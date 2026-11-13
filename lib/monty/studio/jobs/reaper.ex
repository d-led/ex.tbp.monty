defmodule Monty.Studio.Jobs.Reaper do
  @moduledoc """
  Closes the runs whose process is gone.

  A run's record is written before the job that executes it and closed by that
  job, so the job is the only thing that can say when a run ended. When the job
  dies with the node — a restart, a deploy, an `IEx` closed at the wrong moment —
  nothing is left to close the record, and it says `running` for ever: a page
  that shows a run still going when nothing is working on it, and an experiment
  that refuses a new run because its old one is "already running".

  A record is therefore checked against the one thing that can only be true of a
  live run: a process stepping it, which the run registers (`Run.owner/1`). Oban
  says what has become of the job — queued jobs will be tried, settled ones never
  will — and for a job that is executing the registry answers with a pid, or with
  nothing. A `running` record with no pid behind it is one whose process is gone,
  and saying so — with the reason, in the record and in the run's own log — beats
  leaving it to be guessed at.

  Silence is not evidence, and is not used as any: a run stepped where this node
  cannot see it (`mix monty.run`, which never enqueues a job) is the one case
  with no pid and no job, and the only one judged by how recently its record was
  written.

  ## Whose run is it

  The registry is this node's, and with one runs table for a cluster every node
  sees every open row — so "nothing is working on it" would be said by this node
  about a peer's run it cannot see the process of. It was, once, in a two-node
  trial: the second of two parallel runs was abandoned at step 95 by the node that
  was not stepping it.

  A row is therefore **this node's to close only when it names this node** (in
  either spelling), or names no node at all. A peer's run is that peer's, however
  quiet it looks — and the tempting extra clause, "and a node that is no longer in
  the cluster", is exactly the mistake this page's own design records: liveness
  here is a 500 ms `:rpc` to a poller (`ExTbpMonty.Cluster.Nodes`), and two runs
  saturating one machine made that probe time out, so node1 "knew" node2 had gone
  and abandoned its live run twice. A run is not worth a heuristic.

  What closes the run of a node that really died is that node: its own boot sweeps
  its own rows (they are its folder's), and until then the row says `running` and
  a page says it has been quiet for a while — which is true, and is not a lie an
  inference can improve on.
  """

  import Ecto.Query

  require Logger

  alias ExTbpMonty.Repo
  alias Monty.Studio.{Artifacts, Failure, RunHistory}
  alias Monty.Studio.Jobs.Run

  # Oban's own words for a job that has not reached an outcome and is not
  # executing: it will still be tried, so its run is not abandoned, it is
  # waiting. (`retryable`, not `retrying`: that is how the enum is spelled.)
  @waiting ~w(available scheduled retryable)

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
    |> Enum.filter(&ours?(&1, mine()))
    |> Enum.reject(&(Run.held?(&1.id) or alive?(&1)))
    |> Enum.map(&abandon/1)
    |> length()
  end

  @doc """
  Closes `run_id` if nothing is working on it, and answers `:ok` when it did.

  The one-run form of `sweep/0`, for a page that already watches that run. A page
  polls the run it shows, and sweeping every open run on every poll asked the
  database and Oban about runs that page cannot be wrong about; this asks about
  the one it can.

  The counters are enough to decide, and they are all that is read: a full record
  is the run's whole transcript, and this question is asked twice a second by
  every open page. Closing a run writes its status and summary by id, so nothing
  that is not read here is needed to close it.
  """
  @spec reap(String.t()) :: :ok | false
  def reap(run_id) do
    case RunHistory.progress(run_id) do
      %{status: status} = record when status in ["queued", "running"] ->
        cond do
          not ours?(record, mine()) -> false
          Run.held?(record.id) or alive?(record) -> false
          true -> abandon(record)
        end

      _settled ->
        false
    end
  end

  @doc """
  Whether a run's record is this node's to close.

  `mine` is this node in both spellings — the address a peer dials and the name
  its folder has — because a row from an older build carries the second one.

  A row that names no node is a lone node's, and this node is that node. Any other
  name is another node's run, and this node has no business closing it.
  """
  @spec ours?(map(), [String.t()]) :: boolean()
  def ours?(%{node: owner}, mine) when is_binary(owner), do: owner in mine
  def ours?(_record, _mine), do: true

  # This node, in both spellings: `nil` on a node that runs alone, which writes no
  # name at all and therefore matches no row.
  defp mine do
    [ExTbpMonty.Node.address(node()), Monty.Paths.data_dir_name()]
    |> Enum.filter(&is_binary/1)
  end

  # A run is alive if a process is stepping it. Oban says what has become of the
  # job — queued jobs will be tried, settled ones never will — and for a job that
  # is executing, the process is the answer: the registry holds it, and an entry
  # whose pid is gone holds nothing. Oban's `attempted_by` names a host and a
  # producer, not a process, so the pid is this node's to know and nobody else's.
  #
  # No job at all is the headless case — `mix monty.run` steps an experiment in
  # its own VM, so this node's registry can never see it and its queue never
  # knows it — and the only one silence can be judged on.
  defp alive?(record) do
    case job_of(record.id) do
      %{state: state} when state in @waiting -> true
      %{state: "executing"} = job -> working?(record) or starting?(job)
      nil -> fresh?(record)
      %{state: _settled} -> false
    end
  end

  defp working?(record) do
    case Run.owner(record.id) do
      [{pid, _label}] -> Process.alive?(pid)
      [] -> false
    end
  end

  # The one gap a registry cannot see: Oban writes `attempted_at` before it calls
  # the worker, so a claim seconds old may have no process registered yet.
  @claim_grace_s 5
  defp starting?(%{attempted_at: %DateTime{} = at}), do: recent?(at, @claim_grace_s)
  defp starting?(_job), do: false

  # Every step a run takes writes its record, whoever is stepping it.
  defp fresh?(record), do: RunHistory.quiet_for(record) < grace_seconds()

  defp recent?(at, seconds), do: DateTime.diff(DateTime.utc_now(), at, :second) < seconds

  # The threshold is a setting, read through a cache: a claim about somebody
  # else's process is exactly the number that is wrong on a slow machine, so it
  # is not something to bake into a module.
  defp grace_seconds, do: Monty.Studio.Settings.get("job_abandon_after_s")

  defp abandon(record) do
    recorded = record.id |> reason_of() |> Failure.explain() |> Failure.recorded()

    Logger.warning(
      "studio run #{record.id} was abandoned: #{recorded["technical"] || recorded["reason"]}"
    )

    # The sentence is written where a person will look for it — the record a page
    # reads and the run's own log, which exists whether or not the run got far
    # enough to make it. The traceback a job left goes beside it, in the record,
    # for whoever is debugging.
    _ = Artifacts.start(record.id)
    _ = Artifacts.append(record.id, "the run was abandoned: #{recorded["reason"]}")
    _ = RunHistory.finish(record, Map.merge(record.summary || %{}, recorded), "failed")
    _ = cancel_job(record.id)
    _ = announce(record.id, recorded["reason"])

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
