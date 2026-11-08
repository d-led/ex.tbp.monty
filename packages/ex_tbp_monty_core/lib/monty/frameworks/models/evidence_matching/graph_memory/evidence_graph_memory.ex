defmodule Monty.Frameworks.Models.EvidenceMatching.GraphMemory.EvidenceGraphMemory do
  @moduledoc """
  Memory that stores grid models, which is what an evidence-based learning
  module learns into.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/graph_memory.py
  ::EvidenceGraphMemory`, whose whole content is a different object model plus
  what follows from it. Evidence matching compares one observation against every
  node of every object at once, so memory that stored every observation as a
  node would be both slow and enormous; the grid keeps a bounded number of
  nodes per object and is the reason a pretrained YCB model fits in memory at
  all.

  ## Inheritance became configuration

  In Python this class exists to subclass `GraphMemory` and override the three
  places where a model is constructed — build, extend, and load. There is no
  inheritance to override in Elixir, and there does not need to be: memory
  already takes the object model as a module and its options as a keyword list,
  so the same three places build a `GridObjectModel` when memory is made here
  and a `GraphObjectModel` when it is made by `GraphMemory.new/1` directly. One
  struct, one set of functions, two configurations.

  ## What the three numbers mean

    * `:max_nodes_per_graph` — how many nodes an object thins down to, which
      bounds the cost of every matching step;
    * `:max_graph_size` — how large an object may be, in metres, before the
      model refuses it with `GridTooSmallError`;
    * `:num_model_voxels_per_dim` — the resolution, hence the smallest detail a
      model can hold: `max_graph_size / num_model_voxels_per_dim` per voxel.
  """

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GridObjectModel

  @doc """
  An empty memory of grid models, configured by the three numbers Monty's
  learning-module config sets.
  """
  @spec new(keyword()) :: GraphMemory.t()
  def new(options \\ []) do
    GraphMemory.new(
      Keyword.merge(
        Keyword.take(options, [:graph_delta_thresholds, :k, :features_to_use]),
        object_model: GridObjectModel,
        object_model_options: [
          max_nodes: Keyword.get(options, :max_nodes_per_graph, 2000),
          max_size: Keyword.get(options, :max_graph_size, 0.3),
          num_voxels_per_dim: Keyword.get(options, :num_model_voxels_per_dim, 50)
        ]
      )
    )
  end

  @doc """
  What a learning module starts from: the id of every object in memory.

  Nothing is ruled out at the first step, so every stored object is a candidate.
  Monty's base memory answers with its models instead; evidence matching wants
  ids, because its hypotheses are per object and its evidence lives per graph.
  """
  @spec get_initial_hypotheses(GraphMemory.t()) :: [GraphMemory.graph_id()]
  def get_initial_hypotheses(%GraphMemory{} = memory), do: GraphMemory.get_memory_ids(memory)
end
