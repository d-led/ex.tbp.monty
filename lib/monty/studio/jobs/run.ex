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
  alias Monty.Studio.{Artifacts, Run, RunHistory, RunLog, Setup, Summary}

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

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    with {:ok, record} <- fetch(run_id),
         {:ok, opened} <- open(record) do
      run_experiment(record, opened)
    else
      {:error, reason} -> give_up(run_id, reason)
    end
  end

  # -- the run ---------------------------------------------------------------

  defp run_experiment(record, opened) do
    run_id = record.id
    log_ready = Artifacts.start(run_id)
    record = attach_log(record, run_id, log_ready)
    sensor_ids = Setup.sensor_ids(opened.setup)

    case Run.start(opened.setup, steps: record.steps) do
      {:ok, run} ->
        Registry.register(Monty.Runtime.Registry, key(run_id), run.model_id)

        say(
          run_id,
          "run started: #{record.experiment}, #{record.steps} steps, seed #{record.seed}"
        )

        broadcast(run_id, {:started, record.steps})

        {outcome, infos, record} = step_until_done(run_id, record, run, sensor_ids, [])

        Run.stop(run)
        Registry.unregister(Monty.Runtime.Registry, key(run_id))
        close(record, opened, outcome, infos, run_id)

      {:error, reason} ->
        give_up(run_id, {:cannot_start, reason})
    end
  end

  # A step either reports or the run is broken. A broken step is recorded with
  # the reason it died, because a page that says "running" for ever is a page
  # nobody trusts.
  defp step_until_done(run_id, record, run, sensor_ids, infos) do
    receive do
      :stop -> {:stopped, infos, record}
    after
      0 ->
        if Run.finished?(run) do
          {:finished, infos, record}
        else
          step(run_id, record, run, sensor_ids, infos)
        end
    end
  end

  defp step(run_id, record, run, sensor_ids, infos) do
    {:ok, info, observations, run} = Run.step(run)
    record = RunLog.record_step(record, info, observations)
    emit(run_id, info, observations, sensor_ids)
    step_until_done(run_id, record, run, sensor_ids, [info | infos])
  catch
    :exit, reason ->
      say(run_id, "step #{run.step} died: #{inspect(reason)}")
      {{:crashed, run.step, reason}, infos, record}
  end

  defp emit(run_id, info, observations, sensor_ids) do
    entry = RunLog.entry(info)
    line = RunLog.line(entry)
    say(run_id, line)
    frames = frames_for(sensor_ids, observations, info.step)
    broadcast(run_id, {:step, %{line: line, step: info.step, frames: frames}})
  end

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

  defp close(record, opened, outcome, infos, run_id) do
    summary = Summary.from_infos(Enum.reverse(infos), opened.setup)
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

  defp give_up(run_id, reason) do
    Logger.error("studio run #{run_id} did not happen: #{inspect(reason)}")

    with {:ok, record} <- fetch(run_id) do
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
  defp open(%RunHistory.Run{experiment: name}) do
    Studio.open(name)
  end

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

  defp key(run_id), do: {:studio_run, run_id}
end
