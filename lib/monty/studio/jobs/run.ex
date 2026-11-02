defmodule Monty.Studio.Jobs.Run do
  @moduledoc """
  One experiment run, as a queued job.

  A run used to live inside the page that started it, which meant closing the
  page killed the run and refreshing it lost the run's progress. A run is a job
  instead: the page enqueues it, the queue performs it, and the page watches by
  subscribing to `"studio:run:<id>"`. What the run did is in `studio_runs`; what
  it printed is in `priv/studio_runs/<id>/run.log`; both are written as it goes,
  so a run that dies leaves a record of how far it got.

  Stopping is a message, not a kill: the worker checks its mailbox between
  timesteps, so a stop lands at a step boundary and the summary describes the
  steps that actually happened.
  """

  use Oban.Worker, queue: :studio, max_attempts: 1

  require Logger

  alias Monty.Simulators.Synthetic.{Camera, Environment}
  alias Monty.Studio
  alias Monty.Studio.{Artifacts, CentreView, Logging, Run, RunHistory, RunLog, Setup, Summary}

  @doc "Enqueues a run of `attributes` (see `RunLog.attributes/2`) and returns the job."
  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(attributes) do
    case RunHistory.start(attributes) do
      {:ok, record} -> enqueue_run(record)
      {:error, changeset} -> {:error, {:cannot_record, changeset}}
    end
  end

  @doc "Enqueues a run of an experiment already recorded."
  @spec enqueue_run(RunHistory.Run.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_run(%RunHistory.Run{id: id}) do
    %{"run_id" => id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Asks the worker of a run to stop at the next step boundary.

  `:not_found` means no worker holds that run — it finished, or it never
  started — which is nothing to panic about.
  """
  @spec stop(binary()) :: :ok | {:error, :not_found}
  def stop(run_id) do
    case Registry.lookup(Monty.Runtime.Registry, key(run_id)) do
      [{pid, _model_id}] ->
        send(pid, :stop)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "The topic a run's progress is broadcast on."
  @spec topic(binary()) :: String.t()
  def topic(run_id), do: "studio:run:" <> run_id

  @doc """
  The experiment a record describes: its config, the world it was started
  with, and the seed it kept.

  A record is what a run is told to be. Two of its fields are choices the
  config cannot make for a particular run — the world to step and the seed to
  step it from — so they are read back here rather than taken from the config a
  second time. A record that kept no seed leaves the config's own, which is
  what `Monty.Studio.Setup.with_seed/2` reads `nil` as.
  """
  @spec opened_for(RunHistory.Run.t()) :: {:ok, Studio.opened()} | {:error, term()}
  def opened_for(%RunHistory.Run{experiment: name, inputs: inputs, seed: seed}) do
    case Studio.open(name, world_simulator: world_of(inputs)) do
      {:ok, opened} -> {:ok, %{opened | setup: Setup.with_seed(opened.setup, seed)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    # Ownership first, before anything can fail. "Is a process working on this
    # run" is the question `Monty.Studio.Jobs.Reaper` asks, and a run that is
    # being attempted has an owner even while it is still opening its world.
    register(run_id)

    try do
      with {:ok, record} <- fetch(run_id),
           {:ok, opened} <- opened_for(record) do
        run_experiment(record, opened)
      else
        {:error, reason} -> give_up(run_id, reason)
      end
    rescue
      exception ->
        died(run_id, Exception.message(exception))
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        died(run_id, Exception.format(kind, reason, __STACKTRACE__))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      unregister(run_id)
    end
  end

  @doc """
  Whether a process on this node is working on `run_id` right now.

  This is the only evidence of a live run that cannot be stale: a record says
  "running" until somebody closes it, and an Oban job says `executing` until its
  node is gone and nothing notices. A registered worker is a process that exits
  when it stops working, and the registry forgets it then.
  """
  @spec held?(binary()) :: boolean()
  def held?(run_id), do: Registry.lookup(Monty.Runtime.Registry, key(run_id)) != []

  @doc """
  The process working on a run, and the model it is stepping — `[]` when nobody
  is.

  The model id is what a cancelled run's leftover processes are found by, so a
  caller that ends a run out of band (see `Monty.Studio.Jobs.halt/1`) needs it
  before the process that owns it is gone.
  """
  @spec owner(binary()) :: [{pid(), term()}]
  def owner(run_id), do: Registry.lookup(Monty.Runtime.Registry, key(run_id))

  # -- the run ---------------------------------------------------------------

  # One run is one *epoch*: an episode per object the experiment names, each of
  # them ending the way Monty's does — the recognition policy said done, or the
  # page's step budget ran out. The loop is the experiment class's
  # (`MontyExperiment.run_epoch/2`); this function is the world, the records and
  # the page, which the loop asks for through callbacks.
  defp run_experiment(record, opened) do
    run_id = record.id
    log_ready = Artifacts.start(run_id)
    record = attach_log(record, run_id, log_ready)
    sensor_ids = Setup.sensor_ids(opened.setup)
    experiment = Setup.experiment_class(opened.setup)
    objects = Setup.objects(opened.setup)
    # How much of the experiment this run is: all of it, unless its record says
    # fewer episodes — which is how a page runs a slice and how a test runs one.
    episodes = episodes_of(record, Setup.episodes(opened.setup))

    # What this run will leave behind is the config's answer, not the page's: the
    # handlers it names are also what decides whether the modules keep the whole
    # hypothesis space, which is Monty's `init_monty_data_loggers`.
    logging = Logging.open(opened.setup)

    say(
      run_id,
      "run started: #{record.experiment}, #{length(objects)} object(s) × " <>
        "#{Setup.eval_epochs(opened.setup)} rotation(s), #{episodes} episode(s) in all, " <>
        "up to #{record.steps} steps each"
    )

    broadcast(run_id, {:started, record.steps})

    # A class the config names that this port does not have is said out loud
    # once, at the start, and the run goes on without it.
    Enum.each(
      logging.notes ++ Logging.describe(logging, Artifacts.dir(run_id)),
      &say(run_id, &1)
    )

    # `episode` is the episode of the run the steps now belong to: the step
    # counter restarts inside each one, and what a record and a page keep of a
    # step has to say which episode it was in (`RunLog.entry/3`).
    state = %{run: nil, record: record, logging: logging, infos: [], conclusion: %{}, episode: 0}

    {outcome, ran, state} =
      experiment.run_epochs(state, %{
        objects: objects,
        epochs: Setup.eval_epochs(opened.setup),
        episodes: episodes,
        pre_episode: &start_episode(run_id, opened, &1, &2, &3),
        ground_truth: &ground_truth(&1),
        step: &step_once(run_id, &1, sensor_ids),
        finished?: fn %{run: run} -> Run.finished?(run) end,
        stopped?: &stop_requested?/0,
        post_episode: &end_episode(run_id, &1, &2, &3)
      })

    say(run_id, episodes_line(ran))
    close(state.record, opened, outcome, state.infos, state.conclusion, run_id)
  end

  defp episodes_of(%{inputs: %{"episodes" => count}}, _default)
       when is_integer(count) and count > 0,
       do: count

  defp episodes_of(_record, default), do: default

  # Monty's `pre_episode`, interface half: an episode starts where it was told to
  # — the world for this episode's object, the agent positioned, the sensors
  # reset. The previous episode's processes go first, because a run steps one
  # world at a time.
  defp start_episode(run_id, opened, %{run: previous} = state, index, object) do
    stop_run(previous)

    case Run.start(opened.setup,
           steps: state.record.steps,
           episode: index,
           has_detailed_logger: Logging.detailed?(state.logging)
         ) do
      {:ok, run} ->
        Registry.update_value(Monty.Runtime.Registry, key(run_id), fn _ -> run.model_id end)
        say(run_id, "episode #{index + 1}: #{object || "the scene's own object"}")

        broadcast(
          run_id,
          {:episode, %{episode: index, object: object, steps: state.record.steps}}
        )

        {:ok, %{state | run: run, episode: index}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Monty's `pre_episode`, experiment half: what the world chose, told to the
  # model, so a step can name the object under the patch.
  defp ground_truth(%{run: run} = state) do
    :ok = Run.set_ground_truth(run)
    {:ok, state}
  end

  # Monty's `post_episode`: the episode is logged, then its processes go. The
  # order matters — the episode is logged *before* the memory a training episode
  # writes, because that write rewrites the episode's ground truth and an episode
  # logged afterwards would look confused about the object it just recognised.
  defp end_episode(run_id, %{run: run} = state, _outcome, infos) do
    log_statistics(run_id, state.logging, run)
    conclusion = Run.conclusion(run)
    stop_run(run)

    # `infos` arrive newest first; a page reads an epoch oldest first.
    %{state | run: nil, infos: state.infos ++ Enum.reverse(infos), conclusion: conclusion}
  end

  defp stop_run(nil), do: :ok

  defp stop_run(run) do
    Run.stop(run)
  rescue
    # A world already closed is a world with nothing left to stop; stopping is
    # tidying up, not a step that can fail.
    _no_world_left -> :ok
  end

  defp episodes_line(episodes) do
    ran =
      Enum.map_join(episodes, ", ", fn episode ->
        "#{episode.object || "scene"} #{episode.steps} steps (#{ending(episode.outcome)})"
      end)

    "#{length(episodes)} episode(s): #{ran}"
  end

  defp ending(:finished), do: "concluded"
  defp ending(:stopped), do: "stopped"
  defp ending({:crashed, step, _reason}), do: "failed at step #{step}"

  # A step either reports or the run is broken. A broken step is recorded with
  # the reason it died, because a page that says "running" for ever is a page
  # nobody trusts. What the loop does with that — and with a caller's stop — is
  # `MontyExperiment.run_episode_steps/2`, which is Monty's episode loop.
  defp step_once(run_id, %{run: run} = state, sensor_ids) do
    {:ok, info, observations, run} = Run.step(run)
    beliefs = Run.beliefs(run)

    # The world's own answer, not the transformations' — the transformed
    # observations say what the model was *given* (poses, curvatures, and for the
    # ports not even a location), and a picture of the object is what the world
    # rendered. An experiment behind the port records nothing drawable otherwise,
    # which is a replay of blank frames.
    rendered = Run.rendered_observations(run) || observations
    record = RunLog.record_step(state.record, info, rendered, beliefs, episode: state.episode)

    emit(run_id, state.episode, info, rendered, sensor_ids, beliefs, centre_view(run, info.step))
    {:ok, info, %{state | run: run, record: record}}
  catch
    # An exit and a raise are the same thing here: the step did not produce a
    # report. Both end the episode as a failure, because the alternative — the
    # exception escaping the job — leaves a record saying "running" for ever,
    # and a page nobody trusts.
    :exit, reason -> broken(run_id, run, reason)
    :error, reason -> broken(run_id, run, reason)
  end

  defp broken(run_id, run, reason) do
    say(run_id, "step #{run.step} died: #{inspect(reason)}")
    {:error, reason}
  end

  # A run whose statistics did not get written has still run: the episode is
  # real, the file is missing. That is said in the run's log rather than raised,
  # because the failure is about the artefact and not about the experiment.
  defp log_statistics(run_id, logging, run) do
    case Logging.report(logging, run, Artifacts.dir(run_id)) do
      {:ok, _logging} -> :ok
      {:skipped, _logging} -> :ok
      {:error, reason} -> say(run_id, "statistics could not be written: #{inspect(reason)}")
    end
  end

  # The stop lands in this process's mailbox because this process owns the clock.
  defp stop_requested? do
    receive do
      :stop -> true
    after
      0 -> false
    end
  end

  defp emit(run_id, episode, info, observations, sensor_ids, beliefs, centre) do
    entry = RunLog.entry(info, beliefs, episode: episode)
    line = RunLog.line(entry)
    say(run_id, line)
    frames = frames_for(sensor_ids, observations, info.step)

    broadcast(
      run_id,
      {:step,
       %{
         line: line,
         episode: episode,
         step: info.step,
         frames: frames,
         beliefs: beliefs,
         centre: centre
       }}
    )
  end

  # Where the agent is, relative to the object it is meant to be looking at. A
  # world with no scene has nothing to centre on and answers `nil`, which the page
  # reads as "no such panel".
  defp centre_view(run, step), do: CentreView.frame(run.interface.env, step)

  # Every sensor, every step: a queued run has no socket waiting on it, so the
  # throttle that protects a live page has nothing to protect. The frames are
  # not thumbnails either — they are the same drawing a live page would get.
  defp frames_for(sensor_ids, observations, step) do
    seen = Map.get(observations, Environment.agent_id(), %{})

    sensor_ids
    |> Enum.filter(&Map.has_key?(seen, &1))
    |> Enum.map(&Camera.frame(&1, seen[&1], step))
    |> Enum.map(&Map.take(&1, [:sensor_id, :media_type, :data, :note]))
  end

  defp close(record, opened, outcome, infos, conclusion, run_id) do
    summary = Summary.from_infos(infos, opened.setup, conclusion)
    status = status_of(outcome)

    say(run_id, closing_line(outcome, infos, summary))

    case RunHistory.finish(record, RunLog.summary(summary), status) do
      {:ok, record} ->
        broadcast(run_id, {:finished, %{status: status, summary: RunLog.summary(summary)}})
        {:ok, record}

      {:error, changeset} ->
        say(run_id, "could not close the record: #{inspect(changeset.errors)}")
        broadcast(run_id, {:failed, %{reason: {:cannot_close, changeset.errors}}})
        {:cancel, {:cannot_close, changeset.errors}}
    end
  end

  defp status_of(:finished), do: "finished"
  defp status_of(:stopped), do: "stopped"
  defp status_of({:crashed, _step, _reason}), do: "failed"

  defp closing_line(:finished, infos, summary),
    do: "run finished: #{length(infos)} steps in #{summary.duration_us} µs"

  defp closing_line(:stopped, infos, summary),
    do: "run stopped after #{length(infos)} step(s), #{summary.duration_us} µs of compute"

  defp closing_line({:crashed, step, reason}, infos, _summary),
    do: "run failed at step #{step} after #{length(infos)} step(s): #{inspect(reason)}"

  # -- failing loudly enough -------------------------------------------------

  # A run whose worker raised has ended. Oban records the crash on the job, but
  # jobs are pruned and a person reads the run — so the reason goes where the
  # run's own page can show it, in the database and in the run's own log, and
  # only then is the exception let out, for the job's attempt to be counted.
  defp died(run_id, message) do
    Logger.error("studio run #{run_id} died: #{message}")
    _ = Artifacts.start(run_id)
    _ = say(run_id, "the run died: #{message}")

    with {:ok, record} <- fetch(run_id),
         do: RunHistory.finish(record, %{"reason" => message}, "failed")

    broadcast(run_id, {:failed, %{reason: message}})
  end

  defp give_up(run_id, reason) do
    Logger.error("studio run #{run_id} did not happen: #{inspect(reason)}")

    with {:ok, record} <- fetch(run_id) do
      _ = Artifacts.start(run_id)
      _ = say(run_id, "run did not happen: #{inspect(reason)}")
      _ = RunHistory.finish(record, %{"reason" => inspect(reason)}, "failed")
    end

    broadcast(run_id, {:failed, %{reason: reason}})
    {:cancel, reason}
  end

  # A job's arguments are data, not a promise: an id that is not a run id is
  # answered with what it is, rather than with a cast error from the database.
  defp fetch(run_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id),
         %{} = record <- RunHistory.get(uuid) do
      {:ok, record}
    else
      :error -> {:error, {:not_a_run_id, run_id}}
      nil -> {:error, {:no_such_run, run_id}}
    end
  end

  # A run whose experiment no longer composes is not a run: say which one and
  # why, rather than starting something else and calling it the same thing.
  # The record is the contract: a run says which world it steps, and the queue
  # executes that, not whatever the worker's own environment happens to be. Two
  # processes can share the queue and this database, and one of them may have
  # Monty's world configured while the other does not.
  # The record keeps the world a run was started with; the job turns that back
  # into the world to step. A value this build does not carry is `nil`, which
  # `Monty.Studio.Setup` reads as "nothing chosen" — never a silent stand-in: a
  # run recorded as MuJoCo must not step a sphere.
  defp world_of(%{"world" => "mujoco"}), do: :mujoco
  defp world_of(%{"world" => "synthetic"}), do: :synthetic
  defp world_of(_inputs), do: nil

  defp attach_log(record, run_id, :ok) do
    path = Artifacts.log_path(run_id)

    case RunHistory.attach_log(record, path) do
      {:ok, record} -> record
      {:error, changeset} -> fail_log(record, {:cannot_record_log_path, changeset.errors})
    end
  end

  defp attach_log(record, run_id, {:error, reason}) do
    Logger.error("studio run #{run_id}: no log directory: #{inspect(reason)}")
    fail_log(record, reason)
  end

  defp fail_log(record, reason) do
    Logger.error("studio run #{record.id}: #{inspect(reason)}")
    record
  end

  defp say(run_id, line) do
    case Artifacts.append(run_id, line) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("studio run #{run_id}: cannot write log: #{inspect(reason)}")
    end
  end

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, topic(run_id), {:studio, run_id, event})
  end

  # A run has one owner: this worker, until it stops working on it. Registering
  # is how it proves it is alive (see `held?/1` and `Monty.Studio.Jobs.Reaper`).
  defp register(run_id) do
    case Registry.register(Monty.Runtime.Registry, key(run_id), :starting) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp unregister(run_id), do: Registry.unregister(Monty.Runtime.Registry, key(run_id))

  defp key(run_id), do: {:studio_run, run_id}
end
