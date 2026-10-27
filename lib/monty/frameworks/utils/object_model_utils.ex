defmodule Monty.Frameworks.Utils.ObjectModelUtils do
  @moduledoc """
  Grid and point-cloud helpers used while building an object model.

  Mirrors `tbp/monty/frameworks/utils/object_model_utils.py`. What is ported
  here is the part that is arithmetic about observations: deciding whether a new
  observation says anything the graph does not already say, and summarising
  several observations of the same spot into one.

  The rest of the Python file is torch scaffolding — `NumpyGraph`,
  `torch_graph_to_numpy`, and the sparse-tensor index helpers — which exists to
  move data in and out of `torch_geometric`. Elixir has no such layer: a graph
  here is already the map that `NumpyGraph` wraps, so those functions have no
  Elixir counterpart to be faithful to rather than an unwritten one.

  ## Why "is this point new" is a whole function

  Sampling the same spot twice must not grow the graph, but "the same spot" is
  not just "close by": a point on the other side of a thin object is close in
  space and different in what it senses. So a point is redundant only if it is
  within the distance threshold *and* no feature differs by more than that
  feature's threshold — and if it is redundant with any single close point, it
  is redundant.
  """

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation
  alias Monty.Math

  @type locations :: [SpatialArithmetics.vector()]

  @default_distance_threshold 0.001
  @default_pose_threshold :math.pi() / 2

  @doc """
  Whether `new_point` says nothing that `existing_points` does not already say.

  `features` maps a feature name to one value per point, indexed by feature
  index; `clean_ids` translates a position among the accepted points into the
  feature index, because points rejected earlier still occupy a feature index.
  """
  @spec already_in_list?(
          locations(),
          SpatialArithmetics.vector(),
          %{optional(String.t()) => [term()]},
          [non_neg_integer()],
          non_neg_integer(),
          %{optional(String.t()) => term()}
        ) :: boolean()
  def already_in_list?(existing_points, new_point, features, clean_ids, query_id, thresholds) do
    existing_points
    |> Enum.with_index()
    |> Enum.filter(fn {point, _index} ->
      distance(point, new_point) < fetch_threshold(thresholds, "distance")
    end)
    |> Enum.any?(fn {_point, position} ->
      redundant?(features, Enum.at(clean_ids, position), query_id, thresholds)
    end)
  end

  @doc """
  The points from `point_cloud` worth keeping, and their indices.

  Everything before `old_graph_index` is kept without checking, because the
  earlier points were already compared with each other — that is what makes
  extending a graph cost the new observations rather than the whole model.
  """
  @spec remove_close_points(
          locations(),
          %{optional(String.t()) => [term()]},
          map() | nil,
          non_neg_integer()
        ) ::
          {locations(), [non_neg_integer()]}
  def remove_close_points(point_cloud, features, graph_delta_thresholds, old_graph_index) do
    thresholds = with_defaults(graph_delta_thresholds)

    {kept, clean_ids} =
      point_cloud
      |> Enum.drop(old_graph_index)
      |> Enum.with_index(old_graph_index)
      |> Enum.reduce(
        {Enum.take(point_cloud, old_graph_index), Enum.to_list(0..(old_graph_index - 1)//1)},
        fn
          {point, index}, {kept, clean_ids} ->
            if kept == [] or
                 not already_in_list?(kept, point, features, clean_ids, index, thresholds) do
              {kept ++ [point], clean_ids ++ [index]}
            else
              {kept, clean_ids}
            end
        end
      )

    {kept, clean_ids}
  end

  @doc """
  A right-handed orthonormal pose from a rough normal and curvature direction.

  The normal is taken as given (up to length), the curvature direction is made
  perpendicular to it, and the second curvature direction is what completes the
  frame. A curvature direction with nothing perpendicular to the normal is
  meaningless — a flat surface has no preferred direction — so an arbitrary
  tangent is used rather than a zero vector.
  """
  @spec orthonormal_pose_vectors(SpatialArithmetics.vector(), SpatialArithmetics.vector()) :: [
          float()
        ]
  def orthonormal_pose_vectors(surface_normal, curvature_direction) do
    normal = SpatialArithmetics.normalize(surface_normal)
    tangent = SpatialArithmetics.project_onto_tangent_plane(curvature_direction, normal)

    tangent =
      if SpatialArithmetics.magnitude(tangent) < Math.default_tolerance() do
        Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame.new(normal)
        |> Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame.basis_u()
      else
        tangent
      end

    curvature_1 = SpatialArithmetics.normalize(tangent)
    curvature_2 = SpatialArithmetics.cross(normal, curvature_1)

    normal ++ curvature_1 ++ curvature_2
  end

  @doc """
  Merge a newly averaged pose into the pose already stored, by weight.

  Both are rotations, so they are averaged as rotations — not component-wise,
  which would leave a matrix that is no longer a rotation.
  """
  @spec pose_vector_merge([number()], [number()], number(), number()) :: [float()]
  def pose_vector_merge(new_pose_vecs, previous_pose_vecs, num_new_obs, num_previous_obs) do
    [new_pose_vecs, previous_pose_vecs]
    |> Enum.map(&as_rotation/1)
    |> Rotation.mean([num_new_obs, num_previous_obs])
    |> Rotation.to_matrix()
    |> List.flatten()
  end

  @doc """
  One representative pose from several observations of the same spot.

  Two ambiguities have to be resolved first. A surface can be seen from either
  side, so normals are counted by which half-sphere they point into — the one
  spanned by the first observation's curvature directions — and the other side
  is discarded rather than averaged in. And a curvature direction has no sign
  (both point along the same axis), so those pointing the wrong way are flipped
  before averaging.

  The half-sphere rule inverts the count only when *fewer than half* agree
  (`sum < len // 2`), so with three observations split one and two the single
  agreeing observation wins. That is Monty's comparison, reproduced rather than
  corrected: an experiment that averaged a different side would produce
  different numbers from the Python.

  Returns the flat nine-number pose, and whether the curvature directions were
  used; when the poses are not fully defined they carry no information and the
  first observation's direction is kept.
  """
  @spec pose_vector_mean([[number()]], [boolean()]) :: {[float()] | nil, boolean()}
  def pose_vector_mean(pose_vecs, pose_fully_defined) do
    case Enum.filter(pose_vecs, fn pose -> Enum.any?(pose, &(&1 != 0.0)) end) do
      [] -> {nil, false}
      observations -> mean_pose(observations, pose_fully_defined)
    end
  end

  defp mean_pose(observations, pose_fully_defined) do
    parts = Enum.map(observations, &split_pose/1)
    [_first | _rest] = parts
    {_normal, first_curvature_1, first_curvature_2} = hd(parts)

    normals = Enum.map(parts, &elem(&1, 0))

    normal_mean =
      normals
      |> Enum.zip(half_sphere_mask(normals, first_curvature_1, first_curvature_2))
      |> Enum.filter(fn {_normal, keep?} -> keep? end)
      |> Enum.map(fn {normal, _keep?} -> normal end)
      |> mean_vector()
      |> SpatialArithmetics.normalize()

    if defined?(pose_fully_defined) do
      curvature_1 =
        parts
        |> Enum.map(&elem(&1, 1))
        |> Enum.map(&align_with(&1, first_curvature_2, normal_mean))
        |> mean_vector()

      {orthonormal_pose_vectors(normal_mean, curvature_1), true}
    else
      # The curvature directions are not trusted, so the first observation's
      # direction is as good as any: they are not matched on anyway.
      {orthonormal_pose_vectors(normal_mean, first_curvature_1), false}
    end
  end

  # Which observations face the same way as the first one's tangent frame.
  defp half_sphere_mask(normals, first_curvature_1, first_curvature_2) do
    mask =
      Enum.map(normals, fn normal ->
        SpatialArithmetics.get_right_hand_angle(normal, first_curvature_1, first_curvature_2) > 0
      end)

    if Enum.count(mask, & &1) < div(length(mask), 2) or not Enum.any?(mask) do
      Enum.map(mask, &(not &1))
    else
      mask
    end
  end

  # A curvature direction has no sign: both ends describe the same axis, so the
  # ones pointing against the majority are flipped before they are averaged in.
  defp align_with(direction, reference, normal) do
    if SpatialArithmetics.get_right_hand_angle(direction, reference, normal) < 0 do
      Enum.map(direction, &(-1.0 * &1))
    else
      direction
    end
  end

  defp split_pose(pose) do
    {Enum.take(pose, 3), Enum.slice(pose, 3, 3), Enum.slice(pose, 6, 3)}
  end

  defp defined?(pose_fully_defined) do
    Enum.count(pose_fully_defined, & &1) >= div(length(pose_fully_defined), 2)
  end

  defp mean_vector(vectors) do
    vectors
    |> Enum.zip_with(& &1)
    |> Enum.map(&mean/1)
  end

  defp as_rotation(flat_pose_vecs) do
    {:ok, rotation} = flat_pose_vecs |> Enum.chunk_every(3) |> Rotation.from_matrix()
    rotation
  end

  @doc """
  The majority of a list of booleans, ties going to `true`.

  A single boolean per observation is expected; anything deeper is a feature
  this function was not written for, and says so rather than guessing a shape.
  """
  @spec get_most_common_bool([[boolean()]] | [boolean()]) :: boolean()
  def get_most_common_bool(booleans) do
    if depth(booleans) > 2 do
      raise ArgumentError,
            "get_most_common_bool is not defined for features with more than one boolean value"
    end

    flattened = List.flatten(booleans)
    trues = Enum.count(flattened, & &1)

    trues >= length(flattened) - trues
  end

  @doc """
  The most common value among non-negative integers, ties going to the smallest.

  Monty counts with `np.bincount` and takes the first maximum, which is the same
  rule.
  """
  @spec get_most_common_value([non_neg_integer()]) :: non_neg_integer()
  def get_most_common_value(values) do
    values
    |> Enum.frequencies()
    |> Enum.max_by(fn {value, count} -> {count, -value} end)
    |> elem(0)
  end

  @doc """
  The mean of a value that wraps: hue, where 0 and 1 are the same colour.

  Averaging 0.01 and 0.99 component-wise gives 0.5, the opposite colour; the
  mean has to be taken of the angles and brought back to `[0, 1)`.
  """
  @spec circular_mean([number()]) :: float()
  def circular_mean(values) do
    angles = Enum.map(values, &(&1 * 2 * :math.pi()))

    mean_angle =
      :math.atan2(mean(Enum.map(angles, &:math.sin/1)), mean(Enum.map(angles, &:math.cos/1)))

    wrapped = if mean_angle < 0, do: mean_angle + 2 * :math.pi(), else: mean_angle
    wrapped / (2 * :math.pi())
  end

  @doc """
  A graph holding observations but no edges yet.

  `feature_mapping` says which columns of `features` belong to which named
  feature; it is carried along untouched, because only the graph builder knows
  how it was laid out.
  """
  @spec build_point_cloud_graph(locations(), map(), map()) :: map()
  def build_point_cloud_graph(locations, features, feature_mapping) do
    %{x: features, pos: locations, feature_mapping: feature_mapping}
  end

  defp redundant?(features, feature_index, query_id, thresholds) do
    thresholds
    |> Map.keys()
    |> Enum.all?(fn feature ->
      not exceeds?(feature, features, feature_index, query_id, thresholds)
    end)
  end

  defp exceeds?("distance", _features, _feature_index, _query_id, _thresholds), do: false

  defp exceeds?(feature, features, feature_index, query_id, thresholds) do
    case Map.fetch(features, feature) do
      :error ->
        false

      {:ok, values} ->
        exceeds_feature?(
          feature,
          Enum.at(values, feature_index),
          Enum.at(values, query_id),
          thresholds
        )
    end
  end

  defp exceeds_feature?("hsv", stored, observed, thresholds) do
    [hue_threshold | _rest] = List.wrap(Map.fetch!(thresholds, "hsv"))
    circular_difference(Enum.at(stored, 0), Enum.at(observed, 0)) > hue_threshold
  end

  defp exceeds_feature?("pose_vectors", stored, observed, thresholds) do
    stored_normal = Enum.take(stored, 3)
    observed_normal = Enum.take(observed, 3)

    stored_normal
    |> then(
      &SpatialArithmetics.get_angle(
        SpatialArithmetics.normalize(&1),
        SpatialArithmetics.normalize(observed_normal)
      )
    )
    |> Kernel.>(List.first(List.wrap(Map.fetch!(thresholds, "pose_vectors"))))
  end

  defp exceeds_feature?(feature, stored, observed, thresholds) do
    thresholds
    |> Map.fetch!(feature)
    |> List.wrap()
    |> Enum.zip(List.wrap(signed_differences(stored, observed)))
    |> Enum.any?(fn {threshold, difference} -> difference > threshold end)
  end

  defp signed_differences(stored, observed) when is_number(stored) and is_number(observed),
    do: abs(stored - observed)

  defp signed_differences(stored, observed), do: Enum.zip_with(stored, observed, &abs(&1 - &2))

  defp circular_difference(first, second) do
    raw = abs(first - second)
    min(raw, 1.0 - raw)
  end

  defp with_defaults(nil),
    do: %{
      "distance" => @default_distance_threshold,
      "pose_vectors" => [@default_pose_threshold, 2 * :math.pi(), 2 * :math.pi()]
    }

  defp with_defaults(graph_delta_thresholds) do
    graph_delta_thresholds
    |> Map.put_new("distance", @default_distance_threshold)
    |> Map.put_new("pose_vectors", [@default_pose_threshold, 2 * :math.pi(), 2 * :math.pi()])
  end

  defp fetch_threshold(thresholds, feature),
    do: List.first(List.wrap(Map.fetch!(thresholds, feature)))

  defp depth(value) when not is_list(value), do: 0
  defp depth([]), do: 1
  defp depth([head | _rest]), do: 1 + depth(head)

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp distance(point, other) do
    point
    |> Enum.zip(other)
    |> Enum.map(fn {first, second} -> (first - second) * (first - second) end)
    |> Enum.sum()
    |> :math.sqrt()
  end
end
