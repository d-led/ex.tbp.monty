defmodule Monty.Studio.Jobs do
  @moduledoc """
  The queue behind the runs: what Oban holds, and which run each job is for.

  A run is enqueued as a `Monty.Studio.Jobs.Run` job, so "is my run queued,
  executing, or did it fail" is a question about Oban rather than about the runs
  table — the runs table only knows what a run *decided*, which is nothing until
  the worker has started. This module joins the two: every job carries its
  `run_id` in its args, so a job row can say which run it belongs to and what
  that run's record says.

  Nothing here starts, cancels or retries anything: Oban is the source of truth
  for a job's state, and a view that changes state is a different feature.
  """

  import Ecto.Query

  alias ExTbpMonty.Repo
  alias Monty.Studio.RunHistory.Run

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

  # The runs are fetched in one query rather than one per job: a page that lists
  # fifty jobs should not ask the database fifty-one times.
  defp with_runs(jobs) do
    run_ids = jobs |> Enum.map(&run_id/1) |> Enum.reject(&is_nil/1)

    statuses =
      Run
      |> where([run], run.id in ^run_ids)
      |> select([run], {run.id, run.status})
      |> Repo.all()
      |> Map.new()

    Enum.map(jobs, fn job ->
      id = run_id(job)

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
        run_status: Map.get(statuses, id),
        error: last_error(job)
      }
    end)
  end

  defp run_id(%Oban.Job{args: args}), do: Map.get(args, "run_id")

  # Oban accumulates one error per attempt; the last one is why the job is where
  # it is.
  defp last_error(%Oban.Job{errors: []}), do: nil

  defp last_error(%Oban.Job{errors: errors}),
    do: errors |> List.last() |> Map.get("error")
end
