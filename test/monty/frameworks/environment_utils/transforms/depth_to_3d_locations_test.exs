defmodule Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DLocationsTest do
  @moduledoc """
  A depth image, as Monty's sensor modules are given it: points in the world, and
  a mask of which pixels are on the surface in the middle of the view.

  The numbers are chosen so the geometry is checkable by hand. A camera pointing
  down its own −z at 90 degrees of view and no zoom has an image plane half a
  unit wide, so the corner of a three-by-three grid is half a unit out and a unit
  down: `(0.5, 0.5, -1)` times its depth.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DLocations
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.Rotation

  describe "a pixel's depth, in the sensor's own frame" do
    test "is a point on the ray the pixel looks along" do
      observations = observe(%{"patch" => %{"depth" => image(0.5)}}, world_coord: false)

      assert_point(middle_point(observations, "patch"), [0.0, 0.0, -0.5, 1.0])
    end

    test "and the corners of the image are half a unit out at one unit of depth" do
      observations = observe(%{"patch" => %{"depth" => image(0.5)}}, world_coord: false)
      points = points(observations, "patch")

      assert_point(Enum.at(points, 0), [-0.5, 0.5, -0.5, 1.0])
      assert_point(Enum.at(points, 8), [0.5, -0.5, -0.5, 1.0])
    end

    test "and zooming in narrows the image plane with it" do
      observations =
        observe(%{"patch" => %{"depth" => image(0.5)}}, world_coord: false, zooms: 2.0)

      assert_point(Enum.at(points(observations, "patch"), 0), [-0.25, 0.25, -0.5, 1.0])
    end
  end

  describe "points in the world" do
    test "are the sensor's frame turned and moved to where the agent is" do
      # The agent stands half a metre up, its sensor a decimetre above that: a
      # pixel two metres below the sensor is 1.9 m below the world's origin.
      %{observations: observations} = observe_in_world(%{"patch" => %{"depth" => image(0.5)}})

      assert_point(middle_point(observations, "patch"), [0.0, 0.5, -0.4, 1.0])
    end

    test "and the frame they are expressed in comes with them" do
      %{observations: observations} = observe_in_world(%{"patch" => %{"depth" => image(0.5)}})

      cam_to_world = get_in(observations, ["agent_id_0", "patch", "cam_to_world"])

      # The sensor's forward is its own +z, which is what a surface normal is
      # flipped against, and where it is is the agent's place plus its own
      # offset turned by the agent's rotation.
      assert view_direction(cam_to_world) == [0.0, 0.0, 1.0]
      assert translation(cam_to_world) == [0.0, 0.5, 0.1]
    end

    test "and a sensor frame is answered alongside when the experiment asks for one" do
      %{observations: observations} =
        observe_in_world(%{"patch" => %{"depth" => image(0.5)}}, get_all_points: true)

      sensor_frame_data = get_in(observations, ["agent_id_0", "patch", "sensor_frame_data"])

      assert_point(Enum.at(sensor_frame_data, 4), [0.0, 0.0, -0.5, 1.0])
    end

    test "but not when the experiment asks for the pixels on the object only" do
      %{observations: observations} =
        observe_in_world(%{"patch" => %{"depth" => image(0.5)}}, get_all_points: false)

      refute Map.has_key?(get_in(observations, ["agent_id_0", "patch"]), "sensor_frame_data")
    end
  end

  describe "which pixels are on the object" do
    test "is the depth image's answer: a metre away is not the object" do
      observations =
        observe(%{"patch" => %{"depth" => [[0.5, 1.0, 0.5], [1.0, 0.5, 1.0], [0.5, 1.0, 0.5]]}},
          world_coord: false
        )

      # `MissingToMaxDepth` has already turned what the camera could not see into
      # a metre, which is why a metre is where the object stops.
      assert surface_mask(observations, "patch") == [1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0]
    end

    test "and a semantic sensor's own mask when the experiment reads one" do
      observations =
        observe(
          %{"patch" => %{"depth" => image(0.5), "semantic" => two_surfaces(1.0, 0.0)}},
          world_coord: false,
          use_semantic_sensor: true
        )

      assert surface_mask(observations, "patch") == [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0]
    end
  end

  describe "which pixels are on the surface in the middle of the view" do
    test "is all of them when the whole patch is one distance" do
      # A distant agent sees no surface in particular, so its threshold is the
      # whole view.
      surface = DepthTo3DLocations.get_surface_from_depth(image(0.5), image(1.0), 1000.0)

      assert List.flatten(surface) == List.duplicate(1.0, 9)
    end

    test "and only the near one when a far surface is in view too" do
      # Two surfaces a decimetre apart with the near one in the middle of the
      # view: a normal fitted across both would be a normal of nothing.
      surface = DepthTo3DLocations.get_surface_from_depth(two_surfaces(0.4, 0.5), image(1.0), 1.0)

      assert List.flatten(surface) == [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0]
    end

    test "and only the far one when that is what the middle of the view is on" do
      surface = DepthTo3DLocations.get_surface_from_depth(two_surfaces(0.5, 0.4), image(1.0), 1.0)

      assert List.flatten(surface) == [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0]
    end

    test "and nothing at all when the whole patch sees nothing" do
      surface = DepthTo3DLocations.get_surface_from_depth(image(1.0), image(1.0), 1.0)

      assert List.flatten(surface) == List.duplicate(0.0, 9)
    end
  end

  describe "a surface agent's finger" do
    test "does not reach past the clip value" do
      observations =
        observe(%{"patch" => %{"depth" => two_surfaces(0.04, 0.06)}},
          depth_clip_sensors: [0],
          clip_value: 0.05
        )

      # Beyond the finger's reach there is no object, and no distance either: the
      # depth becomes the reach, so a policy asking "is it nearer than 5 cm?"
      # gets the finger's answer rather than the renderer's.
      assert get_in(observations, ["agent_id_0", "patch", "depth"]) == two_surfaces(0.04, 0.05)
      assert surface_mask(observations, "patch") == [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0]
    end

    test "and a depth of zero is as far as the finger goes, not zero distance" do
      observations =
        observe(%{"patch" => %{"depth" => image(0.0)}},
          depth_clip_sensors: [0],
          clip_value: 0.05
        )

      assert get_in(observations, ["agent_id_0", "patch", "depth"]) == image(0.05)
    end

    test "while a sensor that is not the finger keeps the whole view" do
      observations =
        observe(
          %{"patch" => %{"depth" => image(0.04)}, "view_finder" => %{"depth" => image(3.0)}},
          depth_clip_sensors: [0],
          clip_value: 0.05
        )

      assert get_in(observations, ["agent_id_0", "view_finder", "depth"]) == image(3.0)
    end
  end

  describe "from a config" do
    test "it takes the cameras its sensors look through and where the finger reaches" do
      transform =
        DepthTo3DLocations.from_config(%{
          "_target_" => "tbp.monty.frameworks.environment_utils.transforms.DepthTo3DLocations",
          "agent_id" => "agent_id_0",
          "sensor_ids" => ["patch", "view_finder"],
          "resolutions" => [[64, 64], [64, 64]],
          "zooms" => [10.0, 1.0],
          "world_coord" => true,
          "get_all_points" => true,
          "use_semantic_sensor" => false,
          "depth_clip_sensors" => [0],
          "clip_value" => 0.05
        })

      assert [patch, view_finder] = transform.intrinsics
      assert patch.height == 64
      assert_in_delta patch.fx, 0.1, 1.0e-12
      assert_in_delta view_finder.fx, 1.0, 1.0e-12
      assert transform.depth_clip_sensors == [0]
      assert transform.clip_value == 0.05
      assert transform.get_all_points
    end
  end

  # -- fixtures --------------------------------------------------------------

  # The transform, run on the agent the stand-in world's proprioceptive state
  # describes. `seen` is what each sensor observed.
  defp observe(seen, options) do
    %{observations: observations} = observe_in_world(seen, options)
    observations
  end

  defp observe_in_world(seen, options \\ []) do
    sensors = seen |> Map.keys() |> Enum.sort()
    transform = transform(Keyword.put(options, :sensor_ids, sensors))
    state = proprioceptive_state()

    {DepthTo3DLocations.call(%{"agent_id_0" => seen}, transform, state), state}
    |> then(fn {observations, state} ->
      %{observations: observations, proprioceptive_state: state}
    end)
  end

  defp transform(options) do
    sensor_ids = Keyword.fetch!(options, :sensor_ids)

    DepthTo3DLocations.new(
      Keyword.merge(
        [
          agent_id: "agent_id_0",
          resolutions: List.duplicate({3, 3}, length(sensor_ids)),
          hfov: 90.0,
          world_coord: true,
          get_all_points: true
        ],
        options
      )
    )
  end

  # A three-by-three patch all at one distance.
  defp image(depth), do: List.duplicate(List.duplicate(depth, 3), 3)

  # A three-by-three patch whose middle row is `middle` and whose other rows are
  # `edges`: two surfaces in one view, with the one in the middle of the view
  # named.
  defp two_surfaces(middle, edges) do
    [List.duplicate(edges, 3) | List.duplicate(List.duplicate(middle, 3), 1)] ++
      List.duplicate(List.duplicate(edges, 3), 1)
  end

  defp proprioceptive_state do
    %{
      "agent_id_0" => %AgentState{
        position: [0.0, 0.5, 0.0],
        rotation: Rotation.identity(),
        sensors: %{
          "patch" => %SensorState{position: [0.0, 0.0, 0.1], rotation: Rotation.identity()},
          "view_finder" => %SensorState{position: [0.0, 0.0, 0.03], rotation: Rotation.identity()}
        }
      }
    }
  end

  defp points(observations, sensor_id),
    do: get_in(observations, ["agent_id_0", sensor_id, "semantic_3d"])

  defp middle_point(observations, sensor_id), do: observations |> points(sensor_id) |> Enum.at(4)

  defp surface_mask(observations, sensor_id),
    do: observations |> points(sensor_id) |> Enum.map(&List.last/1)

  # The grid halves exactly, but `tan(90 / 2)` is not quite one, so a point is
  # compared to a tolerance rather than matched.
  defp assert_point([x, y, z, on_surface], [expected_x, expected_y, expected_z, expected_mask]) do
    assert_in_delta x, expected_x, 1.0e-12
    assert_in_delta y, expected_y, 1.0e-12
    assert_in_delta z, expected_z, 1.0e-12
    assert on_surface == expected_mask
  end

  defp view_direction(cam_to_world), do: Enum.map(Enum.take(cam_to_world, 3), &Enum.at(&1, 2))

  defp translation(cam_to_world), do: Enum.map(Enum.take(cam_to_world, 3), &Enum.at(&1, 3))
end
