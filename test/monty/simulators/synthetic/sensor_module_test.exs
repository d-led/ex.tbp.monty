defmodule Monty.Simulators.Synthetic.SensorModuleTest do
  @moduledoc """
  A percept says what the image said, and what the world could not say.

  The difference matters downstream: a surface policy follows curvature only
  when the pose is fully defined, so a sensor that claimed a pose it does not
  have would have the policy steering by an invented surface — and a learning
  module configured for `hsv` or `principal_curvatures_log` needs those names to
  be there, computed the way a camera module computes them.
  """

  use ExUnit.Case, async: true

  alias Monty.Simulators.Synthetic.SensorModule

  defp state, do: SensorModule.new("patch")

  defp percept(observation, motor_only? \\ false) do
    {percept, _state} = SensorModule.step(observation, motor_only?, state())
    percept
  end

  describe "a world that reports a surface" do
    defp observation do
      %{
        "location" => [0.0, 0.0, 0.1],
        "value" => 0.0,
        "depth" => [[0.05]],
        "semantic" => [[1.0]],
        "principal_curvatures" => [-20.0, -20.0],
        "pose_vectors" => [[0.0, 0.0, 1.0], [0.0, -1.0, 0.0], [1.0, 0.0, 0.0]],
        "rgba" => [[0.0, 1.0, 0.0, 1.0]]
      }
    end

    test "gives a percept with that pose, defined" do
      {percept, _state} = SensorModule.step(observation(), false, state())

      assert percept.morphological_features["pose_fully_defined"]
      assert percept.morphological_features["pose_vectors"] != nil
    end

    test "and its features, under the names the policies and modules read" do
      assert percept(observation()).non_morphological_features == %{
               "value" => 0.0,
               "min_depth" => 0.05,
               "mean_depth" => 0.05,
               "object_coverage" => 1.0,
               "principal_curvatures" => [-20.0, -20.0],
               "principal_curvatures_log" => [-:math.log(21.0), -:math.log(21.0)],
               "rgba" => [0.0, 1.0, 0.0, 1.0],
               "hsv" => [1.0 / 3.0, 1.0, 1.0]
             }
    end

    test "and it goes on to the learning modules" do
      assert percept(observation()).process_features_in_lm
    end
  end

  describe "a camera that saw nothing where it was pointed" do
    test "reports no depth, and no coverage" do
      # Depth 0 is what a depth image has where the camera saw nothing.
      features =
        percept(%{"location" => [0.0, 0.0, 0.0], "depth" => [[0.0]], "semantic" => [[0.0]]})

      refute Map.has_key?(features.non_morphological_features, "min_depth")
      assert features.non_morphological_features["object_coverage"] == 0.0
      refute features.process_features_in_lm
    end
  end

  describe "a world that reports nothing at all" do
    test "gives a percept whose pose is explicitly not defined" do
      refute percept(%{"location" => [0.1, 0.2, 0.3]}).morphological_features[
               "pose_fully_defined"
             ]
    end

    test "and is still taken to be on the object it is looking at" do
      # A world with no geometry reports everything it has as the thing in front
      # of the sensor, so its percepts are not silently dropped.
      percept = percept(%{"location" => [0.1, 0.2, 0.3]})

      assert percept.morphological_features["on_object"] == 1.0
      assert percept.process_features_in_lm
    end

    test "and a motor-only step still does not pass its message on" do
      refute percept(%{"location" => [0.0, 0.0, 0.0]}, true).pass_message
    end
  end
end
