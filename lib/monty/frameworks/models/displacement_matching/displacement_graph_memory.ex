defmodule Monty.Frameworks.Models.DisplacementMatching.DisplacementGraphMemory do
  @moduledoc """
  What a displacement module reads off a graph: Monty's `DisplacementGraphMemory`.

  The memory itself is `Monty.Frameworks.Models.GraphMatching.GraphMemory` — the
  same k-nearest-neighbour graph every graph module stores. What a *displacement*
  module needs on top of it is a way to start matching: every edge of every graph
  as a two-node path, and the edge's stored displacement, which is what the next
  step's displacement is compared against.

  So this is functions over a graph memory rather than a kind of memory. Monty
  spells the difference as a subclass, which also lets it override how a graph is
  built; here the graph is built once, by `GraphObjectModel`, and every edge
  already carries its displacement — a class that had to say so again would be
  saying what the model says.

  Not ported: the point-pair-feature matching (`match_attribute: "PPF"`), which
  stores four numbers per edge and compares relative lengths. A config that asks
  for it is refused by `DisplacementGraphLM` rather than run as something else.
  """

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel

  @typedoc """
  The four things a displacement module starts an episode with.

  `possible_matches` is every object in memory; `possible_paths` is where a
  match can be at the first step — Monty starts it with the node ids themselves,
  one per node, and replaces them with paths as soon as a move is matched;
  `next_possible_paths` is one two-node path per edge, because a move has to be
  along an edge, and those are the paths a step is matched against;
  `scale_factors` is the first component of each edge's displacement, which a
  scale-invariant match divides by.
  """
  @type hypotheses :: %{
          possible_matches: %{optional(String.t()) => map()},
          possible_paths: %{optional(String.t()) => [non_neg_integer()] | [[non_neg_integer()]]},
          next_possible_paths: %{optional(String.t()) => [[non_neg_integer()]]},
          scale_factors: %{optional(String.t()) => [float()]}
        }

  @doc """
  Every graph in memory as a set of paths to test, Monty's
  `get_initial_hypotheses`.

  A node alone is a path of one, which is where a match can be at the very first
  step; an edge is the path of two the next step extends. Both are keyed by
  graph, because a match is per object.
  """
  @spec get_initial_hypotheses(GraphMemory.t()) :: hypotheses()
  def get_initial_hypotheses(%GraphMemory{} = memory) do
    graph_ids = GraphMemory.get_memory_ids(memory)

    %{
      possible_matches: GraphMemory.get_all_models_in_memory(memory),
      possible_paths: Map.new(graph_ids, &{&1, nodes_in(memory, &1)}),
      next_possible_paths: Map.new(graph_ids, &{&1, edges_in(memory, &1)}),
      scale_factors: Map.new(graph_ids, &{&1, scale_factors_in(memory, &1)})
    }
  end

  # The first channel, as Monty reads it: a path is a list of node ids, and a
  # node id means the same thing in every channel of one graph.
  defp first_channel(memory, graph_id),
    do: memory |> GraphMemory.get_input_channels_in_graph(graph_id) |> hd()

  defp nodes_in(memory, graph_id),
    do: GraphMemory.get_graph_node_ids(memory, graph_id, first_channel(memory, graph_id))

  defp edges_in(memory, graph_id) do
    {sources, targets} = memory |> graph(graph_id) |> Map.fetch!(:edge_index)

    sources
    |> Enum.zip(targets)
    |> Enum.map(fn {source, target} -> [source, target] end)
  end

  # The whole displacement of an edge is stored; Monty keeps its first component
  # as the scale factor, which is the length along the model's own x axis.
  defp scale_factors_in(memory, graph_id) do
    memory
    |> graph(graph_id)
    |> Map.get(:edge_attr, [])
    |> Enum.map(fn displacement -> hd(displacement) * 1.0 end)
  end

  defp graph(memory, graph_id) do
    memory
    |> GraphMemory.get_graph(graph_id, first_channel(memory, graph_id))
    |> GraphObjectModel.graph()
  end
end
