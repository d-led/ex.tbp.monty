defmodule Monty.Frameworks.Models.SensorModules.FeatureChangeFilter do
  @moduledoc """
  Sends a point to the learning modules only when something about it has changed
  enough to be worth learning.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::FeatureChangeFilter`.
  Without it a surface agent would hand its learning module a new point on every
  timestep even when it had barely moved, which is a different experiment: the
  agent would fill a graph with near-identical points instead of sampling the
  surface.

  The tolerances are the config's `delta_thresholds`, by feature name, and three
  names are not features at all:

    * `n_steps` — send anyway after this many steps without sending;
    * `distance` — send if the point moved further than this from the last one
      sent;
    * `hsv` — hue is a circle, so the change is the shorter way round, and the
      tolerance is one number per channel.

  A percept already flagged as uninteresting — off the object, or with a surface
  the fit could not define — is passed on as it is, as Monty passes it: the filter
  decides between features and a location only, not whether to send.
  """

  @behaviour Monty.Frameworks.Models.SensorModules.PerceptFilter

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.SurfacePoseVectors

  # The two names that are not features.
  @not_features ["n_steps", "distance"]

  @enforce_keys [:delta_thresholds]
  defstruct delta_thresholds: %{}

  @type t :: %__MODULE__{delta_thresholds: map()}

  @typedoc """
  What the filter remembers: the last percept it sent on, and how long ago.
  """
  @type memory :: %{last_percept: Message.t() | nil, steps_since_sent: non_neg_integer()}

  @doc "The filter, and the memory a new episode starts with."
  @spec new(map()) :: {t(), memory()}
  def new(delta_thresholds), do: {%__MODULE__{delta_thresholds: delta_thresholds}, reset(nil)}

  @impl true
  def call(%__MODULE__{} = filter, %Message{} = percept, %{} = memory) do
    cond do
      not percept.pass_message ->
        {percept, memory}

      not percept.process_features_in_lm ->
        {percept, memory}

      memory.last_percept == nil ->
        {percept, %{memory | last_percept: percept, steps_since_sent: 0}}

      true ->
        judge(filter.delta_thresholds, percept, memory)
    end
  end

  @impl true
  def reset(_memory), do: %{last_percept: nil, steps_since_sent: 0}

  defp judge(thresholds, percept, memory) do
    significant? = significant_change?(thresholds, memory, percept)
    percept = %{percept | process_features_in_lm: significant?}

    if significant?,
      do: {percept, %{memory | last_percept: percept, steps_since_sent: 0}},
      else: {percept, %{memory | steps_since_sent: memory.steps_since_sent + 1}}
  end

  defp significant_change?(thresholds, memory, percept) do
    feature_changed?(thresholds, memory, percept) or
      steps_changed?(thresholds, memory) or
      moved_far_enough?(thresholds, memory, percept)
  end

  defp feature_changed?(thresholds, memory, percept) do
    thresholds
    |> Enum.reject(fn {feature, _tolerance} -> feature in @not_features end)
    |> Enum.any?(fn {feature, tolerance} ->
      changed?(feature, tolerance, feature_values(feature, memory.last_percept, percept))
    end)
  end

  # Hue is a circle, so the change is the shorter way round; saturation and value
  # are ordinary numbers with one tolerance each.
  defp changed?("hsv", [hue_tolerance | channel_tolerances], {last, current}) do
    hue_between =
      min(
        abs(Enum.at(current, 0) - Enum.at(last, 0)),
        1.0 - abs(Enum.at(current, 0) - Enum.at(last, 0))
      )

    hue_between > hue_tolerance or
      Enum.zip([Enum.drop(current, 1), Enum.drop(last, 1), channel_tolerances])
      |> Enum.any?(fn {value, previous, tolerance} -> abs(value - previous) > tolerance end)
  end

  # Only the surface normal is checked, which is what Monty checks: the curvature
  # directions of a nearly-flat surface are as good as arbitrary.
  defp changed?("pose_vectors", [angle_tolerance | _rest], {last, current}) do
    SpatialArithmetics.get_angle(normal_of(last), normal_of(current)) >= angle_tolerance
  end

  defp changed?(_feature, tolerance, {last, current}) when is_list(current),
    do:
      Enum.zip([current, last, List.wrap(tolerance)])
      |> Enum.any?(fn {value, previous, by} -> abs(value - previous) > by end)

  defp changed?(_feature, tolerance, {last, current}), do: abs(current - last) > tolerance

  defp steps_changed?(thresholds, memory) do
    case Map.fetch(thresholds, "n_steps") do
      {:ok, steps} -> memory.steps_since_sent >= steps
      :error -> false
    end
  end

  defp moved_far_enough?(thresholds, memory, percept) do
    case Map.fetch(thresholds, "distance") do
      {:ok, distance} ->
        SpatialArithmetics.magnitude(
          SpatialArithmetics.subtract(memory.last_percept.location, percept.location)
        ) > distance

      :error ->
        false
    end
  end

  defp feature_values(feature, last_percept, percept),
    do: {feature_value(last_percept, feature), feature_value(percept, feature)}

  defp feature_value(percept, feature) do
    case Message.feature(percept, feature) do
      {:ok, value} -> value
      {:error, _missing} -> nil
    end
  end

  defp normal_of(%SurfacePoseVectors{} = pose_vectors),
    do: SurfacePoseVectors.surface_normal(pose_vectors)

  defp normal_of(vectors) when is_list(vectors), do: hd(vectors)
end
