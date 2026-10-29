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

  alias Monty.Frameworks.EnvironmentUtils.Transforms
  alias Monty.Frameworks.EnvironmentUtils.Transforms.{DepthTo3DLocations, MissingToMaxDepth}
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Synthetic.{Environment, Scene, SensorModule}

  # One sensor's observation of a sphere, after the experiment's transforms have
  # run — the patch a camera module is actually given.
  defp patched_sphere do
    scene = Scene.new(radius: 0.05)

    world =
      Environment.new(["patch"], scene,
        views: %{"patch" => [resolution: 21, hfov: 90.0, zoom: 10.0]},
        agent: %{position: [0.0, 0.0, 0.1], rotation: Rotation.identity()},
        sensors: %{"patch" => %{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}}
      )

    {observations, state, _world} = Environment.step(world, [])

    transforms = [
      MissingToMaxDepth.new(agent_id: "agent_id_0", max_depth: 1.0),
      DepthTo3DLocations.new(
        agent_id: "agent_id_0",
        sensor_ids: ["patch"],
        resolutions: [{21, 21}],
        zooms: 10.0,
        get_all_points: true
      )
    ]

    transforms
    |> Transforms.run(observations, state)
    |> get_in(["agent_id_0", "patch"])
  end

  defp state, do: SensorModule.new("patch")

  defp percept(observation, motor_only? \\ false) do
    {percept, _state} = SensorModule.step(observation, motor_only?, state())
    percept
  end

  describe "a world that reports a patch" do
    test "gives a percept whose surface was estimated from it" do
      # The world answers depth, colour and semantic id — nothing else. The
      # surface is what a camera module makes of those, and on a five-centimetre
      # sphere the answer is the sphere's own curvature.
      percept = percept(patched_sphere())

      assert percept.morphological_features["on_object"] == 1.0

      # The sensor is above the sphere looking down at it, so the surface it is
      # on faces back up.
      [normal | _directions] = percept.morphological_features["pose_vectors"].value
      assert_in_delta Enum.at(normal, 2), 1.0, 1.0e-6

      [first, second] = percept.non_morphological_features["principal_curvatures"]
      assert_in_delta first, -20.0, 1.0
      assert_in_delta second, -20.0, 1.0
    end

    test "and says the curvature directions mean nothing when the surface curves both ways alike" do
      # Monty's `pc1_is_pc2_threshold`: a sphere bends the same amount in every
      # direction, so its curvature directions are arbitrary and a policy that
      # followed them would be following noise (`sensor_modules.py:290-292`).
      refute percept(patched_sphere()).morphological_features["pose_fully_defined"]
    end

    test "and the features a learning module weights are there, under their own names" do
      features = percept(patched_sphere()).non_morphological_features

      assert Map.has_key?(features, "principal_curvatures")
      assert Map.has_key?(features, "principal_curvatures_log")
      assert Map.has_key?(features, "object_coverage")
      assert Map.has_key?(features, "hsv")
      assert features["object_coverage"] == 1.0
    end
  end

  describe "a patch of more than one pixel" do
    # Three by three: the middle sees the surface at five centimetres, one corner
    # sees nothing.
    defp patch(observation) do
      Map.merge(
        %{
          "location" => [0.0, 0.0, 0.1],
          "depth" => [[0.04, 0.04, 0.04], [0.04, 0.05, 0.04], [0.04, 0.04, 1.0]],
          "semantic" => [[1.0, 1.0, 1.0], [1.0, 1.0, 1.0], [1.0, 1.0, 0.0]],
          "rgba" => List.duplicate(List.duplicate([0.0, 1.0, 0.0, 1.0], 3), 3)
        },
        observation
      )
    end

    test "reads its colour at the middle of the view, not at the first pixel" do
      green = [0.0, 1.0, 0.0, 1.0]
      red = [1.0, 0.0, 0.0, 1.0]

      features =
        percept(
          patch(%{"rgba" => [[green, green, green], [green, red, green], [green, green, green]]})
        )
        |> Map.fetch!(:non_morphological_features)

      assert features["rgba"] == red
      assert features["hsv"] == SensorProcessing.rgb2hsv([1.0, 0.0, 0.0])
    end

    test "and covers the share of it that is on the object" do
      features = percept(patch(%{})) |> Map.fetch!(:non_morphological_features)

      # Eight of nine pixels see the object; the ninth returned nothing.
      assert_in_delta features["object_coverage"], 8 / 9, 1.0e-12
      assert features["min_depth"] == 0.04
      assert_in_delta features["mean_depth"], (7 * 0.04 + 0.05) / 8, 1.0e-12
    end

    test "and follows the mask the transform left, not the colours" do
      # Only the pixel the transform kept as on-surface counts, whatever the
      # semantic image would have said on its own.
      on_surface = fn mask, depth -> [0.0, 0.0, depth, mask] end

      kept = [
        on_surface.(0.0, 0.04),
        on_surface.(1.0, 0.02),
        on_surface.(0.0, 0.04),
        on_surface.(0.0, 0.04),
        on_surface.(0.0, 0.04),
        on_surface.(0.0, 0.04),
        on_surface.(0.0, 0.04),
        on_surface.(0.0, 0.04),
        on_surface.(0.0, 0.04)
      ]

      features =
        percept(patch(%{"semantic_3d" => kept})) |> Map.fetch!(:non_morphological_features)

      assert_in_delta features["object_coverage"], 1 / 9, 1.0e-12
      assert features["min_depth"] == 0.04
      assert features["mean_depth"] == 0.04
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
