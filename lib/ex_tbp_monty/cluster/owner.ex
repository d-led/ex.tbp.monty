defmodule ExTbpMonty.Cluster.Owner do
  @moduledoc """
  Which node performs a run, and how to reach it.

  A run is stepped by one process, on one node, and the only thing that can say
  which process that is — `Monty.Runtime.Registry` — is that node's own. With one
  runs table for a cluster, a page on node1 draws node2's rows: it can offer Stop
  on a run it has no way of looking up, so the ask has to travel. The row's `node`
  is the node that claimed the run (`Monty.Studio.AtomicClaim`, via
  `Monty.Studio.RunHistory.mark_running/1`), which makes the row itself the
  routing table.

  `:here` is the answer on a node that runs alone, on a row whose node is this
  one, and on a row that names a node the cluster does not have — in the last case
  there is nobody to ask and asking here is the same as asking into the void.
  """

  alias ExTbpMonty.Cluster.Nodes
  alias Monty.Studio.RunHistory

  @doc """
  The node that has this run, when that is not this node.

  `entries` is a seam for a test, like `Nodes.of/2` — the only way to see two
  nodes without starting two VMs.
  """
  @spec elsewhere(String.t() | nil, [map()]) :: {:ok, node()} | :here
  def elsewhere(run_id, entries \\ Nodes.snapshot()) do
    with %{node: owner} when is_binary(owner) <- RunHistory.head(run_id),
         {node, _entry} <- find_named(entries, owner),
         false <- node == node() do
      {:ok, node}
    else
      _here_or_nobody -> :here
    end
  end

  # The entry for a node in either spelling: a row written now carries the address
  # a peer dials, and one written by an older build carries the folder's name.
  defp find_named(entries, owner) do
    Enum.find_value(entries, fn entry ->
      named(entry, owner) && {entry.node, entry}
    end)
  end

  defp named(entry, owner), do: owner in [Map.get(entry, :address), Map.get(entry, :name)]
end
