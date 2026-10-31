defmodule Monty.Studio.Jobs do
  @moduledoc """
  The queue behind the runs: what Oban holds, which run each job is for, and how
  to stop one.

  A run is enqueued as a `Monty.Studio.Jobs.Run` job, so "is my run queued,
  executing, or did it fail" is a question about Oban rather than about the runs
  table — the runs table only knows what a run *decided*, which is nothing until
  the worker has started. This module joins the two: every job carries its
  `run_id` in its args, so a job row can say which run it belongs to and what
  that run's record says.

  Stopping comes in two shapes, because a job can be in two situations. A worker
  that is running hears `cancel/1` as a message and ends at its next step, with a
  real summary of the steps it did — that is the whole of it for anything that is
  making progress. A step that will never finish (a simulator that hung) hears
  nothing, so `halt/1` is the version that ends the process: the worker is killed,
  the model and the world go with it, and the record is settled here, because the
  process that would have settled it is the one that was killed.
  """

  import Ecto.Query

  require Logger

  alias ExTbpMonty.Repo
  alias Monty.Studio.Jobs.Run, as: Worker
  alias Monty.Studio.RunHistory
  alias Monty.Studio.RunHistory.Run

  # Oban's states for a job that has not started yet: only these can be cancelled
  # outright, because cancelling is what stops them. (`retryable`, not
  # `retrying`: that is how it is spelled.)
  @waiting ~w(available scheduled retryable)

  @cancelled "it was stopped before it finished"
  @killed "someone ended it before it finished"

  @typedoc """
  One job, as the page reads it.

  `state` is Oban's own state as it is stored — `"available"`, `"executing"`,
  `"completed"`, `"retryable"`, `"discarded"`, `"cancelled"`, and the rest of
  `Oban.Job.states/0` — so the page can use the words Oban uses. `run_id` is the
  run the job works on, or `nil` when the job's args name none. `run_status` is
  the recorded run's own status — `"running"`, `"finished"`, `"stopped"`,
  `"failed"` — so a page can tell "queued, no record yet" from "queued, but the
  record says it already ended", which is what a retried job looks like.
  """
  @type job :: %{
          id: integer(),
          state: String.t(),
          queue: String.t(),
          worker: String.t(),
          attempt: pos_integer(),
          max_attempts: pos_integer(),
          inserted_at: DateTime.t() | nil,
          scheduled_at: DateTime.t() | nil,
          run_id: binary() | nil,
          run_status: String.t() | nil,
          run_reason: String.t() | nil,
          error: String.t() | nil
        }

  @doc """
  The jobs of the queue, newest first.

  States are Oban's own names — `"available"`, `"executing"`, `"completed"`,
  `"retryable"`, `"discarded"`, `"cancelled"` — so the page says the same words
  Oban does.
  """
  @spec list(keyword()) :: [job()]
  def list(options \\ []) do
    limit = Keyword.get(options, :limit, 50)

    Oban.Job
    |> order_by([job], desc: job.id)
    |> limit(^limit)
    |> Repo.all()
    |> with_runs()
  end

  @doc "How many jobs are in each state, so a page can say what the queue holds."
  @spec counts() :: %{String.t() => non_neg_integer()}
  def counts do
    Oban.Job
    |> group_by([job], job.state)
    |> select([job], {job.state, count(job.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  How many runs may step at once.

  The queue is the truth, not the number a page holds: enqueueing ten runs behind
  a limit of two is how ten runs become five rounds of two. Monty starts a
  parallel run with a second script, and the script's real setting is how many
  processes go at once; this is that setting, and it can be changed while the
  queue is running.
  """
  @spec parallelism(pos_integer()) :: :ok | {:error, term()}
  def parallelism(limit), do: Oban.scale_queue(queue: :studio, limit: limit)

  @doc """
  The latest job of each of `run_ids`, keyed by run id — absent where a run has
  none any more.

  A run's own page is where a person looks first, and "where is it" is written
  down in Oban: queued, executing, or gone. One query for a page of runs, not one
  per row.
  """
  @spec by_run([binary()]) :: %{optional(binary()) => %{id: integer(), state: String.t()}}
  def by_run([]), do: %{}

  def by_run(run_ids) do
    Oban.Job
    |> where([job], fragment("?->>'run_id' = ANY(?)", job.args, ^run_ids))
    |> order_by([job], desc: job.id)
    |> Repo.all()
    |> Enum.uniq_by(&run_id/1)
    |> Map.new(&{run_id(&1), %{id: &1.id, state: &1.state}})
  end

  # The runs are fetched in one query rather than one per job: a page that lists
  # fifty jobs should not ask the database fifty-one times.
  defp with_runs(jobs) do
    run_ids = jobs |> Enum.map(&run_id/1) |> Enum.reject(&is_nil/1)

    statuses =
      Run
      |> where([run], run.id in ^run_ids)
      |> select([run], {run.id, {run.status, run.summary["reason"]}})
      |> Repo.all()
      |> Map.new()

    Enum.map(jobs, fn job ->
      id = run_id(job)
      {status, reason} = Map.get(statuses, id, {nil, nil})

      %{
        id: job.id,
        state: job.state,
        queue: job.queue,
        worker: job.worker,
        attempt: job.attempt,
        max_attempts: job.max_attempts,
        inserted_at: job.inserted_at,
        scheduled_at: job.scheduled_at,
        run_id: id,
        run_status: status,
        run_reason: reason,
        error: last_error(job)
      }
    end)
  end

  defp run_id(%Oban.Job{args: args}), do: Map.get(args, "run_id")

  # -- stopping one -----------------------------------------------------------

  @doc """
  Cancels a job and stops the run it is for.

  A job that is *waiting* is cancelled outright: cancelling it is the only thing
  that was going to happen to it, and no record was ever going to be written, so
  the run's record is settled here (`{:ok, :settled}`).

  A job that is *executing* is asked instead. Oban cancels a running job by
  ending its process, and a process that is gone cannot write down what it did —
  so the run is told to stop at its next step, writes its own summary, and ends
  `stopped` with the steps it actually took (`{:ok, :stopping}`). The job then
  finishes the way a job that returned finishes.

  `{:error, :settled}` means there was nothing to cancel.
  """
  @spec cancel(integer()) :: {:ok, :stopping | :settled} | {:error, :settled}
  def cancel(job_id) when is_integer(job_id) do
    case Repo.get(Oban.Job, job_id) do
      %Oban.Job{state: "executing"} = job -> stop_executing(job)
      %Oban.Job{state: state} = job when state in @waiting -> cancel_waiting(job)
      _settled_or_missing -> {:error, :settled}
    end
  end

  defp stop_executing(job) do
    Logger.warning("studio job #{job.id} was asked to stop while executing")

    case Worker.stop(run_id(job)) do
      :ok ->
        {:ok, :stopping}

      # Nobody holds it, so there is nothing to ask: the row is all that is left.
      {:error, :not_found} ->
        _ = cancel_row(job)
        {:ok, settle(run_id(job), @cancelled)}
    end
  end

  defp cancel_waiting(job) do
    case cancel_row(job) do
      {:ok, 1} ->
        Logger.warning("studio job #{job.id} was cancelled while waiting")
        {:ok, settle(run_id(job), @cancelled)}

      {:ok, 0} ->
        {:error, :settled}
    end
  end

  @doc """
  Ends an executing job's process now.

  The version for a step that will not finish: the worker is killed rather than
  asked, so the run cannot write its own summary. What it *did* write is kept —
  every step is recorded as it happens — and the record is closed here with
  `#{@killed}`.

  The model and the world are terminated with it. A model is a supervised child
  of its own, so it would outlive its run; the world is started from the worker,
  so it dies with the process that killed it. Nothing of a halted run keeps
  running.

  `{:error, :not_executing}` means there is no process to kill: the job is
  waiting, or it has already ended.
  """
  @spec halt(integer()) :: {:ok, :settled} | {:error, :not_executing}
  def halt(job_id) when is_integer(job_id) do
    case Repo.get(Oban.Job, job_id) do
      %Oban.Job{state: "executing"} = job ->
        # The owner is read first: cancelling the row ends the worker, and with it
        # the registry entry that says which model to stop.
        owner = Worker.owner(run_id(job))
        _ = cancel_row(job)
        Logger.warning("studio job #{job.id} was halted: its process was killed")
        {:ok, kill(run_id(job), owner)}

      _not_executing ->
        {:error, :not_executing}
    end
  end

  # The state in the query, not in a changeset: cancelling is a statement about a
  # job that has reached no outcome, and a job that reached one a moment ago must
  # not be rewritten by a page that was one refresh behind.
  defp cancel_row(job) do
    from(candidate in Oban.Job,
      where: candidate.id == ^job.id and candidate.state == ^job.state
    )
    |> Oban.cancel_all_jobs()
  end

  # The worker first, the model second: the model is a supervised child and would
  # otherwise outlive the run it belonged to. The world goes with the worker,
  # which is the process that started it.
  defp kill(nil, _owner), do: :settled

  defp kill(run_id, owner) do
    case owner do
      [{pid, model_id}] ->
        Process.exit(pid, :kill)
        if is_binary(model_id), do: Monty.Runtime.Model.stop(model_id)
        settle(run_id, @killed)

      [] ->
        settle(run_id, @killed)
    end
  end

  # A `running` record whose process is gone is closed here, because the process
  # that would have closed it is the one that just ended.
  defp settle(run_id, reason) when is_binary(run_id) and is_binary(reason) do
    case RunHistory.get(run_id) do
      %Run{status: "running"} = record ->
        summary = Map.put(record.summary || %{}, "reason", reason)
        {:ok, _closed} = RunHistory.finish(record, summary, "failed")
        announce(run_id, reason)
        :settled

      _finished_or_gone ->
        :settled
    end
  end

  defp settle(_no_run, _reason), do: :settled

  # A page watching this run is told, rather than left waiting for steps that
  # will not come.
  defp announce(run_id, reason) do
    Phoenix.PubSub.broadcast(
      ExTbpMonty.PubSub,
      Worker.topic(run_id),
      {:studio, run_id, {:failed, %{reason: reason}}}
    )
  end

  # Oban accumulates one error per attempt; the last one is why the job is where
  # it is.
  defp last_error(%Oban.Job{errors: []}), do: nil

  defp last_error(%Oban.Job{errors: errors}),
    do: errors |> List.last() |> Map.get("error")
end
