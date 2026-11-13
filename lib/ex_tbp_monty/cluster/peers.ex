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
  def recent(entries \\ Nodes.snapshot(), fetch \\ &runs_on/1) do
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

  defp runs_on(node_name) do
    case :rpc.call(node_name, __MODULE__, :local_recent, [], @timeout) do
      runs when is_list(runs) -> runs
      _no_answer -> []
    end
  end
end
