defmodule Monty.Frameworks.Models.ObjectModel.GridObjectModel do
  @moduledoc """
  A model whose nodes are the busiest voxels of a grid.

  Mirrors `tbp/monty/frameworks/models/object_model.py::GridObjectModel`. Where
  `GraphObjectModel` keeps every observation as a node, this model first sorts
  observations into a voxel grid and then keeps the `max_nodes` voxels that were
  observed most often. That is what bounds a model in two dimensions at once:
  `max_size` bounds the space the object may occupy — observations outside it
  are what `GridTooSmallError` is about — and `num_voxels_per_dim` bounds the
  resolution, so a dense surface does not turn into a graph of ten thousand
  nodes.

  A voxel remembers the average of everything observed inside it: a location,
  and each feature's average. "Average" is not one operation — a hue is a mean
  of angles, a pose is a mean of rotations, a boolean is a majority vote — and
  those differences are the reason this model asks the object-model utilities
  for each feature by name.

  ## The grid is a map

  numpy holds each grid as a sparse 4-D tensor of shape
  `(voxels, voxels, voxels, width)` and reads it with `to_dense()[i, j, k]`.
  A sparse grid *is* a map from voxel index to content, so that is what it is
  here: `observation_count` counts observations per voxel, `location_grid`
  keeps each voxel's average location, and `feature_grid` keeps each voxel's
  averaged features by name. The algorithm is unchanged — the same voxels hold
  the same values — and a voxel nobody observed costs nothing.

  ## The first observation is the centre

  The grid is placed so that the first observation ever made sits in the middle
  voxel, and every later observation is mapped against that. An object
  therefore grows outwards from wherever it was first touched, which is what
  lets a model be built without knowing where the object is.

  ## Averaging an update into a voxel

  A voxel observed again is averaged with what it held — but, in Monty, by
  averaging the *two averages* rather than weighting by the number of
  observations, except for poses (which are merged as rotations, by count) and
  object ids (where the larger count wins). That is reproduced rather than
  corrected: an experiment tuned on Monty's numbers expects the same values,
  and a boolean averaged this way can end up at `0.5`, which Monty reads as
  "defined" because it is not zero.
  """

  alias Monty.Frameworks.Models.ObjectModel.{GraphObjectModel, GridTooSmallError}
  alias Monty.Frameworks.Utils.{KdTree, ObjectModelUtils, SpatialArithmetics}

  @behaviour Monty.Frameworks.Models.ObjectModel

  @in_bounds_fraction 0.9

  @enforce_keys [:object_id, :max_nodes, :max_size, :num_voxels_per_dim]
  defstruct object_id: nil,
            graph: nil,
            max_nodes: nil,
            max_size: nil,
            num_voxels_per_dim: nil,
            location_scale_factor: nil,
            location_offset: nil,
            observation_count: %{},
            location_grid: %{},
            feature_grid: %{},
            current_feature_mapping: %{},
            location_tree: nil,
            use_original_graph: false

  @type voxel :: {integer(), integer(), integer()}
  @type location :: SpatialArithmetics.vector()
  @type feature_rows :: %{optional(String.t()) => [number()] | [boolean()]}
  @type feature_mapping :: %{optional(String.t()) => {non_neg_integer(), non_neg_integer()}}
  @type t :: %__MODULE__{}

  @doc """
  A model for `object_id` that can hold an object `:max_size` metres across at
  `:num_voxels_per_dim` voxels per side, thinned to `:max_nodes` nodes.

  `:use_original_graph` adopts a graph as it stands, grids untouched: Monty
  keeps the switch for graphs that were learned elsewhere, which are matched
  against exactly as they were stored.
  """
  @impl true
  @spec new(String.t(), keyword()) :: t()
  def new(object_id, options) do
    %__MODULE__{
      object_id: object_id,
      max_nodes: Keyword.fetch!(options, :max_nodes),
      max_size: Keyword.fetch!(options, :max_size),
      num_voxels_per_dim: Keyword.fetch!(options, :num_voxels_per_dim),
      use_original_graph: Keyword.get(options, :use_original_graph, false)
    }
  end

  @doc """
  Builds the model from an episode's observations.

  `locations` are in the model's own frame; `features` is what the buffer
  gathered, keyed by feature name with one row per observation.

  `{:error, %GridTooSmallError{}}` when fewer than 90% of the observations fit
  the grid: an object that big needs a bigger model, and storing the part that
  fits would store a lie.
  """
  @impl true
  @spec build_model(t(), [location()], %{optional(String.t()) => list()}) ::
          {:ok, t()} | {:error, GridTooSmallError.t()}
  def build_model(%__MODULE__{} = model, locations, features) do
    with {:ok, model} <- place_and_fill_grid(model, locations, features) do
      {:ok, build_graph_from_grids(model)}
    end
  end

  @doc """
  Adds an episode's observations to the model, in the model's own frame.

  The new observations arrive in the body's frame; `location_rel_model` and
  `object_location_rel_body` are the same physical spot seen in both, and the
  rotation between them is how the model reconciles the two — the same
  transform a graph model applies before adding nodes.
  """
  @impl true
  @spec update_model(
          t(),
          [location()],
          %{optional(String.t()) => list()},
          location(),
          location(),
          Monty.Geometry.Rotation.t()
        ) ::
          {:ok, t()} | {:error, GridTooSmallError.t()}
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

    with {:ok, model} <- update_grids(model, rf_locations, rf_features) do
      {:ok, build_graph_from_grids(model)}
    end
  end

  @doc """
  Adopts a graph as this model's graph.

  A graph learned elsewhere is either kept exactly as it is (`:use_original_graph`)
  or folded into this model's grid, which re-thins it to this model's `max_nodes`
  and resolution.
  """
  @impl true
  @spec set_graph(t(), map()) :: {:ok, t()} | {:error, GridTooSmallError.t()}
  def set_graph(%__MODULE__{use_original_graph: true} = model, graph) do
    {:ok, %{model | graph: graph, location_tree: tree_of(graph)}}
  end

  def set_graph(%__MODULE__{} = model, %{pos: locations} = graph) do
    features = unpack_features(graph)

    with {:ok, model} <- place_and_fill_grid(model, locations, features) do
      {:ok, build_graph_from_grids(model)}
    end
  end

  # -- reading the model ----------------------------------------------------

  @doc "The graph the model currently holds, or `nil` before it has been built."
  @impl true
  def graph(%__MODULE__{graph: graph}), do: graph

  @impl true
  @spec positions(t()) :: [location()]
  def positions(%__MODULE__{graph: nil}), do: []

  def positions(%__MODULE__{} = model),
    do: model |> as_graph_model() |> GraphObjectModel.positions()

  @impl true
  @spec num_nodes(t()) :: non_neg_integer()
  def num_nodes(%__MODULE__{} = model), do: length(positions(model))

  @spec feature_ids_in_graph(t()) :: [String.t()]
  def feature_ids_in_graph(%__MODULE__{current_feature_mapping: mapping}), do: Map.keys(mapping)

  @impl true
  @spec get_values_for_feature(t(), String.t()) :: [[float()]]
  def get_values_for_feature(%__MODULE__{} = model, feature) do
    model |> as_graph_model() |> GraphObjectModel.get_values_for_feature(feature)
  end

  @doc """
  The nearest nodes to each search location, by straight-line distance.

  Monty builds a KD-tree over the graph's positions and queries it; a grid
  model's graph is a point cloud, so there are no edges to walk — the same
  search, done by comparing distances.
  """
  @impl true
  def find_nearest_neighbors(
        %__MODULE__{} = model,
        search_locations,
        num_neighbors,
        options \\ []
      ) do
    capacity = min(num_neighbors, num_nodes(model))
    tree = location_tree(model)

    query =
      if Keyword.get(options, :distance, false),
        do: &KdTree.nearest_with_distances/3,
        else: &KdTree.nearest/3

    Enum.map(search_locations, &query.(tree, &1, capacity))
  end

  # The index over this model's node positions, kept with the graph it belongs
  # to: the positions only change when the model is rebuilt.
  defp location_tree(%__MODULE__{location_tree: tree}) when not is_nil(tree), do: tree

  defp location_tree(%__MODULE__{} = model), do: tree_of(model.graph)

  defp tree_of(%{pos: positions}), do: positions |> Enum.with_index() |> KdTree.build()
  defp tree_of(_no_graph), do: :empty

  @doc "The index of the edge between two nodes, or `nil`: a grid model has none."
  @spec edge_index_between(t(), non_neg_integer(), non_neg_integer()) :: nil
  def edge_index_between(%__MODULE__{}, _previous_node, _new_node), do: nil

  # The graph this model holds, seen through the graph model that knows how to
  # read one: the grid and the graph differ only in how the graph was chosen.
  defp as_graph_model(%__MODULE__{} = model) do
    {:ok, graph_model} =
      model.object_id
      |> GraphObjectModel.new()
      |> GraphObjectModel.set_graph(model.graph)

    graph_model
  end

  # -- filling the grid -----------------------------------------------------

  defp place_and_fill_grid(%__MODULE__{} = model, locations, features) do
    model = %{model | observation_count: %{}, location_grid: %{}, feature_grid: %{}}

    {scale_factor, offset} = location_mapping(model, hd(locations))

    model = %{model | location_scale_factor: scale_factor, location_offset: offset}

    update_grids(model, locations, features)
  end

  # The first observation goes to the middle voxel, so the object grows
  # outwards from wherever it was first touched.
  defp location_mapping(%__MODULE__{} = model, start_location) do
    voxel_size = model.max_size / model.num_voxels_per_dim
    scale_factor = 1 / voxel_size
    start_index = Enum.map(start_location, &round(&1 * scale_factor))
    centre = div(model.num_voxels_per_dim, 2)

    {scale_factor, Enum.map(start_index, &(centre - &1))}
  end

  defp update_grids(%__MODULE__{} = model, locations, features) do
    voxels = Enum.map(locations, &voxel_of(model, &1))
    in_bounds? = Enum.map(voxels, &in_bounds?(model, &1))
    fraction = Enum.count(in_bounds?, & &1) / length(in_bounds?)

    if fraction < @in_bounds_fraction do
      {:error, %GridTooSmallError{fraction_in_bounds: fraction}}
    else
      observations = observations_by_voxel(locations, features, voxels, in_bounds?)
      counts = count_observations(model.observation_count, observations)

      {location_grid, feature_grid} =
        Enum.reduce(observations, {model.location_grid, model.feature_grid}, fn
          {voxel, observations}, {locations_grid, features_grid} ->
            count = Map.fetch!(counts, voxel)

            {Map.put(
               locations_grid,
               voxel,
               averaged_location(observations, locations_grid[voxel], count)
             ),
             Map.put(
               features_grid,
               voxel,
               averaged_features(observations, features_grid[voxel], count)
             )}
        end)

      {:ok,
       %{
         model
         | observation_count: counts,
           location_grid: location_grid,
           feature_grid: feature_grid,
           current_feature_mapping: feature_mapping(features)
       }}
    end
  end

  defp voxel_of(%__MODULE__{} = model, location) do
    location
    |> Enum.map(&round(&1 * model.location_scale_factor))
    |> Enum.zip(model.location_offset)
    |> Enum.map(fn {index, offset} -> index + offset end)
    |> List.to_tuple()
  end

  defp in_bounds?(%__MODULE__{num_voxels_per_dim: dimensions}, voxel) do
    voxel |> Tuple.to_list() |> Enum.all?(&(&1 >= 0 and &1 < dimensions))
  end

  # One entry per voxel observed in this batch, holding that voxel's new
  # observations: their location and their features by name.
  defp observations_by_voxel(locations, features, voxels, in_bounds?) do
    locations
    |> Enum.with_index()
    |> Enum.zip(Enum.zip(voxels, in_bounds?))
    |> Enum.filter(fn {_location, {_voxel, keep?}} -> keep? end)
    |> Enum.map(fn {{location, index}, {voxel, _keep?}} ->
      {voxel, location, observation_features(features, index)}
    end)
    |> Enum.group_by(
      fn {voxel, _location, _features} -> voxel end,
      fn {_voxel, location, features} -> {location, features} end
    )
  end

  defp count_observations(counts, observations) do
    Enum.reduce(observations, counts, fn {voxel, at_voxel}, counts ->
      Map.update(counts, voxel, length(at_voxel), &(&1 + length(at_voxel)))
    end)
  end

  defp observation_features(features, index) do
    for {name, rows} <- features, row = Enum.at(rows, index), not is_nil(row), into: %{} do
      {name, List.wrap(row)}
    end
  end

  defp feature_mapping(features) do
    {mapping, _width} =
      Enum.reduce(features, {%{}, 0}, fn {name, rows}, {mapping, width} ->
        row_width =
          rows |> Enum.reject(&is_nil/1) |> Enum.map(&length(List.wrap(&1))) |> Enum.uniq()

        feature_width = List.first(row_width) || 0
        {Map.put(mapping, name, {width, width + feature_width}), width + feature_width}
      end)

    mapping
  end

  # -- averaging what a voxel holds -----------------------------------------

  defp averaged_location(observations, previous, count) do
    mean =
      observations
      |> Enum.map(fn {location, _features} -> location end)
      |> centroid()

    # Monty averages the new mean with the stored one, rather than weighting by
    # how many observations each represents.
    if count > length(observations) and previous != nil,
      do: midpoint(mean, previous),
      else: mean
  end

  defp averaged_features(observations, previous, count) do
    feature_rows =
      Enum.reduce(observations, %{}, fn {_location, features}, rows ->
        Enum.reduce(features, rows, fn {name, row}, rows ->
          Map.update(rows, name, [row], &(&1 ++ [row]))
        end)
      end)

    new_averages =
      Map.new(feature_rows, fn {name, rows} ->
        {name, average_feature(name, rows, feature_rows)}
      end)

    previous = previous || %{}
    observations_in_voxel = length(observations)
    observations_before = count - observations_in_voxel

    Map.merge(previous, new_averages, fn name, stored, average ->
      if observations_before > 0,
        do: merge_feature(name, average, stored, observations_in_voxel, observations_before),
        else: average
    end)
  end

  # Each feature is averaged the way its own kind of value wants: a hue is an
  # angle, a pose is a rotation, a flag is a vote.
  defp average_feature("hsv", rows, _all_rows) do
    [hues, saturations, values] = rows |> Enum.zip_with(& &1)

    [ObjectModelUtils.circular_mean(hues) | Enum.map([saturations, values], &Monty.Math.mean/1)]
  end

  # A pose is averaged as a rotation, and whether the curvature directions may
  # be trusted is a vote of the flags that came with it — the average is taken
  # over the observations this voxel just received, not over all of them.
  defp average_feature("pose_vectors", rows, all_rows) do
    flags =
      all_rows
      |> Map.get("pose_fully_defined", [])
      |> Enum.map(fn [flag | _] -> as_boolean(flag) end)

    {mean, _defined?} = ObjectModelUtils.pose_vector_mean(rows, flags)
    mean
  end

  defp average_feature("pose_fully_defined", rows, _all_rows), do: majority(rows, &as_boolean/1)
  defp average_feature("on_object", rows, _all_rows), do: majority(rows, &as_boolean/1)

  defp average_feature("object_id", rows, _all_rows) do
    [ObjectModelUtils.get_most_common_value(Enum.map(rows, fn [value | _] -> value end))]
  end

  defp average_feature(_name, rows, _all_rows) do
    rows |> Enum.zip_with(& &1) |> Enum.map(&Monty.Math.mean/1)
  end

  # A flag is stored as the 1.0 or 0.0 a feature row holds, so that averaging it
  # with a stored value later is arithmetic rather than a type error.
  defp majority(rows, convert) do
    majority? =
      ObjectModelUtils.get_most_common_bool(Enum.map(rows, fn [value | _] -> convert.(value) end))

    [if(majority?, do: 1.0, else: 0.0)]
  end

  defp as_boolean(value) when is_boolean(value), do: value
  defp as_boolean(value), do: value != 0.0

  # A pose merges as a rotation weighted by how many observations each side of
  # the merge represents; an object id keeps whichever side saw more; and every
  # other feature averages the two averages, which is Monty's rule and not a
  # weighted mean.
  defp merge_feature("pose_vectors", average, stored, new_count, stored_count) do
    if average == nil do
      stored
    else
      ObjectModelUtils.pose_vector_merge(average, stored, new_count, stored_count)
    end
  end

  defp merge_feature("object_id", average, stored, new_count, stored_count) do
    if stored_count > new_count, do: stored, else: average
  end

  defp merge_feature(_name, average, stored, _new_count, _stored_count),
    do: midpoint(average, stored)

  defp midpoint(left, right), do: Enum.zip_with(left, right, fn a, b -> (a + b) / 2 end)

  defp centroid(vectors) do
    vectors |> Enum.zip_with(& &1) |> Enum.map(&Monty.Math.mean/1)
  end

  # -- thinning the grid into a graph ---------------------------------------

  defp build_graph_from_grids(%__MODULE__{} = model) do
    voxels = top_voxels(model)

    locations = Enum.map(voxels, &Map.fetch!(model.location_grid, &1))
    {rows, mapping} = flatten_features(voxels, model.feature_grid, model.current_feature_mapping)

    graph = ObjectModelUtils.build_point_cloud_graph(locations, rows, mapping)

    %{model | graph: graph, location_tree: tree_of(graph)}
  end

  # The busiest voxels win, and a tie goes to the lower voxel index so that two
  # runs of the same episode keep the same nodes.
  defp top_voxels(%__MODULE__{} = model) do
    model.observation_count
    |> Enum.sort_by(fn {voxel, count} -> {-count, voxel} end)
    |> Enum.take(model.max_nodes)
    |> Enum.map(fn {voxel, _count} -> voxel end)
  end

  defp flatten_features(voxels, feature_grid, mapping) do
    names = mapping |> Map.keys() |> Enum.sort_by(&Map.fetch!(mapping, &1))

    rows =
      Enum.map(voxels, fn voxel ->
        stored = Map.get(feature_grid, voxel, %{})

        Enum.flat_map(names, fn name ->
          stored
          |> Map.get(name, [])
          |> List.wrap()
          |> pad_to(width_of(mapping, name))
        end)
      end)

    {rows, mapping}
  end

  defp width_of(mapping, name) do
    {first, last} = Map.fetch!(mapping, name)
    last - first
  end

  defp pad_to(values, width) do
    values ++ List.duplicate(0.0, max(width - length(values), 0))
  end

  # A graph adopted from elsewhere stores its features as one row per node plus
  # a mapping of which columns are which; the grid wants them by name.
  defp unpack_features(%{x: rows, feature_mapping: mapping}) do
    Map.new(mapping, fn {name, {first, last}} ->
      {name, Enum.map(rows, fn row -> Enum.slice(row, first..(last - 1)//1) end)}
    end)
  end
end
