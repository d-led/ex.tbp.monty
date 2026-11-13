defmodule ExTbpMonty.Cluster.Peers do
  @moduledoc """
  What the other nodes have been running.

  A run's row, its log, its pictures and the process stepping it are one node's —
  that is what `Monty.Paths.node_root/0` decides — so a cluster has one run list
  per node, and a page shows its own. This is the smaller half of seeing the whole
  cluster: each node summarises the runs it has last dealt with, and the page that
  asked shows them under its own list, in flight or settled.

  **Asked, not subscribed.** The runs topic is the cluster's (Phoenix's pubsub is
  the distributed one), but a peer's row is not a row of this node's list — and a
  page that acted on one would be offering Stop and Delete for a run it cannot
  see. So the page asks, and asks again on its own clock, because a run settling
  on a peer is not something this node is told about.

  Read-only by construction: what this module answers is a summary, and the one
  thing a reader can do with it is follow the node's own address to the run
  (`ExTbpMonty.Node.web_url/1`).
  """

  alias ExTbpMonty.Cluster.Nodes
  alias Monty.Studio.RunHistory

  # Short on purpose. A peer that is slow to answer is a peer whose runs this page
  # does not show, and the poller has already marked a peer that stopped
  # answering altogether (`ExTbpMonty.Cluster.Nodes`), so this is the slow case
  # rather than the dead one.
  @timeout 1_000

  # How many of a peer's runs are worth showing: a node with a longer history than
  # this is a node whose own list the reader should open instead.
  @limit 5

  @doc """
  The latest runs of every reachable peer, one entry per node, this node excluded.

  A cluster of one answers `[]`, which is the honest reading: there is no other
  node whose work this page could show.

  `fetch` is a seam for a test, like `Nodes.of/2` — the only way to see two nodes
  without starting two VMs.
  """
  @spec recent([map()], (node() -> [map()] | nil)) :: [%{node: map(), runs: [map()]}]
  def recent(entries \\ Nodes.snapshot(), fetch \\ &recent_on/1) do
    entries
    # This node's own runs are the list the page already draws, and a peer the
    # poller could not reach is a peer whose list says nothing a reader can act on.
    |> Enum.reject(&(&1.self || not Map.get(&1, :alive, false)))
    |> Enum.map(fn entry -> %{node: entry, runs: List.wrap(fetch.(entry.node))} end)
    |> Enum.reject(&(&1.runs == []))
  end

  @doc """
  This node's latest runs, as plain maps — what a peer's page gets back over
  `:rpc`.

  Latest rather than only those still going: a node that finished a run a minute
  ago is answering "what has this machine been doing", which is the question a
  reader of a cluster's other nodes asks. The state travels with each row, so
  `running` and `finished` are told apart by the reader rather than by the query.

  Cheap and public on purpose: the rows carry no pictures and no transcript
  (`RunHistory.search/1` reads a row's columns without them), and only a handful
  of them. The time is a string because the page that shows it is on another node,
  with another clock's idea of now — the browser renders it in its own.

  **This node's own**, which is the same thing as "every run" with a file per
  node and is not with one runs table for the whole cluster: there, a peer that
  answered with everything would hand this page its own runs back as somebody
  else's.
  """
  @spec local_recent() :: [map()]
  def local_recent do
    RunHistory.search(node: Monty.Paths.data_dir_name(), per_page: @limit).runs
    |> Enum.map(fn run ->
      %{
        id: run.id,
        experiment: run.experiment,
        state: run.status,
        steps: run.steps_done,
        started_at: run.started_at && DateTime.to_iso8601(run.started_at)
      }
    end)
  end

  defp recent_on(node_name) do
    case :rpc.call(node_name, __MODULE__, :local_recent, [], @timeout) do
      runs when is_list(runs) -> runs
      _no_answer -> []
    end
  end

  @doc """
  A peer's own page of runs, filtered the way this node's list is — or `nil` when
  it does not answer.

  `nil` rather than an empty page, because the two are different answers: "that
  node has no runs like these" is a list a reader can act on, and "that node did
  not answer" is a page that has to say so instead of pretending the runs are
  gone.

  The rows cross as this application's own structs (`RunHistory.Run`), which is
  honest for a cluster of one build — the version each node runs is in every
  entry of the node list, and two builds that disagree about a struct are already
  two builds that disagree about the schema.

  `fetch` is the same kind of seam as `recent/2`'s: a test cannot dial a peer that
  does not exist, and the shape of the answer is what the page depends on.
  """
  @spec runs_on(map() | node(), keyword(), (map() | node(), map() -> map() | nil)) ::
          map() | nil
  def runs_on(entry_or_name, options \\ [], fetch \\ &page_on/2) do
    # The filters travel as the page's params spell them — strings — so the
    # answering side reads one shape and not two.
    fetch.(entry_or_name, Map.new(options, fn {key, value} -> {to_string(key), value} end))
  end

  defp page_on(entry_or_name, options) do
    name = if is_map(entry_or_name), do: entry_or_name.node, else: entry_or_name

    case :rpc.call(name, __MODULE__, :local_runs, [options], @timeout) do
      %{runs: _runs, total: _total, pages: _pages, page: _page} = page -> page
      _no_answer -> nil
    end
  end

  @doc """
  This node's own page of runs — what a peer's page asks for over `:rpc`.

  Filtered exactly as that page is, and always by this node's own name: with one
  runs table for a cluster, a peer that answered with every matching run would
  hand this page its own runs back under another node's heading.
  """
  @spec local_runs(map()) :: map()
  def local_runs(options) when is_map(options) do
    found =
      RunHistory.search(
        state: Map.get(options, "state", "all"),
        text: Map.get(options, "text", ""),
        page: Map.get(options, "page", 1),
        node: Monty.Paths.data_dir_name()
      )

    %{runs: found.runs, total: found.total, pages: found.pages, page: found.page}
  end
end
