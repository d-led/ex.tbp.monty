defmodule Monty.Studio.Jobs.Reaper do
  @moduledoc """
  Closes the runs whose process is gone.

  A run's record is written before the job that executes it and closed by that
  job, so the job is the only thing that can say when a run ended. When the job
  dies with the node — a restart, a deploy, an `IEx` closed at the wrong moment —
  nothing is left to close the record, and it says `running` for ever: a page
  that shows a run still going when nothing is working on it, and an experiment
  that refuses a new run because its old one is "already running".

  A record is therefore checked against the two things that can only be true of a
  live run: a process registered for it on this node
  (`Monty.Studio.Jobs.Run.held?/1`), or an Oban job still waiting its turn. A
  `running` record with neither is one whose process is gone, and saying so —
  with the reason, in the record and in the run's own log — beats leaving it to
  be guessed at.

  Reading silence as death needs a grace period: a job that has just started has
  not registered itself yet, so for the first minute of an attempt the registry
  cannot be believed. Anything older than that is a decision this module can make
  on its own, because nothing else is going to.

  This is a one-node judgement, and it is worth saying so: the registry is this
  node's, so two nodes executing the same queue would each need to prove
  ownership somewhere they both read — a Postgres advisory lock, which is how the
  mirror this queue's design comes from settles it. This application runs one
  node (`Oban.Engines.Basic`, `queues: [studio: 2]`), and with one node the
  registry is exactly true.
  """

  import Ecto.Query

  require Logger

  alias ExTbpMonty.Repo
  alias Monty.Studio.{Artifacts, RunHistory}
  alias Monty.Studio.Jobs.Run

  # Oban's own words for a job that has not reached an outcome and is not
  # executing: it will still be tried, so its run is not abandoned, it is
  # waiting. (`retryable`, not `retrying`: that is how the enum is spelled.)
  @waiting ~w(available scheduled retryable)

  @grace_seconds 60

  @abandoned "it stopped before it finished — nothing was working on it any more"

  @doc """
  Marks every abandoned run as failed, and returns how many it closed.

  Runs once at boot — a node that starts knows it is not running anything from
  before — and again whenever a page is about to show a run, because a page that
  would otherwise describe a run nobody is working on is a page that lies.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    RunHistory.running()
    |> Enum.reject(&(Run.held?(&1.id) or waiting?(&1)))
    |> Enum.map(&abandon/1)
    |> length()
  end

  # A job that is queued will still be tried, and one that is executing may have
  # started a moment ago.
  defp waiting?(record) do
    case job_of(record.id) do
      %{state: state} when state in @waiting -> true
      %{state: "executing", attempted_at: %DateTime{} = at} -> recent?(at)
      _settled_or_missing -> false
    end
  end

  defp recent?(at), do: DateTime.diff(DateTime.utc_now(), at, :second) < @grace_seconds

  defp abandon(record) do
    reason = reason_of(record.id)

    Logger.warning("studio run #{record.id} was abandoned: #{reason}")

    # The reason is written where a person will look for it — the record a page
    # reads and the run's own log, which exists whether or not the run got far
    # enough to make it.
    _ = Artifacts.start(record.id)
    _ = Artifacts.append(record.id, "the run was abandoned: #{reason}")
    _ = RunHistory.finish(record, Map.put(record.summary || %{}, "reason", reason), "failed")
    _ = cancel_job(record.id)
    _ = announce(record.id, reason)

    :ok
  end

  # Why a run was abandoned, in the best words available: the job's own last
  # error when it left one — a worker that raised has its exception on the
  # attempt, and that sentence is the one a person can act on — and the plain
  # statement of the fact when there is nothing better.
  defp reason_of(run_id) do
    case job_of(run_id) do
      %{errors: errors} when is_list(errors) and errors != [] ->
        last_error(errors)

      _no_evidence ->
        @abandoned
    end
  end

  defp last_error(errors) do
    errors
    |> List.last()
    |> Map.get("error")
    |> case do
      nil -> @abandoned
      text -> text |> to_string() |> String.split("\n") |> List.first()
    end
  end

  # A discarded job is already settled, and cancelling it would only produce an
  # error. An `executing` one is the leftover that holds a queue slot and turns
  # away the next scheduled run through its uniqueness, so it is cancelled with
  # the record it can no longer close.
  defp cancel_job(run_id) do
    case job_of(run_id) do
      %{state: "executing"} = job ->
        _ = Oban.cancel_job(job)
        :ok = Artifacts.append(run_id, "its job ##{job.id} was cancelled: it was left executing")

      _settled_or_missing ->
        :ok
    end
  end

  # A page watching this run is watching a process that no longer exists: it is
  # told, rather than left waiting for steps that will not come.
  defp announce(run_id, reason) do
    Phoenix.PubSub.broadcast(
      ExTbpMonty.PubSub,
      Run.topic(run_id),
      {:studio, run_id, {:failed, %{reason: reason}}}
    )
  end

  defp job_of(run_id) do
    Repo.one(
      from job in Oban.Job,
        where: fragment("?->>'run_id' = ?", job.args, ^run_id),
        order_by: [desc: job.id],
        limit: 1
    )
  end
end
