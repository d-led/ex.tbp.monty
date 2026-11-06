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

  alias Monty.Studio.{
    Artifacts,
    CentreView,
    Failure,
    Logging,
    Memory,
    Run,
    RunHistory,
    RunLog,
    Setup,
    Summary
  }

  # The release a run's own training is filed under. It is not a Monty release:
  # no archive is published under it, so a config can never name it by accident
  # and load graphs it did not ask for.
  @trained_release "trained"

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
      {:ok, opened} -> runnable(%{opened | setup: Setup.with_seed(opened.setup, seed)})
      {:error, reason} -> {:error, reason}
    end
  end

  # The queue refuses what the page refuses. A config built from classes this
  # port has not written cannot run here, and a record marked `failed` with the
  # reason is a truer record than a run that stands a module in and reports
  # nothing about the experiment.
  defp runnable(opened) do
    case Setup.findings(opened.setup, :error) do
      [] -> {:ok, opened}
      [first | _rest] -> {:error, first.message}
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
        died(run_id, Failure.crashed(:error, exception, __STACKTRACE__))
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        died(run_id, Failure.crashed(kind, reason, __STACKTRACE__))
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
    # An epoch walks its own phase's objects: a config can train on two and
    # evaluate on one, which is two episodes a training epoch and one an
    # evaluation epoch.
    objects = %{
      train: Setup.objects(opened.setup, :train),
      eval: Setup.objects(opened.setup, :eval)
    }

    # How much of the experiment this run is: all of it, unless its record says
    # fewer episodes — which is how a page runs a slice and how a test runs one.
    # The number is per phase, so a two-phase config sliced to two runs two of
    # each; every shipped config has one phase, where the two are the same.
    episodes = episodes_of(record, Setup.planned_episodes(opened.setup))

    # What this run will leave behind is the config's answer, not the page's: the
    # handlers it names are also what decides whether the modules keep the whole
    # hypothesis space, which is Monty's `init_monty_data_loggers`.
    logging = Logging.open(opened.setup)
    plan = Setup.epoch_plan(opened.setup)

    say(
      run_id,
      "run started: #{record.experiment}, #{objects_line(objects)} × " <>
        "#{phases_line(plan)}, #{episodes} episode(s) in all, " <>
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
    # step has to say which episode it was in (`RunLog.entry/3`). `mode` is the
    # phase being run — Monty sets it on the model before the epoch steps, and
    # it is what his ending rule reads.
    state = %{
      run: nil,
      record: record,
      logging: logging,
      infos: [],
      conclusion: %{},
      episode: 0,
      # Which pass over the phase's objects the run is on. Monty's sampler reads
      # it: `Predefined` walks its rotations one per epoch, so an epoch is what a
      # run of three sees as upright, then turned, then upright again.
      epoch: 0,
      # How many episodes this run has started. It, not the epoch's own index, is
      # the number the record keeps: see `start_episode/5`.
      episodes_started: 0,
      mode: :eval,
      # What the phase has learned so far, by module. A run is one episode, so
      # this is the memory a training phase carries from one to the next; an
      # evaluation phase writes nothing into it and hands it on unchanged.
      memories: Setup.memories(opened.setup)
    }

    {outcome, ran, state} =
      run_phases(plan, episodes, state, %{
        experiment: experiment,
        objects: objects,
        pre_episode: &start_episode(run_id, opened, &1, &2, &3, &4),
        ground_truth: &ground_truth(&1),
        step: &step_once(run_id, &1, sensor_ids),
        finished?: fn %{run: run} -> Run.finished?(run) end,
        stopped?: &stop_requested?/0,
        post_episode: &end_episode(run_id, &1, &2, &3)
      })

    say(run_id, episodes_line(ran))
    keep_memory(run_id, opened, plan, state.memories)
    close(state.record, opened, outcome, state.infos, state.conclusion, run_id)
  end

  # Monty's `save_state_dir/1`: what a training phase learned is written down at
  # the end of it, because a memory that only exists inside the process that
  # built it dies with the run — the evaluation phase after it, and the next run,
  # would start from the pretrained graphs again.
  #
  # It goes in the run's own directory rather than in the library tree: a library
  # is named by the experiment that loads it (`Memory.load/3`), and a run's output
  # is named by the run. `memory/trained/<name>.jsonl.gz` is the format the
  # pretrained libraries are in, so anything that can read one can read this.
  defp keep_memory(run_id, opened, plan, memories) do
    if Enum.any?(plan, fn {mode, _epochs} -> mode == :train end) do
      Enum.each(memories, fn {module_id, memory} ->
        write_memory(run_id, opened, module_id, memory)
      end)
    end
  end

  # A module that keeps no graph memory — the stand-in learning module a config
  # without an evidence model gets — has nothing to write, and the `shell`
  # finding already says so.
  defp write_memory(_run_id, _opened, _module_id, :none), do: :ok

  defp write_memory(run_id, opened, module_id, memory) do
    path = Path.join([Artifacts.dir(run_id), "memory"])

    case Memory.save(memory, library_name(opened, module_id), @trained_release, path) do
      :ok ->
        say(run_id, "the memory #{module_id} learned is in #{path}")

      {:error, reason} ->
        # A memory that could not be written is worth a sentence, not a crash: the
        # run itself concluded, and what is lost is what comes after it.
        say(run_id, "the memory #{module_id} learned could not be written: #{inspect(reason)}")
    end
  end

  # The name the run's own memory is filed under: the model its config names,
  # which is what a later run of that config would ask for, and the run's own
  # name when it names none. Two modules in one run are two memories, so the
  # module id keeps them apart.
  defp library_name(opened, module_id) do
    base =
      Memory.name_of(opened.setup.model_name_or_path) ||
        sanitise(opened.setup.logging.run_name) || sanitise(opened.name) ||
        "monty-memory"

    if length(opened.setup.learning_modules) > 1, do: base <> "-" <> module_id, else: base
  end

  # A file name, from a config's own words: anything that is not a letter, a
  # digit, an underscore, a dot or a dash becomes a dash. A name that has nothing
  # of that left — the empty run name most of Monty's test configs have — is no
  # name, so the next one is asked for instead of filing a memory under `""`.
  defp sanitise(nil), do: nil

  defp sanitise(name) do
    case name |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-") |> String.trim("-") do
      "" -> nil
      file_name -> file_name
    end
  end

  # Monty's `run()`: `train()` and then `evaluate()`, each a loop of its own with
  # the mode set on the model before it starts. An epoch that ends badly ends the
  # run, because the next phase would step a model that is not there.
  defp run_phases([{mode, epochs} | rest], episodes, state, callbacks) do
    {outcome, ran, state} =
      callbacks.experiment.run_epochs(
        %{state | mode: mode},
        callbacks
        |> Map.put(:objects, Map.get(callbacks.objects, mode, []))
        |> Map.merge(%{epochs: epochs, episodes: episodes})
      )

    case outcome do
      :finished when rest != [] ->
        {later, more, state} = run_phases(rest, episodes, state, callbacks)
        {later, ran ++ more, state}

      finished_or_ended ->
        {finished_or_ended, ran, state}
    end
  end

  defp run_phases([], _episodes, state, _callbacks), do: {:finished, [], state}

  # "2 object(s) to train on, 1 to evaluate", which is not always one number.
  defp objects_line(objects) do
    Enum.map_join([:train, :eval], ", ", fn mode ->
      "#{length(Map.get(objects, mode, []))} to #{if mode == :train, do: "train on", else: "evaluate"}"
    end)
  end

  # "3 train epoch(s) then 14 eval epoch(s)", in the words the record uses.
  defp phases_line([]), do: "no epochs: the config switches both phases off"

  defp phases_line(plan) do
    plan
    |> Enum.map_join(" then ", fn {mode, epochs} -> "#{epochs} #{mode} epoch(s)" end)
  end

  defp episodes_of(%{inputs: %{"episodes" => count}}, _default)
       when is_integer(count) and count > 0,
       do: count

  defp episodes_of(_record, default), do: default

  # Monty's `pre_episode`, interface half: an episode starts where it was told to
  # — the world for this episode's object, the agent positioned, the sensors
  # reset. The previous episode's processes go first, because a run steps one
  # world at a time.
  # Monty's `pre_episode`, interface half: an episode starts where it was told to
  # — the world for this episode's object, the agent positioned, the sensors
  # reset. The previous episode's processes go first, because a run steps one
  # world at a time.
  #
  # `index` is the episode's place *within its epoch*, and the epoch restarts it:
  # a run of three train epochs then three evaluation ones has six episodes and
  # only three indices. It seeds the episode (`Run.start/2` derives the draws from
  # it) and it is what the log line names, Monty's own way. What the record keeps
  # is the run's own episode — `episodes_started` — because a chart stacks the
  # episodes of a run and two of them sharing a number would be drawn as one: a
  # line joining the last step of the training phase to the first of the
  # evaluation one, across a boundary where the evidence really did restart.
  defp start_episode(run_id, opened, %{run: previous} = state, index, object, callbacks) do
    stop_run(previous)

    episode = state.episodes_started

    # The episode is built from its own phase's objects: the world it shows, the
    # semantic id it carries and the target it is judged by all come from the
    # interface Monty would have used for this mode.
    case Run.start(Setup.with_phase(opened.setup, state.mode),
           steps: state.record.steps,
           episode: index,
           epoch: Map.get(callbacks, :epoch, 0),
           mode: state.mode,
           memory: state.memories,
           has_detailed_logger: Logging.detailed?(state.logging)
         ) do
      {:ok, run} ->
        Registry.update_value(Monty.Runtime.Registry, key(run_id), fn _ -> run.model_id end)
        say(run_id, "episode #{index + 1}: #{object || "the scene's own object"}")

        broadcast(
          run_id,
          {:episode, %{episode: episode, object: object, steps: state.record.steps}}
        )

        {:ok, %{state | run: run, episode: episode, episodes_started: episode + 1}}

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

  # Monty's `post_episode`: the episode is logged, then the memory it produced is
  # written, and then its processes go. The order matters — the episode is logged
  # *before* the write, because that write rewrites the episode's ground truth
  # and an episode logged afterwards would look confused about the object it just
  # recognised (`monty_experiment.py`, `post_episode`).
  defp end_episode(run_id, %{run: run} = state, outcome, infos) do
    {conclusion, memories} =
      cond do
        crashed?(outcome) ->
          # The crash took the model with it: a module's failure stopped the step
          # the model is, and both the statistics and the conclusion are read off
          # that model. The reason this run ends is the crash, said once with its
          # own traceback — asking a dead process for the rest would replace it
          # with "a process the run was waiting on exited". Nothing was learned,
          # so the phase keeps the memory it had.
          say(run_id, "the episode crashed, so its statistics were not read")
          {%{}, state.memories}

        state.mode == :train ->
          log_statistics(run_id, state.logging, run)
          conclusion = Run.conclusion(run)
          {conclusion, learned(run_id, run, state.memories)}

        true ->
          # An evaluation episode writes nothing, and this reads nothing either:
          # the memory only has to travel when something wrote to it, and
          # reading it back copies tens of megabytes out of the module process
          # every episode (`LearningModuleServer.state/1` — the reason
          # `detailed/2` exists).
          log_statistics(run_id, state.logging, run)
          {Run.conclusion(run), state.memories}
      end

    stop_run(run)

    # `infos` arrive newest first; a page reads an epoch oldest first.
    %{
      state
      | run: nil,
        infos: state.infos ++ Enum.reverse(infos),
        conclusion: conclusion,
        memories: memories
    }
  end

  # Monty's `model.update_ltm()`: the module decides what a training episode adds
  # to long-term memory. What answers here is the memory the *rest* of the phase
  # starts from — the graph this episode built is what the next one matches
  # against — so it is read only where it can have changed (`Run.next_memories/3`).
  defp learned(run_id, run, memories) do
    Run.next_memories(run, memories, :train)
  rescue
    # A memory is what the episode leaves behind, not part of the episode: a
    # module that cannot answer for it must not turn a finished run into a crash.
    error ->
      say(run_id, "the memory could not be written: #{Exception.message(error)}")
      memories
  end

  defp crashed?({:crashed, _step, _reason}), do: true
  defp crashed?(_outcome), do: false

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
    # A raise and an exit are the same thing here: the step did not produce a
    # report. Both end the episode as a failure, because the alternative — the
    # exception escaping the job — leaves a record saying "running" for ever,
    # and a page nobody trusts. The sentence is built here, where the traceback
    # still exists: formatted later from a bare term, it would have none.
    kind, reason -> step_died(run_id, run, Failure.crashed(kind, reason, __STACKTRACE__))
  end

  defp step_died(run_id, run, %{"reason" => what} = recorded) do
    say(run_id, "step #{run.step} died: #{what}")
    {:error, recorded}
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
    # One summary for the record and for whoever is watching: why a run did not
    # finish is part of it, because that is everything a page has after the last
    # step.
    stored = RunLog.summary(summary, Failure.stopped(outcome))

    say(run_id, closing_line(outcome, infos, summary))

    case RunHistory.finish(record, stored, status) do
      {:ok, record} ->
        broadcast(run_id, {:finished, %{status: status, summary: stored}})
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

  defp closing_line({:crashed, step, reason}, infos, _summary) do
    what = reason |> Failure.stopped() |> Map.fetch!("reason")
    "run failed at step #{step} after #{length(infos)} step(s): #{what}"
  end

  # -- failing loudly enough -------------------------------------------------

  # A run whose worker raised has ended. Oban records the crash on the job, but
  # jobs are pruned and a person reads the run — so the sentence goes where the
  # run's own page shows it, the traceback beside it for whoever is debugging,
  # and only then is the exception let out, for the job's attempt to be counted.
  defp died(run_id, %{"reason" => what} = recorded) do
    Logger.error("studio run #{run_id} died: #{recorded["technical"] || what}")
    _ = Artifacts.start(run_id)
    _ = say(run_id, "the run died: #{what}")

    with {:ok, record} <- fetch(run_id),
         do: RunHistory.finish(record, Map.merge(record.summary || %{}, recorded), "failed")

    broadcast(run_id, {:failed, %{reason: what}})
  end

  defp give_up(run_id, reason) do
    Logger.error("studio run #{run_id} did not happen: #{inspect(reason)}")

    recorded =
      "The run could not start: its experiment would not open."
      |> Failure.explain(inspect(reason))
      |> Failure.recorded()

    with {:ok, record} <- fetch(run_id) do
      _ = Artifacts.start(run_id)
      _ = say(run_id, "run did not happen: #{recorded["reason"]}")
      _ = RunHistory.finish(record, Map.merge(record.summary || %{}, recorded), "failed")
    end

    broadcast(run_id, {:failed, %{reason: recorded["reason"]}})
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
