defmodule Monty.Frameworks.Utils.GraphMatchingUtils do
  @moduledoc """
  The bookkeeping around matching: which k, which poses, which distances.

  Mirrors `tbp/monty/frameworks/utils/graph_matching_utils.py`. The functions
  fall into four groups — building a graph (how many neighbours are there to
  have), seeding hypotheses (which object poses to try), scoring them (custom
  distances, scaled evidence) and knowing when to give up (the LM has moved off
  the object it was tracking).

  ## Shapes

  Hypotheses are rows: `nearest_node_locations` is one list of neighbour
  locations per hypothesis, `search_locations` and `search_normals` one vector
  per hypothesis. Results keep the hypotheses' order, so a distance can always
  be read back as "this hypothesis, that neighbour".

  ## Where the numbers come from

  The uniform pose sampling, the dual-pose filter and the 512 → 256 reduction
  are Monty's, reproduced rather than improved: an experiment that samples a
  different 256 poses is a different experiment.
  """

  require Logger

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Math

  @default_curvature_tolerance_degrees 20
  @curvature_fallback 10
  @default_pose_count 9
  @fallback_curvature_key_order [
    "mean_curvature",
    "mean_curvature_sc",
    "gaussian_curvature",
    "gaussian_curvature_sc"
  ]

  @type locations :: [[float()]]

  @doc """
  The neighbour count a graph can actually support.

  `k` is asked for as "edges I want", so the count includes the node itself and
  comes back one larger. A graph with too few observations cannot honour it: it
  falls back to "everything except me", and with two or fewer points there is
  nothing to fall back to.
  """
  @spec correct_k_n(pos_integer(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, :not_enough_observations}
  def correct_k_n(k_n, num_datapoints) do
    k_n = k_n + 1

    cond do
      num_datapoints > k_n ->
        {:ok, k_n}

      num_datapoints > 2 ->
        Logger.debug("setting k_n to #{num_datapoints - 1} for #{num_datapoints} observations")
        {:ok, num_datapoints - 1}

      true ->
        Logger.error("not enough observations collected to build graph")
        {:error, :not_enough_observations}
    end
  end

  @doc """
  The paths that are not a repeat of an earlier one.

  Two paths are the same visit if the points line up: the summed distance
  between corresponding points is below `threshold`. Summing rather than taking
  the maximum is Monty's choice, and it means two paths that both stay close to
  a longer path are the same path.
  """
  @spec unique_paths([locations()], float()) :: [locations()]
  def unique_paths(paths, threshold \\ 0.01) do
    Enum.reduce(paths, [], fn path, unique ->
      if Enum.any?(unique, &same_path?(&1, path, threshold)), do: unique, else: unique ++ [path]
    end)
  end

  defp same_path?(kept, candidate, threshold) do
    kept
    |> Enum.zip(candidate)
    |> Enum.map(fn {kept_point, candidate_point} -> distance(kept_point, candidate_point) end)
    |> Enum.sum()
    |> Kernel.<(threshold)
  end

  @doc """
  Whether every value lies in its own range.

  A range whose minimum exceeds its maximum wraps around: `{350, 20}` covers
  everything except the 20-odd degrees in between, which is how a circular
  feature like an orientation is tolerated.
  """
  @spec in_ranges?([number()], [{number(), number()}]) :: boolean()
  def in_ranges?(values, ranges) do
    values
    |> Enum.zip(ranges)
    |> Enum.all?(fn {value, {low, high}} ->
      if low <= high, do: value >= low and value <= high, else: value >= low or value <= high
    end)
  end

  @doc """
  A spread of object poses to try before anything is known.

  Each axis is sampled at `n_degrees_sampled` angles; every combination is
  generated in lexicographic order, then halved: a rotation and its dual
  `(a + 180, -b + 180, c + 180)` describe the same pose, so only the first of
  each pair is kept. Nine samples give 512 combinations and 256 poses, which is
  what a `uniform` experiment means by "tried every rotation".
  """
  @spec uniform_initial_possible_poses(pos_integer()) :: [Rotation.t()]
  def uniform_initial_possible_poses(n_degrees_sampled \\ @default_pose_count) do
    degrees = uniform_degrees(n_degrees_sampled)

    for(first <- degrees, second <- degrees, third <- degrees, do: {first, second, third})
    |> Enum.reduce({[], []}, fn pose, {poses, duals} ->
      if Tuple.to_list(pose) in duals do
        {poses, duals}
      else
        {:ok, rotation} = Rotation.from_euler_degrees(Tuple.to_list(pose))
        {[rotation | poses], [Tuple.to_list(dual_of(pose)) | duals]}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  The initial poses an experiment asks for.

  `:uniform` samples the whole rotation space, `:informed` starts from the first
  observation instead (there is nothing to assume yet), and a list of Euler
  poses means "try exactly these" — inverted, because they describe how the
  object sits rather than how it must be turned.
  """
  @spec initial_possible_poses(
          :uniform
          | :informed
          | {:euler_degrees, [SpatialArithmetics.vector()]}
        ) ::
          {:ok, [Rotation.t()] | :first_observation}
  def initial_possible_poses(:uniform), do: {:ok, uniform_initial_possible_poses()}
  def initial_possible_poses(:informed), do: {:ok, :first_observation}

  def initial_possible_poses({:euler_degrees, euler_poses}) do
    {:ok,
     Enum.map(euler_poses, fn euler ->
       euler |> then(&Rotation.from_euler_degrees/1) |> elem(1) |> Rotation.invert()
     end)}
  end

  @doc """
  Makes every input channel tolerate pose vectors, in radians.

  `pose_vectors` are degrees everywhere else in Monty's configs and radians
  everywhere in its arithmetic, so this is the one place the conversion
  happens. Channels that already declare a tolerance keep it; the rest get
  `default_tolerances` degrees on all three vectors.
  """
  @spec add_pose_features_to_tolerances(map(), number()) :: map()
  def add_pose_features_to_tolerances(
        tolerances,
        default_tolerances \\ @default_curvature_tolerance_degrees
      ) do
    Map.new(tolerances, fn {channel, channel_tolerances} ->
      degrees = Map.get(channel_tolerances, "pose_vectors", List.duplicate(default_tolerances, 3))

      {channel, Map.put(channel_tolerances, "pose_vectors", Enum.map(degrees, &Math.degrees/1))}
    end)
  end

  @doc """
  How strongly the surface curves where the sensor is, as one number.

  The maximum absolute principal curvature, or a plain curvature value, or —
  when the sensor reports none — a large default, which widens the search
  sphere until it is nearly circular. Searching a wide sphere is slow but
  finds the object; searching a tight one around a curvature that was never
  measured finds nothing.
  """
  @spec relevant_curvature(%{optional(String.t()) => term()}) :: number()
  def relevant_curvature(features) do
    cond do
      Map.has_key?(features, "principal_curvatures_log") ->
        features |> Map.fetch!("principal_curvatures_log") |> max_absolute()

      Map.has_key?(features, "principal_curvatures") ->
        features |> Map.fetch!("principal_curvatures") |> max_absolute()

      true ->
        case Enum.find(@fallback_curvature_key_order, &Map.has_key?(features, &1)) do
          nil ->
            Logger.info("no curvatures contained in the features #{inspect(Map.keys(features))}")
            @curvature_fallback

          key ->
            Map.fetch!(features, key)
        end
    end
  end

  @doc """
  Evidence rescaled into `[-1, 1]` so that one module's longer history cannot
  outvote another's.

  By default the scale is shared: the widest and narrowest evidence over all
  objects set the range, so the objects stay comparable. An evidence set whose
  largest value is below 1 is not rescaled at all — it is only clipped, because
  stretching it would inflate evidence that was never strong.

  `per_object: true` scales each object against itself. Monty notes this can
  hand a weakly supported object too much of a boost; it is kept for the
  experiments that ask for it.

  When every evidence is equal there is no scale to speak of: Monty's division
  yields NaN there, and zeros here, which vote neither way.
  """
  @spec scaled_evidences(%{optional(String.t()) => [number()]}, keyword()) ::
          %{optional(String.t()) => [float()]}
  def scaled_evidences(evidences, options \\ []) do
    if Keyword.get(options, :per_object, false) do
      Map.new(evidences, fn {graph_id, values} -> {graph_id, spread(values)} end)
    else
      scale_together(evidences)
    end
  end

  defp scale_together(evidences) do
    non_empty = for {_graph_id, [_ | _] = values} <- evidences, do: values

    {low, high} =
      non_empty
      |> List.flatten()
      |> then(fn all -> {Enum.min(all, fn -> 0.0 end), Enum.max(all, fn -> 0.0 end)} end)

    Map.new(evidences, fn {graph_id, values} ->
      scaled =
        if high >= 1.0,
          do: values |> spread_against(low, high),
          else: Enum.map(values, &clip(&1, -1.0, 1.0))

      {graph_id, scaled}
    end)
  end

  defp spread(values) do
    spread_against(values, Enum.min(values, fn -> 0.0 end), Enum.max(values, fn -> 0.0 end))
  end

  defp spread_against([], _low, _high), do: []

  defp spread_against(values, low, high) when high == low,
    do: Enum.map(values, fn _value -> 0.0 end)

  defp spread_against(values, low, high) do
    Enum.map(values, fn value -> (value - low) / (high - low) * 2 - 1 end)
  end

  @doc """
  Distances from each hypothesis' search point to its nearest graph nodes,
  flattened along the surface normal.

  A plain Euclidean distance treats the search sphere as a ball; the surface a
  sensor is looking at is not one. Adding `|dot(difference, normal)|` penalises
  candidates that sit off the sensed tangent plane, and dividing by
  `|curvature| + 0.5` lets a curved surface search further off that plane than
  a flat one — while the 0.5 keeps a flat surface from collapsing the sphere to
  a disc (and the division from being by zero).
  """
  @spec custom_distances(
          [locations()],
          [SpatialArithmetics.vector()],
          [SpatialArithmetics.vector()],
          number()
        ) ::
          [[float()]]
  def custom_distances(nearest_node_locations, search_locations, search_normals, search_curvature) do
    flatness = 1 / (abs(search_curvature) + 0.5)

    [nearest_node_locations, search_locations, search_normals]
    |> Enum.zip()
    |> Enum.map(fn {node_locations, search_location, search_normal} ->
      Enum.map(node_locations, fn node_location ->
        difference = SpatialArithmetics.subtract(node_location, search_location)

        SpatialArithmetics.magnitude(difference) +
          abs(SpatialArithmetics.dot(difference, search_normal)) * flatness
      end)
    end)
  end

  @doc """
  Weights that fall off exponentially into the past, one per step.

  The most recent step is weighted 1.0.
  """
  @spec exponential_kernel(pos_integer(), number()) :: [float()]
  def exponential_kernel(size, decay_rate) do
    Enum.map((size - 1)..0//-1, fn index -> :math.exp(-decay_rate * index) end)
  end

  @doc """
  Whether the evidence has been falling for long enough to say the sensor has
  moved onto a different object.

  Each step's drop is weighted by how recent it is, so a sharp fall this step
  counts for more than a slow decline over many; the sum of those weighted
  drops is compared with `:detection_threshold`.
  """
  @spec detect_new_object_exponential([number()], keyword()) :: boolean()
  def detect_new_object_exponential(max_evidence_per_step, options \\ []) do
    threshold = Keyword.get(options, :detection_threshold, -1.0)
    decay_rate = Keyword.get(options, :decay_rate, 3)
    {drops, _positive_jump} = delta_evidence_values(max_evidence_per_step)

    weightings = exponential_kernel(length(drops), decay_rate)

    drops
    |> Enum.zip(weightings)
    |> Enum.map(fn {drop, weighting} -> drop * weighting end)
    |> Enum.sum()
    |> Kernel.<=(threshold)
  end

  @doc """
  Whether the last `k` evidence changes add up to a drop of at least
  `:detection_threshold`.

  `:reset_at_positive_jump` counts only the steps since evidence last rose:
  a module that just got more confident is not on its way off the object, no
  matter what it did before.
  """
  @spec detect_new_object_k_steps([number()], keyword()) :: boolean()
  def detect_new_object_k_steps(max_evidence_per_step, options \\ []) do
    threshold = Keyword.get(options, :detection_threshold, -1.0)
    k = Keyword.get(options, :k, 3)
    reset? = Keyword.get(options, :reset_at_positive_jump, false)

    window = Enum.take(max_evidence_per_step, -(k + 1))
    {drops, positive_jump} = delta_evidence_values(window)

    counted =
      if reset? and positive_jump != nil,
        do: Enum.drop(drops, positive_jump),
        else: drops

    Enum.sum(counted) <= threshold
  end

  @doc """
  The step-to-step changes in evidence, with the rises clipped away, and where
  evidence last rose.

  Only drops suggest movement onto a new object, so the rises are clipped to
  zero; the position of the last rise is returned so the caller can decide
  whether to count from there.
  """
  @spec delta_evidence_values([number()]) :: {[float()], non_neg_integer() | nil}
  def delta_evidence_values(max_evidence_per_step) do
    changes =
      max_evidence_per_step
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [previous, current] -> current - previous end)

    positive_jump =
      changes
      |> Enum.with_index()
      |> Enum.filter(fn {change, _index} -> change > 0 end)
      |> case do
        [] -> nil
        rises -> rises |> List.last() |> elem(1)
      end

    {Enum.map(changes, fn change -> min(change, 0) * 1.0 end), positive_jump}
  end

  @doc """
  The step at which the sensor first spent `n_steps_off_primary_target`
  consecutive steps off the primary target, or `nil` if it never did.

  A single step elsewhere is not "on a new object" — the sensor may simply have
  looked past an edge — so the run of steps is what counts.
  """
  @spec find_step_on_new_object([String.t()], String.t(), pos_integer()) ::
          non_neg_integer() | nil
  def find_step_on_new_object(stepwise_targets, primary_target, n_steps_off_primary_target) do
    off_primary = Enum.map(stepwise_targets, &(&1 != primary_target))

    off_primary
    |> Enum.chunk_every(n_steps_off_primary_target, 1, :discard)
    |> Enum.find_index(&Enum.all?(&1))
    |> case do
      nil -> nil
      first_window -> first_window + n_steps_off_primary_target - 1
    end
  end

  @doc """
  The directions a node may be sensing from, one pose vector set per rotation.

  With `num_hyps_per_node == 2` the pose is well defined (the two principal
  curvatures differ), and a well-defined pose still cannot tell an object from
  its upside-down twin: the curvature directions may point either way, so both
  are offered. Otherwise the directions are sampled around the normal.
  """
  @spec possible_sensed_directions(SurfacePoseVectors.t(), pos_integer()) ::
          [locations()]
  def possible_sensed_directions(%SurfacePoseVectors{value: value}, 2) do
    [surface_normal, principal_1, principal_2] = value
    flipped = [surface_normal, negate(principal_1), negate(principal_2)]
    [value, flipped]
  end

  def possible_sensed_directions(%SurfacePoseVectors{value: value}, num_hyps_per_node) do
    SpatialArithmetics.get_more_directions_in_plane(value, num_hyps_per_node)
  end

  defp negate(vector), do: Enum.map(vector, &(-1.0 * &1))

  defp uniform_degrees(n_degrees_sampled) do
    step = 360 / (n_degrees_sampled - 1)
    Enum.map(0..(n_degrees_sampled - 2)//1, fn index -> index * step / 1 end)
  end

  defp dual_of({first, second, third}) do
    {wrap(first + 180), wrap(-second + 180), wrap(third + 180)}
  end

  defp wrap(degrees) do
    wrapped = degrees |> :math.fmod(360.0)
    if wrapped < 0, do: wrapped + 360.0, else: wrapped
  end

  defp max_absolute([first, second]) when is_number(first) and is_number(second),
    do: max(abs(first), abs(second))

  defp max_absolute(value), do: value |> List.wrap() |> Enum.map(&abs/1) |> Enum.max()

  defp distance(point, other) do
    point
    |> Enum.zip(other)
    |> Enum.map(fn {first, second} -> (first - second) * (first - second) end)
    |> Enum.sum()
    |> :math.sqrt()
  end

  defp clip(value, low, high), do: value |> max(low) |> min(high)
end
