defmodule Monty.Simulators.ExMujoco.WorldTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{MoveForward, OrientHorizontal}
  alias Monty.Simulators.ExMujoco.World

  # The world renders its sensors, so it needs an OpenGL context; a machine
  # without one runs everything else and says why it cannot run this.
  if not ExMujoco.Renderer.available?() do
    @moduletag skip: ExMujoco.Renderer.unavailable_reason()
  end

  @agent "agent_id_0"

  # A box a hand's width across, half a metre under a patch that looks straight
  # down at it. MuJoCo's sizes are half-extents, so a 0.1 box reaches 0.1 m up
  # and its top is 0.4 m from the camera.
  defp scene(overrides) do
    Map.merge(
      %{
        "data_path" => nil,
        "agents" => [
          %{
            "agent_id" => @agent,
            "class" => "SurfaceAgent",
            "position" => [0.0, 0.0, 0.5],
            "rotation" => [1.0, 0.0, 0.0, 0.0],
            "sensor_configs" => %{
              "patch" => %{
                "height" => 64,
                "width" => 64,
                "zoom" => 1.0,
                "position" => [0.0, 0.0, 0.0],
                "rotation" => [1.0, 0.0, 0.0, 0.0],
                "semantic" => true
              }
            }
          }
        ],
        "objects" => [
          %{
            "name" => "box",
            "position" => [0.0, 0.0, 0.0],
            "scale" => [0.1, 0.1, 0.1],
            "semantic_id" => 7
          }
        ]
      },
      overrides
    )
  end

  defp world(overrides) do
    scene(overrides)
    |> Map.take(["data_path", "agents", "objects"])
    |> then(fn options ->
      World.new(
        data_path: options["data_path"],
        agents: options["agents"],
        objects: options["objects"]
      )
    end)
    |> World.reset()
  end

  describe "what an episode is about" do
    test "the object the scene holds, named" do
      world = world(%{})

      assert world.primary_target["object_name"] == "box"
      assert world.primary_target["semantic_id"] == 7
      assert world.primary_target["position"] == [0.0, 0.0, 0.0]
    end

    test "and what each semantic id means, so a log can name what was seen" do
      assert world(%{}).semantic_id_to_label == %{7 => "box"}
    end

    test "a scene with no object is about nothing, rather than about a guess" do
      assert world(%{"objects" => []}).primary_target == nil
    end
  end

  test "it never moves an agent on its own: the actions do" do
    refute World.positions_itself?()
  end

  describe "a step" do
    test "answers observations and proprioceptive state in Monty's shapes" do
      {observations, state, _world} = World.step(world(%{}), [])

      assert %{"depth" => depth, "rgba" => rgba, "semantic" => semantic} =
               observations[@agent]["patch"]

      assert length(depth) == 64
      assert length(hd(depth)) == 64
      assert [red, green, blue, 255] = hd(hd(rgba))
      assert is_integer(red) and is_integer(green) and is_integer(blue)
      # Monty's ids, not MuJoCo's: background is 0 and nothing is negative.
      assert semantic |> List.flatten() |> Enum.all?(&(is_integer(&1) and &1 >= 0))

      assert %{position: [0.0, 0.0, 0.5], rotation: rotation} = state[@agent]
      assert rotation == %Monty.Geometry.Rotation{wxyz: {1.0, 0.0, 0.0, 0.0}}
    end

    test "moves the agent along the axis the action names" do
      {_observations, state, _world} =
        World.step(world(%{}), [%MoveForward{agent_id: @agent, distance: 0.1}])

      # Forward is the body's own -z, and this body is level: it descends.
      assert_in_delta Enum.at(state[@agent].position, 2), 0.4, 1.0e-9
    end

    test "leaves the other axes alone when the body is level" do
      {_observations, state, _world} =
        World.step(world(%{}), [%MoveForward{agent_id: @agent, distance: 0.1}])

      assert_in_delta Enum.at(state[@agent].position, 0), 0.0, 1.0e-12
      assert_in_delta Enum.at(state[@agent].position, 1), 0.0, 1.0e-12
    end

    test "orbits sideways, turns and comes forward the way the surface agent asks" do
      {_observations, state, _world} =
        World.step(world(%{}), [
          %OrientHorizontal{
            agent_id: @agent,
            rotation_degrees: 90,
            left_distance: 0.0,
            forward_distance: 0.0
          }
        ])

      # A right turn of 90°: the body's own x now points where world -y did.
      assert %{rotation: rotation} = state[@agent]
      assert_in_delta elem(rotation.wxyz, 0), :math.cos(:math.pi() / 4), 1.0e-9
    end
  end

  describe "what the patch sees" do
    test "the object, under it, at the distance it is at" do
      {observations, _state, _world} = World.step(world(%{}), [])

      assert observations[@agent]["patch"]["semantic"] |> centre() == 7
      assert_in_delta observations[@agent]["patch"]["depth"] |> centre(), 0.4, 0.001
    end

    test "an object named no semantic id takes MuJoCo's own number for its shape" do
      unnamed =
        world(%{
          "objects" => [
            %{
              "name" => "box",
              "position" => [0.0, 0.0, 0.0],
              "scale" => [0.1, 0.1, 0.1],
              "semantic_id" => nil
            }
          ]
        })

      assert unnamed.semantic_id_to_label == %{ExMujoco.Types.Geom.box() => "box"}
    end

    test "only the sensors a positioning step names are drawn" do
      {observations, _state, _world} = World.step(world(%{}), [], ["elsewhere"])

      assert observations[@agent] == %{}
    end
  end

  describe "an episode" do
    test "starts again where it started, with the head level" do
      world = world(%{})

      {_observations, start, world} = World.step(world, [])

      {_observations, moved, world} =
        World.step(world, [%MoveForward{agent_id: @agent, distance: 0.1}])

      refute moved[@agent].position == start[@agent].position

      {_observations, again, _world} = World.step(World.reset(world), [])

      assert again[@agent].position == start[@agent].position
    end
  end

  defp centre(rows) do
    rows
    |> Enum.at(32)
    |> Enum.at(32)
  end
end
