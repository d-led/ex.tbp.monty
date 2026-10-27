defmodule Monty.Frameworks.Models.GraphMatching.GraphMemory do
  @moduledoc """
  A library of object models, with a librarian.

  Mirrors `tbp/monty/frameworks/models/graph_matching.py::GraphMemory`. Memory
  holds one model per `graph_id`, each of which holds one graph per input
  channel — a mug seen through a patch sensor and through a view finder is one
  object with two graphs, and they are matched separately.

  Alongside the models it keeps, per graph and channel, the same features laid
  out as rows (`feature_array`) with the names of those columns
  (`feature_order`). That is a cache, not a second truth: matching compares one
  observation against every node at once, and doing it column-wise is what makes
  that affordable — Monty's own note calls the per-node loop one of the three
  slowest things in the loop.

  ## What is a `nil` here

  Monty pre-fills the feature array with NaN so a node that lacks a feature is
  distinguishable from a node whose feature is zero. This port keeps that
  distinction by keeping `nil` for a missing value rather than by filling a
  buffer: a node with no stored value has no evidence (see
  `...FeatureEvidence.Calculator`), which is exactly what the NaN was for.

  ## Where the layout comes from

  Monty reads the column order from the first node's feature dictionary, which
  in Python is insertion-ordered. An Elixir map has a stable but not
  insertion-based order, so the order here is the map's — returned alongside the
  array, never assumed by a caller, and therefore identical in effect.
  """

  require Logger

  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Frameworks.Utils.SpatialArithmetics

  @pose_features ["pose_vectors", "pose_fully_defined"]

  defstruct graph_delta_thresholds: nil,
            k: nil,
            models_in_memory: %{},
            feature_array: %{},
            feature_order: %{},
            features_to_use: %{}

  @type graph_id :: String.t()
  @type input_channel :: String.t()
  @type t :: %__MODULE__{}

  @doc """
  An empty memory.

  `:graph_delta_thresholds` decides when two observations are different enough
  to both be stored; `:k` how many neighbours each new node links to.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      graph_delta_thresholds: Keyword.get(options, :graph_delta_thresholds),
      k: Keyword.get(options, :k),
      features_to_use: Keyword.get(options, :features_to_use, %{})
    }
  end

  @doc """
  Add an observation to the graph it belongs to, building it if it is new.

  `graph_id` of `nil` means recognition did not settle on an object in time, and
  a memory that learns from a guess is worse than one that learns nothing, so
  nothing is stored.
  """
  @spec update_memory(
          t(),
          [[number()]],
          %{optional(input_channel()) => map()},
          graph_id() | nil,
          [number()],
          [number()],
          Monty.Geometry.Rotation.t()
        ) ::
          t()
  def update_memory(
        %__MODULE__{} = memory,
        _locations,
        _features,
        nil,
        _object_location_rel_body,
        _location_rel_model,
        _object_rotation
      ) do
    Logger.info("no match found in time, not updating memory")
    memory
  end

  def update_memory(
        %__MODULE__{} = memory,
        locations,
        features,
        graph_id,
        object_location_rel_body,
        location_rel_model,
        object_rotation
      ) do
    Enum.reduce(features, memory, fn {input_channel, channel_features}, memory ->
      {channel_features, channel_locations} =
        extract_entries_with_content(channel_features, locations)

      if graph_id in get_memory_ids(memory) and
           input_channel in get_input_channels_in_graph(memory, graph_id) do
        Logger.info("#{graph_id} already in memory, extending #{input_channel}")

        extend_graph(
          memory,
          channel_locations,
          channel_features,
          graph_id,
          input_channel,
          object_location_rel_body,
          location_rel_model,
          object_rotation
        )
      else
        Logger.info("#{graph_id} not in memory for #{input_channel}, building it")
        build_graph(memory, channel_locations, channel_features, graph_id, input_channel)
      end
    end)
  end

  @doc """
  Rebuild the feature rows and column names for every graph in memory.
  """
  @spec initialize_feature_arrays(t()) :: t()
  def initialize_feature_arrays(%__MODULE__{} = memory) do
    Enum.reduce(get_memory_ids(memory), memory, fn graph_id, memory ->
      channels = get_input_channels_in_graph(memory, graph_id)

      {arrays, orders} =
        Enum.reduce(channels, {%{}, %{}}, fn input_channel, {arrays, orders} ->
          {rows, order} = all_node_features(memory, graph_id, input_channel)
          {Map.put(arrays, input_channel, rows), Map.put(orders, input_channel, order)}
        end)

      memory
      |> put_in([Access.key(:feature_array), graph_id], arrays)
      |> put_in([Access.key(:feature_order), graph_id], orders)
    end)
  end

  @doc """
  The models stored for `graph_id`: a map of input channel to model.

  With an `input_channel` of `:first`, one channel is picked arbitrarily — it is
  a placeholder for callers that need a graph rather than a particular channel,
  and Monty makes the same arbitrary choice.
  """
  @spec get_graph(t(), graph_id(), input_channel() | :first | nil) ::
          %{optional(input_channel()) => GraphObjectModel.t()} | GraphObjectModel.t()
  def get_graph(%__MODULE__{models_in_memory: models}, graph_id, nil),
    do: Map.fetch!(models, graph_id)

  def get_graph(%__MODULE__{} = memory, graph_id, :first) do
    memory
    |> get_input_channels_in_graph(graph_id)
    |> hd()
    |> then(&get_graph(memory, graph_id, &1))
  end

  def get_graph(%__MODULE__{} = memory, graph_id, input_channel) do
    if input_channel in get_input_channels_in_graph(memory, graph_id) do
      memory.models_in_memory |> Map.fetch!(graph_id) |> Map.fetch!(input_channel)
    else
      raise ArgumentError, "#{graph_id} has no data stored for #{input_channel}"
    end
  end

  @doc "The feature rows for a graph and channel, as `{rows, column_order}`."
  @spec get_feature_array(t(), graph_id(), input_channel()) :: [[float() | nil]]
  def get_feature_array(%__MODULE__{feature_array: arrays}, graph_id, input_channel) do
    arrays |> Map.fetch!(graph_id) |> Map.fetch!(input_channel)
  end

  @doc "The feature names, in the order their columns appear."
  @spec get_feature_order(t(), graph_id(), input_channel()) :: [String.t()]
  def get_feature_order(%__MODULE__{feature_order: orders}, graph_id, input_channel) do
    orders |> Map.fetch!(graph_id) |> Map.fetch!(input_channel)
  end

  @doc "The node locations of a graph."
  @spec get_locations_in_graph(t(), graph_id(), input_channel()) :: [[float()]]
  def get_locations_in_graph(%__MODULE__{} = memory, graph_id, input_channel) do
    memory |> get_graph(graph_id, input_channel) |> GraphObjectModel.positions()
  end

  @doc "Every model in memory, by object id."
  @spec get_all_models_in_memory(t()) :: %{optional(graph_id()) => map()}
  def get_all_models_in_memory(%__MODULE__{models_in_memory: models}), do: models

  @doc """
  What a learning module starts from: every object in memory, and no paths yet.

  At the first step nothing is ruled out, so every stored object is a candidate;
  the hypotheses get narrowed by evidence from there.
  """
  @spec get_initial_hypotheses(t()) :: {%{optional(graph_id()) => map()}, map()}
  def get_initial_hypotheses(%__MODULE__{} = memory) do
    {get_all_models_in_memory(memory), %{}}
  end

  @doc "The ids of every object in memory."
  @spec get_memory_ids(t()) :: [graph_id()]
  def get_memory_ids(%__MODULE__{models_in_memory: models}), do: Map.keys(models)

  @doc "The input channels a graph stores."
  @spec get_input_channels_in_graph(t(), graph_id()) :: [input_channel()]
  def get_input_channels_in_graph(%__MODULE__{models_in_memory: models}, graph_id) do
    models |> Map.fetch!(graph_id) |> Map.keys()
  end

  @doc "The node ids of a graph: `0..num_nodes-1`."
  @spec get_graph_node_ids(t(), graph_id(), input_channel()) :: [non_neg_integer()]
  def get_graph_node_ids(%__MODULE__{} = memory, graph_id, input_channel) do
    count =
      memory
      |> get_graph(graph_id, input_channel)
      |> GraphObjectModel.num_nodes()

    Enum.to_list(0..(count - 1)//1)
  end

  @doc """
  How many nodes a graph has — summed over its channels when none is named.
  """
  @spec get_num_nodes_in_graph(t(), graph_id(), input_channel() | nil) :: non_neg_integer()
  def get_num_nodes_in_graph(%__MODULE__{} = memory, graph_id, nil) do
    memory
    |> get_input_channels_in_graph(graph_id)
    |> Enum.reduce(0, fn input_channel, total ->
      total + get_num_nodes_in_graph(memory, graph_id, input_channel)
    end)
  end

  def get_num_nodes_in_graph(%__MODULE__{} = memory, graph_id, input_channel) do
    memory |> get_graph(graph_id, input_channel) |> GraphObjectModel.num_nodes()
  end

  @doc """
  The features stored at one node, or at each of several nodes.

  `feature_keys` of `nil` uses the channel's configured features, which is how
  the learning module reads a node; naming keys reads exactly those, which is
  how a caller asks for one feature without knowing the rest.
  """
  @spec get_features_at_node(
          t(),
          graph_id(),
          input_channel(),
          non_neg_integer() | [non_neg_integer()],
          [String.t()] | nil
        ) :: %{optional(String.t()) => [float()] | [[float()]]}
  def get_features_at_node(
        %__MODULE__{} = memory,
        graph_id,
        input_channel,
        node_ids,
        feature_keys \\ nil
      ) do
    keys = feature_keys || Map.fetch!(memory.features_to_use, input_channel)
    graph = get_graph(memory, graph_id, input_channel)

    values =
      Map.new(keys, fn key -> {key, GraphObjectModel.get_values_for_feature(graph, key)} end)

    case node_ids do
      node_id when is_integer(node_id) ->
        Map.new(values, fn {key, rows} -> {key, Enum.at(rows, node_id)} end)

      node_ids ->
        Map.new(values, fn {key, rows} -> {key, Enum.map(node_ids, &Enum.at(rows, &1))} end)
    end
  end

  @doc """
  The pose vectors stored at every node of a graph, one 3×3 set per node.

  A burst samples rotations by aligning these against what the sensor sees, so
  it wants the whole set in one place rather than a node at a time — Monty's
  `get_rotation_features_at_all_nodes`, which reshapes the flattened pose
  vectors back into the three directions they are.
  """
  @spec get_rotation_features_at_all_nodes(t(), graph_id(), input_channel()) :: [
          [SpatialArithmetics.vector()]
        ]
  def get_rotation_features_at_all_nodes(%__MODULE__{} = memory, graph_id, input_channel) do
    memory
    |> get_features_at_node(
      graph_id,
      input_channel,
      get_graph_node_ids(memory, graph_id, input_channel),
      [
        "pose_vectors"
      ]
    )
    |> Map.fetch!("pose_vectors")
    |> Enum.map(&Enum.chunk_every(&1, 3))
  end

  @doc "The number of objects in memory."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = memory), do: memory |> get_memory_ids() |> length()

  @doc "The models, as something that can be saved and reloaded."
  @spec state_dict(t()) :: %{optional(graph_id()) => map()}
  def state_dict(%__MODULE__{models_in_memory: models}), do: models

  @doc """
  Replace the contents of memory with a saved set of models.

  This is how a pretrained memory arrives: every object is added as it was
  stored, and nothing is rebuilt.
  """
  @spec load_state_dict(t(), %{optional(graph_id()) => map()}) :: t()
  def load_state_dict(%__MODULE__{} = memory, memento) do
    Logger.info("loading #{map_size(memento)} model(s) into memory")

    Enum.reduce(memento, memory, fn {graph_id, model}, memory ->
      add_graph_to_memory(memory, model, graph_id)
    end)
  end

  @doc "Store a model under `graph_id`, replacing anything with that id."
  @spec add_graph_to_memory(t(), map(), graph_id()) :: t()
  def add_graph_to_memory(%__MODULE__{} = memory, model, graph_id) do
    put_in(memory, [Access.key(:models_in_memory), graph_id], model)
  end

  @doc "Forget an object."
  @spec remove_graph_from_memory(t(), graph_id()) :: t()
  def remove_graph_from_memory(%__MODULE__{} = memory, graph_id) do
    update_in(memory.models_in_memory, &Map.delete(&1, graph_id))
  end

  @doc """
  Build a graph for a channel that memory has nothing for yet.

  No edges are added here: a graph grows observation by observation, and edges
  are what `update_memory/7` adds once there is a model to compare against.
  """
  @spec build_graph(t(), [[number()]], map(), graph_id(), input_channel()) :: t()
  def build_graph(%__MODULE__{} = memory, locations, features, graph_id, input_channel) do
    model =
      GraphObjectModel.new(graph_id)
      |> GraphObjectModel.build_model(
        locations,
        features,
        nil,
        thresholds_for(memory, input_channel)
      )

    memory
    |> put_in(
      [Access.key(:models_in_memory), graph_id],
      Map.get(memory.models_in_memory, graph_id, %{})
    )
    |> put_in([Access.key(:models_in_memory), graph_id, input_channel], model)
    |> then(fn memory ->
      Logger.info("added graph #{graph_id} for #{input_channel}")
      memory
    end)
  end

  @doc """
  Add observations to a graph that already exists for this channel.

  The new observations are in the body's frame; they are transformed into the
  model's using the two reference points and the detected rotation.
  """
  @spec extend_graph(
          t(),
          [[number()]],
          map(),
          graph_id(),
          input_channel(),
          [number()],
          [number()],
          Monty.Geometry.Rotation.t()
        ) ::
          t()
  def extend_graph(
        %__MODULE__{} = memory,
        locations,
        features,
        graph_id,
        input_channel,
        object_location_rel_body,
        location_rel_model,
        object_rotation
      ) do
    model =
      memory
      |> get_graph(graph_id, input_channel)
      |> GraphObjectModel.update_model(
        locations,
        features,
        location_rel_model,
        object_location_rel_body,
        object_rotation
      )

    put_in(memory, [Access.key(:models_in_memory), graph_id, input_channel], model)
  end

  defp thresholds_for(%__MODULE__{graph_delta_thresholds: nil}, _input_channel), do: nil

  defp thresholds_for(%__MODULE__{graph_delta_thresholds: thresholds}, input_channel),
    do: Map.fetch!(thresholds, input_channel)

  # Every node's features, packed into rows in one order — the layout the
  # calculator compares against. Pose features are left out: they are matched as
  # poses, elsewhere.
  defp all_node_features(memory, graph_id, input_channel) do
    nodes = get_graph_node_ids(memory, graph_id, input_channel)

    per_node =
      Enum.map(nodes, fn node_id ->
        memory
        |> get_features_at_node(graph_id, input_channel, node_id)
        |> Map.drop(@pose_features)
      end)

    order = per_node |> hd() |> Map.keys()
    rows = Enum.map(per_node, fn features -> Enum.flat_map(order, &Map.fetch!(features, &1)) end)

    {rows, order}
  end

  # An observation with no content for this channel (a sensor that saw nothing)
  # must not be learned from.
  defp extract_entries_with_content(features, locations) do
    # `false` means the pose was not defined at that step, and `nil` is this
    # port's NaN; both mean there is nothing to learn from.
    present =
      features
      |> Map.fetch!("pose_fully_defined")
      |> Enum.map(&(&1 not in [nil, false]))

    kept_features =
      Map.new(features, fn {feature, values} ->
        {feature,
         values
         |> Enum.zip(present)
         |> Enum.filter(fn {_, keep?} -> keep? end)
         |> Enum.map(fn {value, _} -> value end)}
      end)

    kept_locations =
      locations
      |> Enum.zip(present)
      |> Enum.filter(fn {_, keep?} -> keep? end)
      |> Enum.map(fn {location, _} -> location end)

    {kept_features, kept_locations}
  end
end
