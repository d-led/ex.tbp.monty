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

  defp features(observation) do
    {percept, _state} = SensorModule.step(observation, false, SensorModule.new("patch"))
    percept.non_morphological_features
  end

  test "a view of scenery alone is no coverage at all" do
    observation = %{
      "location" => [0.0, 0.0, 0.0],
      "depth" => [[1.0, 1.0], [1.0, 1.0]],
      "semantic" => [[0.0, 0.0], [0.0, 0.0]]
    }

    assert features(observation)["object_coverage"] == 0.0
  end

  test "and its depth is not the object's depth" do
    observation = %{
      "location" => [0.0, 0.0, 0.0],
      "depth" => [[1.0]],
      "semantic" => [[0.0]]
    }

    refute Map.has_key?(features(observation), "min_depth")
  end

  test "half the view on the object is half the coverage" do
    observation = %{
      "location" => [0.0, 0.0, 0.0],
      "depth" => [[0.05, 0.09], [1.0, 1.0]],
      "semantic" => [[1.0, 1.0], [0.0, 0.0]]
    }

    assert features(observation)["object_coverage"] == 0.5
  end

  test "and the object's depth is measured over the object's pixels only" do
    observation = %{
      "location" => [0.0, 0.0, 0.0],
      "depth" => [[0.05, 0.09], [1.0, 1.0]],
      "semantic" => [[1.0, 1.0], [0.0, 0.0]]
    }

    assert_in_delta features(observation)["min_depth"], 0.05, 1.0e-12
    assert_in_delta features(observation)["mean_depth"], 0.07, 1.0e-12
  end

  test "a world with no semantic image reports nothing but the object" do
    observation = %{"location" => [0.0, 0.0, 0.0], "depth" => [[0.04]]}

    assert features(observation)["object_coverage"] == 1.0
    assert_in_delta features(observation)["min_depth"], 0.04, 1.0e-12
  end
end
