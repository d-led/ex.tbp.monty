defmodule Monty.Frameworks.Models.FeatureLocationMatching.FeatureGraphMemory do
  @moduledoc """
  Monty's `FeatureGraphMemory`: the same library, read by feature.

  The feature-at-location module matches an observation in two questions. Which
  nodes could I be standing on — that is this module's `match_all_node_features`
  — and, once a pose is being tested, does the pose agree. The first question is
  what narrows a graph of twenty thousand nodes to the handful worth walking
  from, so it is asked of the whole graph at once.

  ## Why this is a module of functions and not a second struct

  Monty spells the difference as a subclass, and the difference is four
  functions: hypotheses with poses in them, a node's frame, the matching nodes,
  and the comparison behind them. Everything else — the models, the feature rows,
  the learning — is `GraphMemory`'s, and a second struct would be the same fields
  with a different name. So `new/1` builds a `GraphMemory` and these functions
  read it, which is the same shape `Monty.Frameworks.Models.GraphMatching.GraphMemory`
  already has for the evidence module's `EvidenceGraphMemory`.

  ## The comparison

  Monty builds two arrays per column — the observed value plus and minus its
  tolerance — and asks numpy whether each node's value lies between them. A
  feature that is *circular* (hue, the first of `hsv`'s three) wraps through 1,
  so a tolerance of 0.1 around 0.05 covers `[0.95, 1]` and `[0, 0.15]` and the
  test becomes "outside" rather than "inside". A node with no stored value has no
  evidence for that column and does not match, which is what Monty's NaN
  pre-fill does.

  ## Where the tolerances come from

  Monty's memory holds `features_to_use` *and* the tolerances, because in Python
  the module assigns its own tolerances to it. This port's memory holds the
  feature **names** it keeps rows for, which is what the evidence kernel reads,
  so the tolerances are passed in by the learning module that owns them — the
  same numbers, in the same place as the config that stated them.
  """

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory

  @doc """
  A memory that can answer which nodes have which features.

  Monty's `FeatureGraphMemory.__init__` takes only the thresholds that decide
  when two observations are the same node; the memory it returns is the base
  one, because there is nothing else to store.
  """
  @spec new(keyword()) :: GraphMemory.t()
  def new(options \\ []), do: GraphMemory.new(options)

  @doc """
  Monty's `FeatureGraphMemory.get_initial_hypotheses`.

  Three answers, not two: every object is possible, every node of it is a place
  to have started — as a *path* of one location, because that is what the next
  step extends — and no pose is ruled out yet.
  """
  @spec get_initial_hypotheses(GraphMemory.t()) ::
          {%{optional(GraphMemory.graph_id()) => map()},
           %{optional(GraphMemory.graph_id()) => [[[float()]]]},
           %{optional(GraphMemory.graph_id()) => []}}
  def get_initial_hypotheses(%GraphMemory{} = memory) do
    possible_matches = GraphMemory.get_all_models_in_memory(memory)

    {possible_paths, possible_poses} =
      Enum.reduce(GraphMemory.get_memory_ids(memory), {%{}, %{}}, fn graph_id, {paths, poses} ->
        channel = memory |> GraphMemory.get_input_channels_in_graph(graph_id) |> hd()

        locations = GraphMemory.get_locations_in_graph(memory, graph_id, channel)

        {
          Map.put(paths, graph_id, Enum.map(locations, &[&1])),
          Map.put(poses, graph_id, [])
        }
      end)

    {possible_matches, possible_paths, possible_poses}
  end

  @doc """
  Monty's `get_rotation_features_at_node`: a node's frame, as three directions.

  The stored pose vectors of one node, shaped as the surface normal and the two
  principal curvature directions — what `align_orthonormal_vectors/2` expects.
  """
  @spec get_rotation_features_at_node(
          GraphMemory.t(),
          GraphMemory.graph_id(),
          non_neg_integer(),
          GraphMemory.input_channel()
        ) :: [[float()]]
  def get_rotation_features_at_node(%GraphMemory{} = memory, graph_id, node_id, channel) do
    memory
    |> GraphMemory.get_rotation_features_at_nodes(graph_id, channel, [node_id])
    |> hd()
  end

  @doc """
  Monty's `get_nodes_with_matching_features`: the nodes worth walking from.

  `:list_of_lists` wraps every location in a list of its own, which is how Monty
  hands back a path that starts on a node — the first observation has no
  displacement behind it, so a path *is* one location.

  Only the first input channel is matched: this module is not used in a
  heterarchy, and Monty says the same in the same place.
  """
  @spec get_nodes_with_matching_features(
          GraphMemory.t(),
          GraphMemory.graph_id(),
          map(),
          map(),
          keyword()
        ) :: {[non_neg_integer()], [[float()]] | [[[float()]]]}
  def get_nodes_with_matching_features(memory, graph_id, features, tolerances, options \\ [])

  def get_nodes_with_matching_features(
        %GraphMemory{} = memory,
        graph_id,
        features,
        tolerances,
        options
      ) do
    channel = features |> Map.keys() |> hd()

    node_ids = GraphMemory.get_graph_node_ids(memory, graph_id, channel)
    locations = GraphMemory.get_locations_in_graph(memory, graph_id, channel)

    indices = match_all_node_features(memory, features, channel, graph_id, tolerances)

    ids = Enum.map(indices, &Enum.at(node_ids, &1))
    matched_locations = Enum.map(indices, &Enum.at(locations, &1))

    if Keyword.get(options, :list_of_lists, false) do
      {ids, Enum.map(matched_locations, &[&1])}
    else
      {ids, matched_locations}
    end
  end

  @doc """
  Monty's `_match_all_node_features`: which nodes could be where I am.

  The answer is the indices of the nodes whose every stored feature lies within
  the observed value's tolerance — the row layout and its column names being the
  memory's own (`feature_order`), which is why the observation is walked in that
  order rather than in the order its features arrive.

  A graph being matched always has rows: they are built when the episode starts,
  which is what `FeatureGraphLM.init_from_ltm/1` does before the first step.
  """
  @spec match_all_node_features(
          GraphMemory.t(),
          map(),
          GraphMemory.input_channel(),
          GraphMemory.graph_id(),
          map()
        ) :: [non_neg_integer()]
  def match_all_node_features(%GraphMemory{} = memory, features, channel, graph_id, tolerances) do
    order = GraphMemory.get_feature_order(memory, graph_id, channel)
    rows = GraphMemory.get_feature_array(memory, graph_id, channel)
    observed = Map.fetch!(features, channel)
    tolerances = Map.fetch!(tolerances, channel)

    windows = column_windows(order, observed, tolerances, channel)

    rows
    |> Enum.with_index()
    |> Enum.filter(fn {row, _index} -> row_matches?(row, windows) end)
    |> Enum.map(fn {_row, index} -> index end)
  end

  # One window per stored column, in the row's own order. A feature with one
  # tolerance for several columns (a scalar `on_object` next to `rgba`'s four
  # numbers) is the same tolerance repeated, which is how numpy broadcasts it.
  defp column_windows(order, observed, tolerances, channel) do
    Enum.flat_map(order, fn name ->
      values = observed |> Map.fetch!(name) |> List.wrap()
      tolerance = Map.fetch!(tolerances, name)
      tolerances_for_columns = tolerance |> List.wrap() |> repeat_to(length(values))

      values
      |> Enum.zip(tolerances_for_columns)
      |> Enum.with_index()
      |> Enum.map(fn {{value, tolerance}, index} ->
        window(value, tolerance, circular?(name, index))
      end)
    end)
  rescue
    KeyError ->
      reraise ArgumentError,
              "the observation carries no #{inspect(channel)} feature a graph stores; " <>
                "a node can only be matched against features the sensor sent",
              __STACKTRACE__
  end

  defp repeat_to([value], count), do: List.duplicate(value, count)
  defp repeat_to(values, _count), do: values

  # Hue is the only circular feature: the first of `hsv`'s three numbers.
  defp circular?("hsv", 0), do: true
  defp circular?(_name, _index), do: false

  # `{low, high, wraps?}`: a circular window that crosses 1 has a low above its
  # high, and is matched from the outside.
  defp window(value, tolerance, false), do: {value - tolerance, value + tolerance, false}

  defp window(value, tolerance, true),
    do: {wrap(value - tolerance), wrap(value + tolerance), true}

  defp wrap(value), do: value - :math.floor(value)

  defp row_matches?(row, windows) do
    row
    |> Enum.zip(windows)
    |> Enum.all?(fn {value, window} -> within?(value, window) end)
  end

  # A node with no stored value is not a match for any window — Monty's NaN,
  # which compares false against everything.
  defp within?(nil, _window), do: false
  defp within?(value, {low, high, true}), do: value >= low or value <= high
  defp within?(value, {low, high, false}), do: value >= low and value <= high
end
