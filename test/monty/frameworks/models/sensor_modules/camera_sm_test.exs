defmodule Monty.Frameworks.Models.SensorModules.CameraSMTest do
  @moduledoc """
  What a percept says, what it refuses to say, and what noise does to it.

  `CameraSM` is the four layers Monty composes — observation processor, message
  noise, percept filter, snapshot telemetry — so these tests are about the
  contract between them: the features the config declared and no others, a
  surface estimated from the patch rather than told, a point withheld until it is
  worth learning, and noise that is reproducible from the episode's seed.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.EnvironmentUtils.Transforms
  alias Monty.Frameworks.EnvironmentUtils.Transforms.{DepthTo3DLocations, MissingToMaxDepth}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Models.SensorModules.CameraSM
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Synthetic.{Environment, Scene}

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

    test "says which object its middle pixel is on, as the world numbered it" do
      # The fourth column of a point is the world's semantic id — the same column
      # the transform reads to decide a pixel is on the object — so a patch on
      # object 3 says 3, and one that saw nothing says 0. It is Monty's logging
      # annotation, kept off the features so nothing matches on it.
      semantic = fn id -> List.duplicate(List.duplicate(id, 3), 3) end

      assert percept(Patch.new(mask: semantic.(3.0))).semantic_id == 3
      assert percept(Patch.new(mask: semantic.(0.0))).semantic_id == 0

      refute Map.has_key?(
               percept(Patch.new(mask: semantic.(3.0))).non_morphological_features,
               "semantic_id"
             )
    end
  end

  describe "an observation with no point cloud" do
    test "makes no percept at all" do
      # A world whose observations never went through the depth-to-points
      # transform has no surface to report, and a percept claiming one would be
      # inventing it.
      assert {nil, _sensor} =
               CameraSM.step(%{"location" => [0.1, 0.2, 0.3]}, false, ctx(), sensor())
    end
  end

  describe "a motor-only step" do
    test "does not pass its message on, whatever the patch says" do
      {percept, _sensor} = CameraSM.step(Patch.new(), true, ctx(), sensor())

      refute percept.pass_message
    end
  end

  describe "a sensor with no noise_params" do
    test "reports the same percept whatever the seed" do
      # Nothing is drawn from the stream, so there is nothing for a seed to
      # change — which is what makes an un-noised experiment reproducible.
      observation = patched_sphere_observation()

      assert percept(observation, ctx: ctx(1)) == percept(observation, ctx: ctx(2))
    end
  end

  describe "noise" do
    # The sphere's patch is a percept the sensor actually sends on: a flat patch
    # has no surface for a learning module to learn, and Monty adds feature noise
    # only to percepts that are sent (`sensor_modules.py:449`).
    setup do
      observation = patched_sphere_observation()
      assert percept(observation).process_features_in_lm

      {:ok, observation: observation}
    end

    test "comes from the episode's stream, so the same seed makes the same percept", %{
      observation: observation
    } do
      params = %{"location" => 0.001}

      assert noised(observation, params, ctx: ctx(7)).location ==
               noised(observation, params, ctx: ctx(7)).location

      refute noised(observation, params, ctx: ctx(7)).location ==
               noised(observation, params, ctx: ctx(8)).location
    end

    test "is not added to a percept with no features worth matching on" do
      # Monty's condition is `process_features_in_lm`: a percept that is only a
      # location has no features to noise.
      flat = Patch.new()
      refute percept(flat).process_features_in_lm

      assert noised(flat, %{"features" => %{"hsv" => 1000.0}}).non_morphological_features["hsv"] ==
               percept(flat).non_morphological_features["hsv"]
    end

    test "moves a real-valued feature off the value the fit found", %{observation: observation} do
      params = %{"features" => %{"principal_curvatures_log" => 5.0}}

      refute noised(observation, params).non_morphological_features["principal_curvatures_log"] ==
               percept(observation).non_morphological_features["principal_curvatures_log"]
    end

    test "flips a boolean as often as the noise amount says", %{observation: observation} do
      # A sphere bends the same amount both ways, so the flag starts false
      # (`sensor_modules.py:290-292`); a probability of one always flips it and a
      # probability of zero never does.
      flips = %{"features" => %{"pose_fully_defined" => 1.0}}
      never = %{"features" => %{"pose_fully_defined" => 0.0}}

      refute percept(observation).morphological_features["pose_fully_defined"]

      assert noised(observation, flips).morphological_features["pose_fully_defined"]
      refute noised(observation, never).morphological_features["pose_fully_defined"]
    end

    test "keeps a hue on the wheel, however hard it is pushed", %{observation: observation} do
      # There is no colour with a hue outside `[0, 1]`, and Monty clips rather
      # than reporting one (`sensor_modules.py:477-478`).
      [hue | _saturation_and_value] =
        noised(observation, %{"features" => %{"hsv" => 1000.0}}).non_morphological_features["hsv"]

      assert hue >= 0.0 and hue <= 1.0
    end

    test "turns a pose rather than nudging its three directions apart", %{
      observation: observation
    } do
      # Noise on a pose is a rotation: nudging each direction on its own would
      # stop the three being a frame, and every consumer of `pose_vectors`
      # assumes one.
      exact = percept(observation).morphological_features["pose_vectors"]

      turned =
        noised(observation, %{"features" => %{"pose_vectors" => 5.0}}).morphological_features[
          "pose_vectors"
        ]

      assert [x_axis, y_axis, z_axis] = turned.value
      assert_in_delta length_of(x_axis), 1.0, 1.0e-9
      assert_in_delta dot(x_axis, y_axis), 0.0, 1.0e-9
      assert_in_delta dot(y_axis, z_axis), 0.0, 1.0e-9

      refute turned == exact
    end

    test "moves the location a little, and only a little", %{observation: observation} do
      exact = percept(observation)
      moved = noised(observation, %{"location" => 0.001})

      offset =
        Enum.zip_with([moved.location, exact.location], fn [left, right] -> left - right end)

      assert length_of(offset) > 0.0
      assert length_of(offset) < 0.01
    end
  end

  describe "a sensor with delta_thresholds" do
    test "offers its first point to the learning module, and not the same one twice" do
      # Which is what a surface agent's filter is for: a new point per timestep
      # would fill its graph with near-identical points. The point is still sent
      # — it is the *features* the filter judges, not the message
      # (`sensor_modules.py:715-740`).
      observation = patched_sphere_observation()
      sensor = sensor(delta_thresholds: %{"distance" => 0.01, "n_steps" => 20})

      {first, sensor} = CameraSM.step(observation, false, ctx(), sensor)
      {second, _sensor} = CameraSM.step(observation, false, ctx(), sensor)

      assert first.process_features_in_lm
      refute second.process_features_in_lm
      assert second.pass_message
    end
  end

  describe "snapshot telemetry" do
    test "records the raw observation and the sensor's pose when asked to" do
      sensor = sensor(save_raw_obs: true) |> placed_at([1.0, 2.0, 3.0])
      observation = Patch.new()

      {_percept, sensor} = CameraSM.step(observation, false, ctx(), sensor)

      state = CameraSM.state_dict(sensor)
      assert state.raw_observations == [observation]

      assert [%{sm_location: location, sm_rotation: wxyz}] = state.sm_properties
      assert location == [1.0, 2.0, 3.0]
      assert_in_delta Enum.at(wxyz, 0), 1.0, 1.0e-12
    end

    test "records nothing when the config did not ask" do
      {_percept, sensor} = CameraSM.step(Patch.new(), false, ctx(), sensor())

      assert CameraSM.state_dict(sensor).raw_observations == []
    end

    test "is emptied for the next episode, along with the filter's memory" do
      sensor = sensor(save_raw_obs: true, delta_thresholds: %{"n_steps" => 20}) |> placed_at()

      {_percept, sensor} = CameraSM.step(Patch.new(), false, ctx(), sensor)
      reset = CameraSM.reset(sensor)

      # After a reset the next point is a new episode's first, so it is sent.
      {percept, _reset} = CameraSM.step(Patch.new(), false, ctx(), reset)

      assert CameraSM.state_dict(reset).raw_observations == []
      assert CameraSM.state_dict(reset).processed_observations == []
      assert percept.pass_message
    end

    test "records every percept in the order they were made" do
      observation = Patch.new()
      sensor = sensor(save_raw_obs: true) |> placed_at()
      {percept, sensor} = CameraSM.step(observation, false, ctx(), sensor)

      assert CameraSM.state_dict(sensor).processed_observations == [percept]
    end
  end

  describe "the sensor's pose" do
    test "is the agent's pose with the sensor's offset turned and added" do
      # Monty's `update_state`: `agent.position + rotate(agent.rotation,
      # sensor.position)`, and the rotations multiplied
      # (`sensor_modules.py:565-570`).
      agent = %AgentState{
        position: [1.0, 2.0, 3.0],
        rotation: quarter_turn_about_z(),
        sensors: %{
          "patch" => %SensorState{position: [0.1, 0.0, 0.0], rotation: Rotation.identity()}
        }
      }

      %SensorState{position: position, rotation: rotation} =
        CameraSM.update_state(agent, sensor()).pose

      Enum.zip_with([position, [1.0, 2.1, 3.0]], fn [actual, expected] ->
        assert_in_delta actual, expected, 1.0e-9
      end)

      assert rotation.wxyz == quarter_turn_about_z().wxyz
    end

    test "is refused when the agent has no such sensor" do
      agent = %AgentState{
        position: [0.0, 0.0, 0.0],
        rotation: Rotation.identity(),
        sensors: %{}
      }

      assert_raise ArgumentError, ~r/has no sensor/, fn ->
        CameraSM.update_state(agent, sensor())
      end
    end
  end

  describe "from_config/1" do
    test "builds the sensor an entry in Monty's config describes" do
      # The surf experiment's patch sensor, as `camera_surf_delta.yaml` writes it.
      {:ok, sensor} =
        CameraSM.from_config(%{
          "_target_" => "tbp.monty.frameworks.models.sensor_modules.CameraSM",
          "sensor_module_id" => "patch",
          "is_surface_sm" => true,
          "features" => ["on_object", "hsv"],
          "delta_thresholds" => %{"on_object" => 0, "n_steps" => 20},
          "save_raw_obs" => false
        })

      assert sensor.sensor_module_id == "patch"
      assert sensor.features == ["on_object", "hsv"]
      assert sensor.save_raw_obs == false
      assert sensor.processor.is_surface_sm
    end

    test "declines a sensor another class owns" do
      # Monty's surf experiments put the view finder behind
      # `ExperimentSensorModule`, which this port has not written.
      assert {:error, {:unsupported_sensor_module, _target}} =
               CameraSM.from_config(%{
                 "_target_" => "tbp.monty.experiment.sensor_module.ExperimentSensorModule",
                 "sensor_module_id" => "view_finder",
                 "features" => []
               })
    end

    test "declines a features list that was never resolved" do
      # `${constants.default_sensor_features}` is a Hydra interpolation; a sensor
      # built from the string would report features its config never named.
      assert {:error, {:unresolved_features, _features}} =
               CameraSM.from_config(%{
                 "_target_" => "tbp.monty.frameworks.models.sensor_modules.CameraSM",
                 "sensor_module_id" => "patch",
                 "features" => "${constants.default_sensor_features}"
               })
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp ctx(seed \\ 0), do: Context.new(seed)

  defp sensor(options \\ []) do
    CameraSM.new("patch", Keyword.merge([features: @features, is_surface_sm: true], options))
  end

  defp percept(observation, options \\ []) do
    {ctx, options} = Keyword.pop(options, :ctx, ctx())
    {percept, _sensor} = CameraSM.step(observation, false, ctx, sensor(options))
    percept
  end

  defp noised(observation, noise_params, options \\ []) do
    percept(observation, Keyword.put(options, :noise_params, noise_params))
  end

  defp features(observation), do: percept(observation).non_morphological_features

  # A sensor that has been told where it is, which only snapshot telemetry needs.
  defp placed_at(sensor, position \\ [0.0, 0.0, 0.0]) do
    CameraSM.update_state(
      %AgentState{
        position: position,
        rotation: Rotation.identity(),
        sensors: %{
          sensor.sensor_module_id => %SensorState{
            position: [0.0, 0.0, 0.0],
            rotation: Rotation.identity()
          }
        }
      },
      sensor
    )
  end

  defp length_of(vector), do: :math.sqrt(dot(vector, vector))
  defp dot(a, b), do: Enum.zip_with([a, b], fn [left, right] -> left * right end) |> Enum.sum()

  defp quarter_turn_about_z do
    {:ok, rotation} = Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 2)
    rotation
  end

  defp patched_sphere, do: percept(patched_sphere_observation())

  # One sensor's observation of a sphere, after the experiment's transforms have
  # run — the patch a camera module is actually given.
  defp patched_sphere_observation do
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
    |> Transforms.run(observations, Monty.Context.new(0), state)
    |> get_in(["agent_id_0", "patch"])
  end
end
