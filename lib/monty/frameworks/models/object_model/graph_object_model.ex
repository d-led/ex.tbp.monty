defmodule Monty.Frameworks.Models.ObjectModel.GraphObjectModel do
  @moduledoc """
  An object model as a graph: one node per distinct observation, edges to the
  nearest neighbours.

  Mirrors `tbp/monty/frameworks/models/object_model.py::GraphObjectModel`.

  ## What a graph is here

  Python builds a `torch_geometric.data.Data`, and Monty's own
  `torch_graph_to_numpy` turns that into a bag of arrays with the same names —
  which is exactly what an Elixir map is, so the port has no graph class to
  invent:

    * `pos` — one `[x, y, z]` per node, in the model's reference frame;
    * `x` — one row per node, the node id in column 0 and then every feature
      laid end to end;
    * `feature_mapping` — feature name to `{first_column, last_column}` (a
      half-open range, as Monty's `x[:, start:end]` is);
    * `norm` — the surface normal of each node, when the features carry pose
      vectors;
    * `edge_index` and `edge_attr` — the neighbour links and the displacement
      from each edge's source to its target.

  ## What is deliberately absent

  `add_ppf_to_graph/1` attaches point-pair features to the edges through
  `torch_geometric`'s transform. Point-pair features belong to displacement
  matching, which this port does not cover, so there is nothing honest to
  translate — the field stays nil and `has_ppf` stays false.
  """

  require Logger

  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Frameworks.Utils.ObjectModelUtils
  alias Monty.Frameworks.Utils.SpatialArithmetics

  @enforce_keys [:object_id]
  defstruct object_id: nil,
            graph: nil,
            k_n: nil,
            graph_delta_thresholds: nil

  @type location :: SpatialArithmetics.vector()
  @type graph :: %{required(atom()) => term()}
  @type t :: %__MODULE__{}

  @doc "A model for `object_id`, with no graph yet."
  @spec new(String.t()) :: t()
  def new(object_id), do: %__MODULE__{object_id: object_id}

  @doc """
  Builds the graph from observations and links each node to its `k_n` nearest
  neighbours.

  `k_n` is asked for as edges, so the neighbour count includes the node itself —
  `GraphMatchingUtils.correct_k_n/2` adjusts it for small graphs — and `nil`
  builds the point cloud without edges.
  """
  @spec build_model(
          t(),
          [location()],
          %{optional(String.t()) => list()},
          pos_integer() | nil,
          map() | nil
        ) ::
          t()
  def build_model(%__MODULE__{} = model, locations, features, k_n, graph_delta_thresholds) do
    graph = build_adjacency_graph(locations, features, k_n, graph_delta_thresholds, 0)

    %{model | graph: graph, k_n: k_n, graph_delta_thresholds: graph_delta_thresholds}
  end

  @doc """
  Adds new observations to the model, in the model's reference frame.

  The new observations arrive in the body's frame; `location_rel_model` and
  `object_location_rel_body` are the same physical spot seen in both, and the
  rotation between them is how the model reconciles the two.
  """
  @spec update_model(
          t(),
          [location()],
          %{optional(String.t()) => list()},
          location(),
          location(),
          Monty.Geometry.Rotation.t()
        ) ::
          t()
  def update_model(
        %__MODULE__{} = model,
        locations,
        features,
        location_rel_model,
        object_location_rel_body,
        object_rotation
      ) do
    {rf_locations, rf_features} =
      SpatialArithmetics.apply_rf_transform_to_points(
        locations,
        features,
        location_rel_model,
        object_location_rel_body,
        object_rotation
      )

    {all_locations, all_features} = combine_graph_information(model, rf_locations, rf_features)

    graph =
      build_adjacency_graph(
        all_locations,
        all_features,
        model.k_n,
        model.graph_delta_thresholds,
        num_nodes(model)
      )

    %{model | graph: graph}
  end

  @doc "The graph itself, or `nil` before the model has been built."
  @spec graph(t()) :: graph() | nil
  def graph(%__MODULE__{graph: graph}), do: graph

  @doc "Replaces the graph, as when a pretrained model is loaded."
  @spec set_graph(t(), graph()) :: t()
  def set_graph(%__MODULE__{} = model, graph), do: %{model | graph: graph}

  @doc "One `[x, y, z]` per node."
  @spec positions(t()) :: [location()]
  def positions(%__MODULE__{graph: %{pos: positions}}), do: positions

  @doc "The number of nodes in the graph."
  @spec num_nodes(t()) :: non_neg_integer()
  def num_nodes(%__MODULE__{graph: %{pos: positions}}), do: length(positions)
  def num_nodes(%__MODULE__{graph: nil}), do: 0

  @doc "The names of the features stored in the graph, `node_ids` included."
  @spec feature_ids_in_graph(t()) :: [String.t()]
  def feature_ids_in_graph(%__MODULE__{graph: %{feature_mapping: mapping}}), do: Map.keys(mapping)

  @doc """
  The columns of `x` holding one feature, as rows.

  Monty hands out `x[:, start:end]`; this hands out the same thing as a list of
  rows, so a caller never has to know the column offsets of anything else.
  """
  @spec get_values_for_feature(t(), String.t()) :: [[float()]]
  def get_values_for_feature(%__MODULE__{graph: %{x: rows, feature_mapping: mapping}}, feature) do
    {first, last} = Map.fetch!(mapping, feature)
    Enum.map(rows, &Enum.slice(&1, first, last - first))
  end

  @doc """
  The index of the edge from `previous_node` to `new_node`, or `nil` if the
  graph does not have one.
  """
  @spec edge_index_between(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer() | nil
  def edge_index_between(
        %__MODULE__{graph: %{edge_index: {sources, targets}}},
        previous_node,
        new_node
      ) do
    sources
    |> Enum.zip(targets)
    |> Enum.find_index(fn {source, target} -> source == previous_node and target == new_node end)
  end

  def edge_index_between(%__MODULE__{graph: %{}}, _previous_node, _new_node), do: nil

  @doc """
  The ids of the `count` nodes nearest each of `search_locations`.

  One list per search location, nearest first, ties going to the lower node id so
  that two runs of the same episode choose the same nodes. Monty asks its grid
  model this question through a `KDTree`; a graph answers it by measuring, which
  is the same answer at the sizes an object model has.
  """
  @spec find_nearest_neighbors(t(), [location()], pos_integer()) :: [[non_neg_integer()]]
  def find_nearest_neighbors(
        %__MODULE__{graph: %{pos: positions}} = model,
        search_locations,
        count
      ) do
    _ = model

    count = min(count, length(positions))

    Enum.map(search_locations, fn search_location ->
      positions
      |> Enum.with_index()
      |> Enum.map(fn {position, index} -> {index, distance(search_location, position)} end)
      |> Enum.sort_by(fn {index, distance} -> {distance, index} end)
      |> Enum.take(count)
      |> Enum.map(fn {index, _distance} -> index end)
    end)
  end

  @doc """
  The existing graph and the new observations, as one point cloud.

  New features become new columns, with zeros for the nodes that never had them
  — which is why a feature that the graph stores but the observation lacks
  raises: padding *that* with zeros would silently claim the sensor saw
  nothing.
  """
  @spec combine_graph_information(t(), [location()], %{optional(String.t()) => list()}) ::
          {[location()], %{optional(String.t()) => [[float()]]}}
  def combine_graph_information(%__MODULE__{graph: nil}, locations, features) do
    {locations, Map.new(features, fn {feature, values} -> {feature, as_rows(values)} end)}
  end

  def combine_graph_information(%__MODULE__{graph: graph}, locations, features) do
    stored_feature_names = graph.feature_mapping |> Map.keys() |> Enum.reject(&(&1 == "node_ids"))

    missing =
      Enum.reject(stored_feature_names, fn feature -> Map.has_key?(features, feature) end)

    if missing != [] do
      # Monty raises `NotImplementedError` here and names the missing feature;
      # the honest Elixir equivalent is an argument error, since nothing is
      # unimplemented — the observation is incomplete.
      raise ArgumentError,
            "features #{inspect(missing)} are in the graph but were not observed at this step"
    end

    all_features =
      Map.new(features, fn {feature, values} ->
        new_rows = as_rows(values)

        {feature, combine_feature(graph, feature, new_rows)}
      end)

    {graph.pos ++ locations, all_features}
  end

  defp combine_feature(graph, feature, new_rows) do
    case Map.fetch(graph.feature_mapping, feature) do
      {:ok, {first, last}} ->
        old_rows = Enum.map(graph.x, &Enum.slice(&1, first, last - first))
        old_rows ++ new_rows

      :error ->
        # A feature the graph has never seen: it takes new columns, and the
        # nodes that predate it get zeros.
        width = new_rows |> hd() |> length()
        List.duplicate(List.duplicate(0.0, width), length(graph.pos)) ++ new_rows
    end
  end

  # Monty stores every feature as a float tensor, so a boolean feature is 1.0 or
  # 0.0 in `x` too.
  defp as_rows(values) do
    Enum.map(values, fn
      value when is_number(value) -> [value * 1.0]
      value when is_boolean(value) -> [if(value, do: 1.0, else: 0.0)]
      row -> Enum.map(row, &normalise_value/1)
    end)
  end

  defp normalise_value(value) when is_number(value), do: value * 1.0
  defp normalise_value(value) when is_boolean(value), do: if(value, do: 1.0, else: 0.0)

  # Mirrors `GraphObjectModel._build_adjacency_graph`. Public because a graph
  # built from observations is useful on its own, and because Monty's own tests
  # reach for the private method.
  @doc false
  @spec build_adjacency_graph(
          [location()],
          %{optional(String.t()) => list()},
          pos_integer() | nil,
          map() | nil,
          non_neg_integer()
        ) ::
          graph()
  def build_adjacency_graph(locations, features, k_n, graph_delta_thresholds, old_graph_index) do
    {locations_reduced, clean_ids} =
      ObjectModelUtils.remove_close_points(
        locations,
        features,
        graph_delta_thresholds,
        old_graph_index
      )

    num_nodes = length(locations_reduced)

    {rows, feature_mapping} = feature_columns(features, clean_ids, num_nodes)

    graph = %{
      x: rows,
      pos: locations_reduced,
      norm: normal_of(feature_mapping, rows),
      feature_mapping: Map.put(feature_mapping, "node_ids", {0, 1}),
      edge_index: nil,
      edge_attr: nil
    }

    if k_n == nil do
      graph
    else
      add_neighbour_edges(graph, locations_reduced, k_n)
    end
  end

  # A graph of one or two nodes has no neighbours to link to. Monty's
  # `correct_k_n` reports that as an error and then hands `None` to
  # scikit-learn, which fails further down; here the graph is built without
  # edges and says why, because the point cloud is still a model.
  defp add_neighbour_edges(graph, locations, k_n) do
    case GraphMatchingUtils.correct_k_n(k_n, length(locations)) do
      {:ok, neighbours} ->
        add_edges(graph, locations, neighbours)

      {:error, :not_enough_observations} ->
        Logger.warning("graph of #{length(locations)} node(s) has no neighbours to link to")
        graph
    end
  end

  defp feature_columns(features, clean_ids, num_nodes) do
    node_ids = for index <- 0..(num_nodes - 1)//1, do: [index * 1.0]

    features
    |> Enum.reduce({node_ids, %{}}, fn {feature, values}, {rows, mapping} ->
      selected =
        clean_ids
        |> Enum.map(&Enum.at(values, &1))
        |> as_rows()

      first = rows |> hd() |> length()
      last = first + (selected |> hd() |> length())

      rows = Enum.zip_with(rows, selected, &(&1 ++ &2))
      {rows, Map.put(mapping, feature, {first, last})}
    end)
  end

  # Only the surface normal is kept separately: it is what a search is oriented
  # by, and digging it out of `x` at every step would repeat the same slice.
  defp normal_of(feature_mapping, rows) do
    case Map.fetch(feature_mapping, "pose_vectors") do
      {:ok, {first, _last}} -> Enum.map(rows, &Enum.slice(&1, first, 3))
      :error -> nil
    end
  end

  defp add_edges(graph, locations, neighbour_count) do
    edges =
      locations
      |> Enum.with_index()
      |> Enum.flat_map(fn {location, source} ->
        locations
        |> Enum.with_index()
        |> Enum.reject(fn {_other, index} -> index == source end)
        |> Enum.map(fn {other, index} -> {index, distance(location, other)} end)
        |> Enum.sort_by(fn {index, distance} -> {distance, index} end)
        |> Enum.take(neighbour_count)
        |> Enum.map(fn {index, _distance} -> {source, index} end)
      end)

    {sources, targets} = Enum.unzip(edges)

    graph
    |> Map.put(:edge_index, {sources, targets})
    |> Map.put(
      :edge_attr,
      Enum.map(edges, fn {source, target} -> displacements(locations, source, target) end)
    )
  end

  defp displacements(locations, source, target) do
    SpatialArithmetics.subtract(Enum.at(locations, target), Enum.at(locations, source))
  end

  defp distance(point, other) do
    point
    |> Enum.zip(other)
    |> Enum.map(fn {first, second} -> (first - second) * (first - second) end)
    |> Enum.sum()
    |> :math.sqrt()
  end
end
