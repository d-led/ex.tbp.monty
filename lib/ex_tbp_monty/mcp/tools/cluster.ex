defmodule ExTbpMonty.Mcp.Tools.Cluster do
  @moduledoc """
  `monty_cluster_nodes`: which nodes there are, which build each one runs, and
  what each one can do.

  A caller that is about to run something needs this before it runs it: a cluster
  of unlike machines is one where "which node" is a question about what a node
  *can*, and the answer is not in any config file — it is the machines
  themselves. The tags are `ExTbpMonty.Cluster.Capabilities`; the list is the
  same one the settings page shows, read from the same poller, so a client is told
  what a person reading the page is told.

  A node that runs alone answers too, with one entry: clustering is off, and that
  is a different answer from "a cluster with one member".
  """

  alias ExTbpMonty.Cluster
  alias ExTbpMonty.Cluster.Capabilities

  @doc """
  The nodes, their builds and their tags.
  """
  def nodes(_arguments, _ctx) do
    entries = Cluster.Nodes.snapshot()

    {:ok, %{text: text(entries), structured: structured(entries)}}
  end

  @doc """
  The answer as a program reads it.

  Public because it is the whole answer: a test states it for two nodes without
  running two VMs.
  """
  @spec structured([map()]) :: map()
  def structured(entries) do
    %{
      "enabled" => Cluster.enabled?(),
      "why_not" => ExTbpMonty.Node.why_not(),
      "nodes" =>
        Enum.map(entries, fn entry ->
          %{
            "node" => to_string(entry.node),
            "name" => entry.name,
            "version" => entry.version,
            "self" => entry.self,
            "alive" => entry.alive,
            "capabilities" => entry.capabilities
          }
        end),
      "by_capability" => Map.new(Capabilities.by_tag(entries))
    }
  end

  @doc """
  The answer as a model reads it.

  One line per node, then the other direction: a caller looking for a machine
  that can do something should not have to read every row to find it.
  """
  @spec text([map()]) :: String.t()
  def text(entries) do
    """
    #{heading(entries)}

    #{Enum.map_join(entries, "\n", &row/1)}

    #{capabilities(entries)}
    """
  end

  defp heading(entries) do
    case {Cluster.enabled?(), length(entries)} do
      {false, _} ->
        "One node. Clustering is off here: MONTY_CLUSTER (with a node name) turns it on."

      {true, 1} ->
        "One node in this cluster: this one. A peer joins it as soon as it connects."

      {true, count} ->
        "#{count} nodes in this cluster:"
    end
  end

  # A peer that did not answer is still a node: dropping it would hide the one
  # thing a caller can act on, which is that something is expected there and is
  # not there.
  defp row(entry) do
    parts = [
      entry.name,
      entry.version || "no answer",
      entry.self && "this node",
      entry.capabilities != [] && Enum.join(entry.capabilities, " ")
    ]

    "  " <> Enum.join(Enum.reject(parts, &(&1 in [nil, false])), " · ")
  end

  defp capabilities(entries) do
    case Capabilities.by_tag(entries) do
      [] ->
        "No node advertises a capability tag."

      tags ->
        "What this cluster can do:\n" <>
          Enum.map_join(tags, "\n", fn {tag, names} -> "  #{tag}: #{Enum.join(names, ", ")}" end)
    end
  end
end
