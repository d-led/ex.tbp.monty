defmodule Monty.Simulators.Synthetic.CoverageTest do
  @moduledoc """
  Coverage is about objects, not about pixels that returned a depth.

  Monty's camera module reports `object_coverage` as the fraction of the view
  whose semantic id is not background, and takes `min_depth`/`mean_depth` over
  those pixels only (`sensor_modules.py:213-216`). The difference decides whether
  a surface agent thinks it is looking at its object or at the scenery — with a
  `MissingToMaxDepth` transform in front, *every* pixel returns a depth, so a
  sensor counting returns would report full coverage while looking at a wall.
  """

  use ExUnit.Case, async: true

  alias Monty.Simulators.Synthetic.SensorModule

  # What a sensor's config asks it to report, and how it is built.
  @features ["object_coverage", "min_depth", "mean_depth"]

  defp features(observation), do: percept(observation).non_morphological_features

  # A surface sensor, which is what reports coverage: it is allowed to fit a
  # surface with its middle pixel off the object as long as part of the patch is
  # on it (`sensor_modules.py:216-222`).
  defp percept(observation) do
    sensor = SensorModule.new("patch", features: @features, is_surface_sm: true)
    {percept, _state} = SensorModule.step(observation, false, sensor)

    percept
  end

  # A patch as the depth-to-points transform leaves it: one row per pixel, three
  # coordinates and the on-surface mask, plus the depth image the transform was
  # given. `masked` says which pixels are on the surface.
  defp patch(depths, masked) do
    rows =
      Enum.zip_with([List.flatten(depths), List.flatten(masked)], fn [depth, mask] ->
        [0.0, 0.0, -depth, mask]
      end)

    %{
      "location" => [0.0, 0.0, 0.0],
      "depth" => depths,
      "semantic_3d" => rows,
      "cam_to_world" => [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0]
      ]
    }
  end

  test "a view of scenery alone is no coverage at all" do
    observation = patch([[1.0, 1.0], [1.0, 1.0]], [[0.0, 0.0], [0.0, 0.0]])

    assert features(observation)["object_coverage"] == 0.0
  end

  test "and its depth is not the object's depth" do
    observation = patch([[1.0]], [[0.0]])

    refute Map.has_key?(features(observation), "min_depth")
  end

  test "half the view on the object is half the coverage" do
    observation = patch([[0.05, 0.09], [1.0, 1.0]], [[1.0, 1.0], [0.0, 0.0]])

    assert features(observation)["object_coverage"] == 0.5
  end

  test "and the object's depth is measured over the object's pixels only" do
    observation = patch([[0.05, 0.09], [1.0, 1.0]], [[1.0, 1.0], [0.0, 0.0]])

    assert_in_delta features(observation)["min_depth"], 0.05, 1.0e-12
    assert_in_delta features(observation)["mean_depth"], 0.07, 1.0e-12
  end
end
