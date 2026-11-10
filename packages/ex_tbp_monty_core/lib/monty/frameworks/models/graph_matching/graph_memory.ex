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

  alias Monty.Frameworks.Models.ObjectModel
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Frameworks.Utils.SpatialArithmetics

  @pose_features ["pose_vectors", "pose_fully_defined"]

  defstruct graph_delta_thresholds: nil,
            k: nil,
            object_model: GraphObjectModel,
            object_model_options: [],
            models_in_memory: %{},
            feature_array: %{},
            feature_order: %{},
            feature_rows: %{},
            node_arrays: %{},
            rotation_features: %{},
            features_to_use: %{}

  @type graph_id :: String.t()
  @type input_channel :: String.t()
  @type t :: %__MODULE__{}

  @doc """
  An empty memory.

  `:graph_delta_thresholds` decides when two observations are different enough
  to both be stored; `:k` how many neighbours each new node links to.

  `:object_model` is the kind of model memory stores — a graph of every
  observation, or a grid thinned into one — and `:object_model_options` is what
  that kind was configured with. Monty spells the same choice as a subclass;
  here it is a module and a keyword list, so nothing has to know which model it
  is holding.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      graph_delta_thresholds: Keyword.get(options, :graph_delta_thresholds),
      k: Keyword.get(options, :k),
      object_model: Keyword.get(options, :object_model, GraphObjectModel),
      object_model_options: Keyword.get(options, :object_model_options, []),
      features_to_use: Keyword.get(options, :features_to_use, %{})
    }
  end

  @doc """
  Add an observation to the graph it belongs to, building it if it is new.

  `graph_id` of `nil` means recognition did not settle on an object in time, and
  a memory that learns from a guess is worse than one that learns nothing, so
  nothing is stored.

  How each channel's data is handled falls into one of three cases, and the third
  is the one that is easy to get wrong:

    1. unknown object — the points are stored as they came, untransformed;
    2. known object, known channel — the graph is extended, which transforms the
       points into the model's own frame on the way in (`extend_graph/8`);
    3. known object, **unknown channel** — a channel first seen in a later
       episode. It has no graph to be extended, and building one from the
       untransformed points puts the new channel in the body's frame while every
       other channel of that object is in the model's: the two then never line up,
       which is the misalignment of Monty's PR #1280. So the points are
       transformed here, through the object's detected rotation, before the graph
       is built.

  Whether the object is known is decided once, before the loop: a channel this
  call adds must not make the object look like it already had a reference frame
  for the channels after it (Monty's own note on the same bug).
  """
  @spec update_memory(
          t(),
          [[number()]],
          %{optional(input_channel()) => map()},
          graph_id() | nil,
          [number()],
          [number()],
          Monty.Geometry.Rotation.t() | nil
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
    object_known? = graph_id in get_memory_ids(memory)

    Logger.info(
      if(object_known?,
        do: "#{graph_id} already in memory (#{inspect(get_memory_ids(memory))})",
        else: "#{graph_id} not in memory (#{inspect(get_memory_ids(memory))})"
      )
    )

    Enum.reduce(features, memory, fn {input_channel, channel_features}, memory ->
      {channel_features, channel_locations} =
        extract_entries_with_content(channel_features, locations)

      cond do
        not object_known? ->
          build_graph(memory, channel_locations, channel_features, graph_id, input_channel)

        input_channel in get_input_channels_in_graph(memory, graph_id) ->
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

        true ->
          {channel_locations, channel_features} =
            transform_new_channel(
              channel_locations,
              channel_features,
              graph_id,
              input_channel,
              object_location_rel_body,
              location_rel_model,
              object_rotation
            )

          build_graph(memory, channel_locations, channel_features, graph_id, input_channel)
      end
    end)
  end

  # A channel of a known object, seen for the first time: the points have to
  # reach the model's reference frame before they become nodes, or this channel
  # will sit in a frame of its own.
  defp transform_new_channel(
         channel_locations,
         channel_features,
         graph_id,
         input_channel,
         _object_location_rel_body,
         _location_rel_model,
         nil
       ) do
    Logger.warning(
      "No object rotation for #{graph_id}; adding new channel #{input_channel} " <>
        "without transforming it into the object's reference frame."
    )

    {channel_locations, channel_features}
  end

  defp transform_new_channel(
         channel_locations,
         channel_features,
         _graph_id,
         _input_channel,
         object_location_rel_body,
         location_rel_model,
         object_rotation
       ) do
    SpatialArithmetics.apply_rf_transform_to_points(
      channel_locations,
      channel_features,
      location_rel_model,
      object_location_rel_body,
      object_rotation
    )
  end

  @doc """
  Ensures every graph's feature rows and column names are present.

  A pretrained library is read once and its rows travel with the memory, so the
  learning module's `reset_stm/1` — which asks for the rows at the start of
  *every* episode, Monty's own order — finds them already there. Only rows that
  are missing are built, and rows go missing in exactly one way: a graph is
  written (`add_graph_to_memory/3`, `build_graph/5`, `extend_graph/8`), which
  drops the rows derived from it. A count is not that signal — a graph replaced
  by one of the same size has rows that name the old nodes.

  This is not only an optimisation. A seventy-seven-object library is a hundred
  and fifty thousand nodes, and building their rows takes minutes; an experiment
  of three rotations would spend those minutes two hundred and thirty times.
  """
  @spec initialize_feature_arrays(t()) :: t()
  def initialize_feature_arrays(%__MODULE__{} = memory) do
    Enum.reduce(get_memory_ids(memory), memory, fn graph_id, memory ->
      Enum.reduce(get_input_channels_in_graph(memory, graph_id), memory, fn input_channel,
                                                                            memory ->
        build_rows_if_missing(memory, graph_id, input_channel)
      end)
    end)
  end

  defp build_rows_if_missing(memory, graph_id, input_channel) do
    if Map.has_key?(channels(memory.feature_array, graph_id), input_channel) do
      memory
    else
      {rows, order} = all_node_features(memory, graph_id, input_channel)

      %{
        memory
        | feature_array: put_channel(memory.feature_array, graph_id, input_channel, rows),
          feature_order: put_channel(memory.feature_order, graph_id, input_channel, order),
          feature_rows:
            put_channel(
              memory.feature_rows,
              graph_id,
              input_channel,
              cacheable_rows(rows)
            ),
          node_arrays:
            put_channel(
              memory.node_arrays,
              graph_id,
              input_channel,
              node_arrays(memory, graph_id, input_channel)
            ),
          rotation_features:
            put_channel(
              memory.rotation_features,
              graph_id,
              input_channel,
              rotation_features(memory, graph_id, input_channel)
            )
      }
    end
  end

  @doc """
  Where every node is, how its frame sits, and whether that frame was defined —
  as the bytes a kernel reads.

  `{locations, poses, defined}`, each a binary: three f64 a node for its
  position, six for its normal and first curvature direction, one for whether the
  pose was fully defined. `nil` when a graph has no frames to read, which is a
  graph the evidence kernel cannot be handed at all.

  Written where the feature rows are written, and forgotten where they are
  forgotten: all of it is what the graphs hold when an episode starts, and none of
  it changes while one is being matched.
  """
  @spec get_node_arrays(t(), graph_id(), input_channel()) ::
          {binary(), binary(), binary()} | nil
  def get_node_arrays(%__MODULE__{node_arrays: arrays}, graph_id, input_channel) do
    arrays |> Map.get(graph_id, %{}) |> Map.get(input_channel)
  end

  # A graph that does not store both halves of a frame has no arrays to read, and
  # keeps the reference path — a model built from a fixture with only some of the
  # features is exactly that.
  defp node_arrays(%__MODULE__{} = memory, graph_id, input_channel) do
    graph = get_graph(memory, graph_id, input_channel)

    read? =
      memory.object_model.has_feature?(graph, "pose_vectors") and
        memory.object_model.has_feature?(graph, "pose_fully_defined")

    if read?, do: frame_arrays(memory, graph)
  end

  defp frame_arrays(memory, graph) do
    positions = memory.object_model.positions(graph)
    poses = memory.object_model.get_values_for_feature(graph, "pose_vectors")
    defined = memory.object_model.get_values_for_feature(graph, "pose_fully_defined")

    with [_ | _] <- positions,
         true <- Enum.all?(positions, &match?([_, _, _], &1)),
         true <- length(poses) == length(positions),
         true <- Enum.all?(poses, &match?([_, _, _, _, _, _ | _], &1)),
         true <- length(defined) == length(positions) do
      {flatten(positions, 3), pose_bytes(poses), defined_bytes(defined)}
    else
      _nothing_to_read -> nil
    end
  end

  defp pose_bytes(poses) do
    poses
    |> Enum.map(fn [n1, n2, n3, d1, d2, d3 | _unread] ->
      <<n1 * 1.0::float-64-little, n2 * 1.0::float-64-little, n3 * 1.0::float-64-little,
        d1 * 1.0::float-64-little, d2 * 1.0::float-64-little, d3 * 1.0::float-64-little>>
    end)
    |> IO.iodata_to_binary()
  end

  # `0.0` is a pose that was not defined, and anything else — including the `nil`
  # a recording may carry — is one that was, which is how the comparison reads a
  # stored flag (`elem(flags, id) != 0.0`).
  defp defined_bytes(defined) do
    defined
    |> Enum.map(fn [flag | _rest] ->
      if flag == 0.0, do: <<0.0::float-64-little>>, else: <<1.0::float-64-little>>
    end)
    |> IO.iodata_to_binary()
  end

  defp flatten(rows, width) do
    values =
      for row <- rows, value <- Enum.take(row, width), into: <<>> do
        <<value * 1.0::float-64-little>>
      end

    values
  end

  # The flat rows are read as a rectangle of values, so only a rectangle of
  # values is cached: rows of different widths would have the kernel read one
  # node's values as another's, and rows of no width at all are not a rectangle
  # of nothing — they are nodes whose features could not be read, and the
  # reference answers `nil` for each of them. A graph that is either keeps the
  # rows it has and the comparison it has always done.
  defp cacheable_rows([]), do: flatten_rows([])

  defp cacheable_rows(rows) do
    widths = rows |> Enum.map(&length/1) |> Enum.uniq()

    case widths do
      [width] when width > 0 -> {elem(flatten_rows(rows), 0), width}
      _ragged_or_empty -> nil
    end
  end

  @doc """
  The rows as one flat binary of little-endian f64, with the width of a row.

  The same bytes a native kernel reads: one row after another, with a NaN where
  a node has no value — Monty pre-fills a missing feature with NaN, which is what
  `nil` means here. `{<<>>, 0}` for no rows. Rows are written where they are
  built, which is why a reader never rebuilds them: a step reads the same bytes
  once per node, and the rows do not change while an episode is being matched.
  """
  @spec flatten_rows([[number() | nil]]) :: {binary(), non_neg_integer()}
  def flatten_rows([]), do: {<<>>, 0}

  # A missing value is the IEEE quiet NaN, byte for byte. It is written as bits
  # rather than as a float because Erlang has no NaN: the pattern is not a value
  # the syntax can build, only bytes a kernel can read.
  @missing <<0x7FF8_0000_0000_0000::little-64>>

  def flatten_rows([first | _rest] = rows) do
    width = length(first)

    binary =
      for row <- rows, value <- row, into: <<>> do
        case value do
          nil -> @missing
          number -> <<number * 1.0::float-64-little>>
        end
      end

    {binary, width}
  end

  defp put_channel(by_graph, graph_id, input_channel, value) do
    Map.update(by_graph, graph_id, %{input_channel => value}, fn channels ->
      Map.put(channels, input_channel, value)
    end)
  end

  defp channels(by_graph, graph_id), do: Map.get(by_graph, graph_id, %{})

  # The rows of a graph are its nodes' features in its own order, so writing the
  # graph is what makes them wrong. Every writer says so here, and a reader that
  # finds rows takes them as current.
  defp forget_rows(memory, graph_id, input_channel) do
    %{
      memory
      | feature_array: drop_channel(memory.feature_array, graph_id, input_channel),
        feature_order: drop_channel(memory.feature_order, graph_id, input_channel),
        feature_rows: drop_channel(memory.feature_rows, graph_id, input_channel),
        node_arrays: drop_channel(memory.node_arrays, graph_id, input_channel),
        rotation_features:
          drop_channel(memory.rotation_features, graph_id, input_channel)
    }
  end

  defp forget_rows(memory, graph_id) do
    %{
      memory
      | feature_array: Map.delete(memory.feature_array, graph_id),
        feature_order: Map.delete(memory.feature_order, graph_id),
        feature_rows: Map.delete(memory.feature_rows, graph_id),
        node_arrays: Map.delete(memory.node_arrays, graph_id),
        rotation_features: Map.delete(memory.rotation_features, graph_id)
    }
  end

  defp drop_channel(by_graph, graph_id, input_channel) do
    Map.update(by_graph, graph_id, %{}, &Map.delete(&1, input_channel))
  end

  @doc """
  The models stored for `graph_id`: a map of input channel to model.

  With an `input_channel` of `:first`, one channel is picked arbitrarily — it is
  a placeholder for callers that need a graph rather than a particular channel,
  and Monty makes the same arbitrary choice.
  """
  @spec get_graph(t(), graph_id(), input_channel() | :first | nil) ::
          %{optional(input_channel()) => ObjectModel.model()} | ObjectModel.model()
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

  @doc """
  The same rows as one flat binary of little-endian f64, with the width of a row.

  `nil` is a NaN, which is the missing value Monty pre-fills with. `nil` when no
  rows have been built for the graph yet, which is a graph that has never been
  asked for its features.
  """
  @spec get_feature_rows(t(), graph_id(), input_channel()) ::
          {binary(), non_neg_integer()} | nil
  def get_feature_rows(%__MODULE__{feature_rows: rows}, graph_id, input_channel) do
    rows |> Map.get(graph_id, %{}) |> Map.get(input_channel)
  end

  @doc "The node locations of a graph."
  @spec get_locations_in_graph(t(), graph_id(), input_channel()) :: [[float()]]
  def get_locations_in_graph(%__MODULE__{} = memory, graph_id, input_channel) do
    memory.object_model.positions(get_graph(memory, graph_id, input_channel))
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
    count = memory.object_model.num_nodes(get_graph(memory, graph_id, input_channel))

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
    memory.object_model.num_nodes(get_graph(memory, graph_id, input_channel))
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
      Map.new(keys, fn key -> {key, memory.object_model.get_values_for_feature(graph, key)} end)

    # A row is looked up by node id, and a caller asking about many nodes asks
    # about every node of a graph often enough that walking the list per id
    # would dominate a matching step. Tuples make the lookup constant.
    case node_ids do
      node_id when is_integer(node_id) ->
        Map.new(values, fn {key, rows} -> {key, rows |> List.to_tuple() |> elem(node_id)} end)

      node_ids ->
        Map.new(values, fn {key, rows} ->
          tuple = List.to_tuple(rows)
          {key, Enum.map(node_ids, &elem(tuple, &1))}
        end)
    end
  end

  @doc """
  The pose vectors stored at every node of a graph, one 3×3 set per node.

  A burst samples rotations by aligning these against what the sensor sees, so
  it wants the whole set in one place rather than a node at a time — Monty's
  `get_rotation_features_at_all_nodes`, which reshapes the flattened pose
  vectors back into the three directions they are.

  Read from the cache the feature rows come with, and from the graph itself when
  a graph holds only some of the features (a model built from a fixture).
  """
  @spec get_rotation_features_at_all_nodes(t(), graph_id(), input_channel()) :: [
          [SpatialArithmetics.vector()]
        ]
  def get_rotation_features_at_all_nodes(%__MODULE__{} = memory, graph_id, input_channel) do
    case cached_rotation_features(memory, graph_id, input_channel) do
      nil ->
        memory
        |> get_graph_node_ids(graph_id, input_channel)
        |> then(&get_rotation_features_at_nodes(memory, graph_id, input_channel, &1))

      rotations ->
        Tuple.to_list(rotations)
    end
  end

  @doc """
  The pose vectors stored at the named nodes, one 3×3 set each.

  The same rows as `get_rotation_features_at_all_nodes/3`, for a chosen few. A
  burst samples rotations from a few hundred nodes of a graph that may hold
  twenty thousand, and reading every node's pose vectors to keep a handful built
  a row list and a tuple for the whole graph on every step, per channel.

  Those rows never change while a graph is being matched — the graph is written
  once per episode at most — so this answers from a cache built when the graph's
  rows were: ten graphs of a ten-object library cost 9.5 ms a step to re-read,
  and 0.2 ms to look up.
  """
  @spec get_rotation_features_at_nodes(t(), graph_id(), input_channel(), [non_neg_integer()]) :: [
          [SpatialArithmetics.vector()]
        ]
  def get_rotation_features_at_nodes(%__MODULE__{} = memory, graph_id, input_channel, node_ids) do
    case cached_rotation_features(memory, graph_id, input_channel) do
      nil ->
        memory
        |> get_features_at_node(graph_id, input_channel, node_ids, ["pose_vectors"])
        |> Map.fetch!("pose_vectors")
        |> Enum.map(&Enum.chunk_every(&1, 3))

      rotations ->
        Enum.map(node_ids, &elem(rotations, &1))
    end
  end

  defp cached_rotation_features(%__MODULE__{rotation_features: cached}, graph_id, input_channel) do
    cached |> Map.get(graph_id, %{}) |> Map.get(input_channel)
  end

  # The pose vectors as the two readers above hand them out: one set of
  # directions per node, in the graph's own order. `nil` for a graph that does
  # not store pose vectors, which keeps the reader's own answer for it.
  defp rotation_features(%__MODULE__{} = memory, graph_id, input_channel) do
    graph = get_graph(memory, graph_id, input_channel)

    if memory.object_model.has_feature?(graph, "pose_vectors") do
      graph
      |> then(&memory.object_model.get_values_for_feature(&1, "pose_vectors"))
      |> Enum.map(&Enum.chunk_every(&1, 3))
      |> List.to_tuple()
    end
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
    memory
    |> put_in([Access.key(:models_in_memory), graph_id], model)
    |> forget_rows(graph_id)
  end

  @doc "Forget an object."
  @spec remove_graph_from_memory(t(), graph_id()) :: t()
  def remove_graph_from_memory(%__MODULE__{} = memory, graph_id) do
    memory
    |> update_in([Access.key(:models_in_memory)], &Map.delete(&1, graph_id))
    |> forget_rows(graph_id)
  end

  @doc """
  Build a graph for a channel that memory has nothing for yet.

  No edges are added here: a graph grows observation by observation, and edges
  are what `update_memory/7` adds once there is a model to compare against.
  """
  @spec build_graph(t(), [[number()]], map(), graph_id(), input_channel()) :: t()
  def build_graph(%__MODULE__{} = memory, locations, features, graph_id, input_channel) do
    model = memory.object_model.new(graph_id, object_model_options(memory, input_channel))

    case memory.object_model.build_model(model, locations, features) do
      {:ok, model} ->
        memory
        |> put_in(
          [Access.key(:models_in_memory), graph_id],
          Map.get(memory.models_in_memory, graph_id, %{})
        )
        |> put_in([Access.key(:models_in_memory), graph_id, input_channel], model)
        |> forget_rows(graph_id, input_channel)
        |> then(fn memory ->
          Logger.info("added graph #{graph_id} for #{input_channel}")
          memory
        end)

      {:error, reason} ->
        Logger.warning(
          "not building #{graph_id} for #{input_channel}: " <>
            "the model cannot hold it (#{inspect(reason)})"
        )

        memory
    end
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
    model = get_graph(memory, graph_id, input_channel)

    case memory.object_model.update_model(
           model,
           locations,
           features,
           location_rel_model,
           object_location_rel_body,
           object_rotation
         ) do
      {:ok, model} ->
        memory
        |> put_in([Access.key(:models_in_memory), graph_id, input_channel], model)
        |> forget_rows(graph_id, input_channel)

      {:error, reason} ->
        Logger.warning(
          "not extending #{graph_id} for #{input_channel}: " <>
            "the model cannot hold it (#{inspect(reason)})"
        )

        memory
    end
  end

  # What memory knows about building one graph: the model's own configuration,
  # plus the two things that are memory's (how many neighbours a node links to,
  # and what counts as a different observation). A model reads the options it
  # has a use for — a grid has no edges and so no `k_n`.
  defp object_model_options(%__MODULE__{} = memory, input_channel) do
    memory.object_model_options ++
      [k_n: memory.k, graph_delta_thresholds: thresholds_for(memory, input_channel)]
  end

  defp thresholds_for(%__MODULE__{graph_delta_thresholds: nil}, _input_channel), do: nil

  defp thresholds_for(%__MODULE__{graph_delta_thresholds: thresholds}, input_channel),
    do: Map.fetch!(thresholds, input_channel)

  # Every node's features, packed into rows in one order — the layout the
  # calculator compares against. Pose features are left out: they are matched as
  # poses, elsewhere.
  #
  # Each feature is read as one column and indexed by node, rather than asking
  # for one node at a time: the per-node answer rebuilds the whole column tuple
  # on every call, which is quadratic in a graph's size and minutes on a library
  # of seventy-seven objects.
  defp all_node_features(memory, graph_id, input_channel) do
    nodes = get_graph_node_ids(memory, graph_id, input_channel)
    graph = get_graph(memory, graph_id, input_channel)

    order =
      memory.features_to_use
      |> Map.fetch!(input_channel)
      |> Enum.reject(&(&1 in @pose_features))

    columns =
      Map.new(order, fn key ->
        {key, graph |> memory.object_model.get_values_for_feature(key) |> List.to_tuple()}
      end)

    rows =
      Enum.map(nodes, fn node_id ->
        Enum.flat_map(order, fn key -> elem(Map.fetch!(columns, key), node_id) end)
      end)

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
