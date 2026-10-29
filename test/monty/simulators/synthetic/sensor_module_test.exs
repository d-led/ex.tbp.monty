defmodule Monty.Simulators.Synthetic.SensorModuleTest do
  @moduledoc """
  What a percept says, and what it refuses to say.

  A sensor module is now the ported `ObservationProcessor` and a percept filter
  behind a thin shell, so these tests are about the contract a percept has:
  the features the config declared and no others, the surface estimated from the
  patch, and a flag saying whether a learning module should learn this point.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.EnvironmentUtils.Transforms
  alias Monty.Frameworks.EnvironmentUtils.Transforms.{DepthTo3DLocations, MissingToMaxDepth}
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Synthetic.{Environment, Scene, SensorModule}

  # What the surf experiment's patch sensor declares
  # (`base_10simobj_surf_agent`), which is a surface sensor with a short filter.
  @features [
    "pose_vectors",
    "pose_fully_defined",
    "on_object",
    "object_coverage",
    "min_depth",
    "mean_depth",
    "hsv",
    "principal_curvatures",
    "principal_curvatures_log"
  ]

  defmodule Patch do
    @moduledoc false
    # A patch as the depth-to-points transform leaves it: one row per pixel,
    # `[x, y, z, on_surface]`, with the depth and colour images it came from.

    @green [0.0, 1.0, 0.0, 1.0]

    def new(options \\ []) do
      depths =
        Keyword.get(options, :depths, [
          [0.04, 0.04, 0.04],
          [0.04, 0.05, 0.04],
          [0.04, 0.04, 0.04]
        ])

      mask = Keyword.get(options, :mask, List.duplicate(List.duplicate(1.0, 3), 3))
      colour = Keyword.get(options, :rgba, List.duplicate(List.duplicate(@green, 3), 3))

      %{
        "location" => [0.0, 0.0, 0.1],
        "depth" => depths,
        "rgba" => colour,
        "cam_to_world" => [
          [1.0, 0.0, 0.0, 0.0],
          [0.0, 1.0, 0.0, 0.0],
          [0.0, 0.0, 1.0, 0.1],
          [0.0, 0.0, 0.0, 1.0]
        ],
        "semantic_3d" => rows(depths, mask)
      }
    end

    defp rows(depths, mask) do
      Enum.zip_with([List.flatten(depths), List.flatten(mask)], fn [depth, on_surface] ->
        [0.0, 0.0, -depth, on_surface]
      end)
    end
  end

  describe "a world that reports a patch" do
    test "gives a percept whose surface was estimated from it" do
      # The world answers depth, colour and semantic id — nothing else. The
      # surface is what a camera module makes of those, and on a five-centimetre
      # sphere the answer is the sphere's own curvature.
      percept = patched_sphere()

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
      refute patched_sphere().morphological_features["pose_fully_defined"]
    end

    test "and reports every feature its config declared, and no others" do
      features = patched_sphere().non_morphological_features

      # `pose_vectors`, `pose_fully_defined` and `on_object` are morphological:
      # properties of the surface rather than features to match on.
      assert Enum.sort(Map.keys(features)) ==
               Enum.sort(@features -- ["pose_vectors", "pose_fully_defined", "on_object"])

      assert features["object_coverage"] == 1.0
    end
  end

  describe "a patch" do
    test "reports its colour at the middle of the view, not at the first pixel" do
      green = [0.0, 1.0, 0.0, 1.0]
      red = [1.0, 0.0, 0.0, 1.0]

      features =
        Patch.new(rgba: [[green, green, green], [green, red, green], [green, green, green]])
        |> percept(features: ["rgba", "hsv"])
        |> Map.fetch!(:non_morphological_features)

      assert features["rgba"] == red
      assert features["hsv"] == SensorProcessing.rgb2hsv([1.0, 0.0, 0.0])
    end

    test "reports the share of it on the surface, and the depths over those pixels" do
      # Eight of nine pixels are on the surface; the ninth returned nothing.
      patch =
        Patch.new(
          depths: [[0.04, 0.04, 0.04], [0.04, 0.05, 0.04], [0.04, 0.04, 1.0]],
          mask: [[1.0, 1.0, 1.0], [1.0, 1.0, 1.0], [1.0, 1.0, 0.0]]
        )

      features = features(patch)

      assert_in_delta features["object_coverage"], 8 / 9, 1.0e-12
      assert features["min_depth"] == 0.04
      assert_in_delta features["mean_depth"], (7 * 0.04 + 0.05) / 8, 1.0e-12
    end

    test "follows the mask the transform left, not the depth image" do
      # Only one pixel was kept as on-surface; the rest are scenery however close
      # they are.
      patch =
        Patch.new(
          depths: [[0.04, 0.04, 0.04], [0.04, 0.02, 0.04], [0.04, 0.04, 0.04]],
          mask: [[0.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 0.0]]
        )

      features = features(patch)

      assert_in_delta features["object_coverage"], 1 / 9, 1.0e-12
      assert features["min_depth"] == 0.02
    end

    test "is not offered to a learning module when none of it is on the object" do
      percept = percept(Patch.new(mask: List.duplicate(List.duplicate(0.0, 3), 3)))

      assert percept.non_morphological_features["object_coverage"] == 0.0
      refute percept.process_features_in_lm
    end

    test "reports only the features its config asked for" do
      percept = percept(Patch.new(), features: ["on_object"])

      # The one exception is Monty's own: a sensor that asks for no curvature is
      # flagged with a `pose_fully_defined` of false, in the features rather than
      # among the morphological ones (`docs/monty-bugs.md` §1.10).
      assert percept.non_morphological_features == %{"pose_fully_defined" => false}
      assert percept.morphological_features["on_object"] == 1.0
    end
  end

  describe "an observation with no point cloud" do
    test "makes no percept at all" do
      # A world whose observations never went through the depth-to-points
      # transform has no surface to report, and a percept claiming one would be
      # inventing it.
      assert {nil, _state} = SensorModule.step(%{"location" => [0.1, 0.2, 0.3]}, false, sensor())
    end
  end

  describe "a motor-only step" do
    test "does not pass its message on, whatever the patch says" do
      {percept, _state} = SensorModule.step(Patch.new(), true, sensor())

      refute percept.pass_message
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp sensor(options \\ []) do
    SensorModule.new(
      "patch",
      Keyword.merge([features: @features, is_surface_sm: true], options)
    )
  end

  defp percept(observation, options \\ []) do
    {percept, _state} = SensorModule.step(observation, false, sensor(options))
    percept
  end

  defp features(observation), do: percept(observation).non_morphological_features

  # One sensor's observation of a sphere, after the experiment's transforms have
  # run — the patch a camera module is actually given.
  defp patched_sphere do
    world =
      Environment.new(["patch"], Scene.new(radius: 0.05),
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
    |> percept()
  end
end
