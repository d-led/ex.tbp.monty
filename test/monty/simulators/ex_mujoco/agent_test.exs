defmodule Monty.Simulators.ExMujoco.AgentTest do
  use ExUnit.Case, async: true

  alias Monty.Simulators.ExMujoco.{Agent, Orientation}

  # The action vocabulary as a run sends it: `ActionJSONEncoder`'s words, which
  # `priv/monty_py/world.py` also reads, so an action cannot mean two things in
  # two worlds. Monty's own cases for these live in
  # `tests/unit/simulators/mujoco/agent_actions_test.py`, driven by hypothesis
  # there; these are hand-written behaviour cases, not a translation of them.
  defp action(name, fields), do: Map.put(fields, "action", name)

  defp surface(overrides \\ %{}) do
    agent(Map.merge(%{class: "SurfaceAgent"}, overrides))
  end

  defp distant(overrides \\ %{}) do
    agent(Map.merge(%{class: "DistantAgent"}, overrides))
  end

  defp agent(fields) do
    struct!(
      Agent,
      Map.merge(
        %{
          id: "agent_id_0",
          sensors: %{},
          free: 0,
          pitch: 7,
          position: [0.0, 0.0, 0.0],
          rotation: Orientation.identity(),
          pitch_degrees: 0.0,
          origin: {[0.0, 0.0, 0.0], Orientation.identity()}
        },
        fields
      )
    )
  end

  defp moved_along(agent, index), do: Enum.at(agent.position, index)

  describe "a surface agent" do
    test "moves forward along the axis it faces, which is the body's own -z" do
      agent = surface(%{position: [0.0, 0.0, 0.5]})

      assert %Agent{position: [_, _, z]} =
               Agent.act(agent, action("move_forward", %{"distance" => 0.1}), false)

      assert_in_delta z, 0.4, 1.0e-9
    end

    test "orbits horizontally: sideways along the body's own x, then a turn, then forward" do
      agent = surface()

      assert %Agent{position: position, rotation: rotation} =
               Agent.act(
                 agent,
                 action("orient_horizontal", %{
                   "left_distance" => 0.2,
                   "forward_distance" => 0.0,
                   "rotation_degrees" => 0.0
                 }),
                 false
               )

      # Monty's left is the body's own -x, which is what a policy's left distance
      # means in the scene either world builds.
      assert_in_delta Enum.at(position, 0), -0.2, 1.0e-9
      assert Orientation.euler_y(rotation) == 0.0
    end

    test "a horizontal orbit with no sideways part is a turn about the vertical" do
      agent = surface()

      assert %Agent{rotation: rotation} =
               Agent.act(
                 agent,
                 action("orient_horizontal", %{
                   "left_distance" => 0.0,
                   "forward_distance" => 0.0,
                   "rotation_degrees" => 90.0
                 }),
                 false
               )

      assert_in_delta Orientation.euler_y(rotation), -:math.pi() / 2.0, 1.0e-9
    end

    test "orbits vertically: down along the body's own y, then a pitch" do
      agent = surface(%{position: [0.0, 0.0, 0.5]})

      assert %Agent{position: position, rotation: rotation} =
               Agent.act(
                 agent,
                 action("orient_vertical", %{
                   "down_distance" => 0.1,
                   "forward_distance" => 0.0,
                   "rotation_degrees" => 30.0
                 }),
                 false
               )

      assert_in_delta Enum.at(position, 1), -0.1, 1.0e-9
      assert_in_delta Enum.at(position, 2), 0.5, 1.0e-9
      assert_in_delta Orientation.euler_x(rotation), :math.pi() / 6.0, 1.0e-9
    end

    test "a tangential move of nothing is nothing" do
      agent = surface(%{position: [0.1, 0.2, 0.3]})

      assert Agent.act(
               agent,
               action("move_tangentially", %{"distance" => 0.0, "direction" => [1.0, 0.0, 0.0]}),
               false
             ) == agent
    end

    test "a tangential move is in the world already, so a turned body does not turn it" do
      turned = surface(%{rotation: Orientation.about_y(90.0)})

      tangent =
        Agent.act(
          turned,
          action("move_tangentially", %{"distance" => 0.1, "direction" => [1.0, 0.0, 0.0]}),
          false
        )

      assert_in_delta moved_along(tangent, 0), 0.1, 1.0e-9
      assert tangent.rotation == turned.rotation
    end

    test "accepts a pose, position and rotation together" do
      pose =
        Agent.act(
          surface(),
          action("set_agent_pose", %{
            "location" => [0.1, 0.2, 0.3],
            "rotation_quat" => [1.0, 0.0, 0.0, 0.0]
          }),
          false
        )

      assert pose.position == [0.1, 0.2, 0.3]
      assert pose.rotation == Orientation.identity()
    end

    test "a sensor rotation keeps only its angle about x, because the head is a hinge" do
      # A rotation that yaws 30° and pitches 20°: a hinge can only do the second,
      # so the yaw is dropped rather than the head being turned sideways.
      pitched = Orientation.multiply(Orientation.about_y(30.0), Orientation.about_x(20.0))

      head =
        Agent.act(
          surface(),
          action("set_sensor_rotation", %{"rotation_quat" => Tuple.to_list(pitched)}),
          false
        )

      assert_in_delta head.pitch_degrees, 20.0, 1.0e-9
    end
  end

  describe "a distant agent: a camera that looks from where it stands" do
    test "moves forward along the body's own -z" do
      agent = distant(%{position: [0.0, 0.0, 0.5]})

      assert %Agent{position: [_, _, z]} =
               Agent.act(agent, action("move_forward", %{"distance" => 0.1}), false)

      assert_in_delta z, 0.4, 1.0e-9
    end

    test "turns left and right in opposite directions, and the two cancel" do
      agent = distant()

      left = Agent.act(agent, action("turn_left", %{"rotation_degrees" => 30.0}), false)
      right = Agent.act(agent, action("turn_right", %{"rotation_degrees" => 30.0}), false)

      assert_in_delta Orientation.euler_y(left.rotation), :math.pi() / 6.0, 1.0e-9
      assert_in_delta Orientation.euler_y(right.rotation), -:math.pi() / 6.0, 1.0e-9

      assert %Agent{rotation: {w, x, y, z}} =
               right |> Agent.act(action("turn_left", %{"rotation_degrees" => 30.0}), false)

      assert_in_delta w, 1.0, 1.0e-9
      assert_in_delta x + y + z, 0.0, 1.0e-9
    end

    test "looks up and down with the head, not the body" do
      agent = distant()

      up =
        Agent.act(
          agent,
          action("look_up", %{"rotation_degrees" => 15.0, "constraint_degrees" => nil}),
          false
        )

      down =
        Agent.act(
          agent,
          action("look_down", %{"rotation_degrees" => 15.0, "constraint_degrees" => nil}),
          false
        )

      assert up.pitch_degrees == 15.0
      assert down.pitch_degrees == -15.0
      assert up.rotation == agent.rotation
    end

    test "a constrained look stops at the constraint rather than refusing to move" do
      agent = distant(%{pitch_degrees: 10.0})
      constraint = 20.0

      up =
        Agent.act(
          agent,
          action("look_up", %{"rotation_degrees" => 30.0, "constraint_degrees" => constraint}),
          false
        )

      down =
        Agent.act(
          agent,
          action("look_down", %{"rotation_degrees" => 90.0, "constraint_degrees" => constraint}),
          false
        )

      assert up.pitch_degrees == constraint
      assert down.pitch_degrees == -constraint
    end
  end

  describe "an action an agent does not have" do
    test "is ignored when the scene says a missing action is not an error" do
      agent = surface()

      assert Agent.act(agent, action("no_such_action", %{}), false) == agent
    end

    test "names the agent and the action when it is an error" do
      error =
        assert_raise RuntimeError, fn ->
          Agent.act(surface(), action("no_such_action", %{}), true)
        end

      assert error.message == "SurfaceAgent does not understand 'actuate_no_such_action'"
    end

    test "an agent with no vocabulary at all understands none of them" do
      nothing = agent(%{class: "NoopAgent"})

      assert Agent.act(nothing, action("move_forward", %{"distance" => 0.1}), false) == nothing

      assert_raise RuntimeError, fn ->
        Agent.act(nothing, action("move_forward", %{"distance" => 0.1}), true)
      end
    end
  end
end
