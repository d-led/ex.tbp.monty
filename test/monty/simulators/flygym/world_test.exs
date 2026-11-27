defmodule Monty.Simulators.Flygym.WorldTest do
  # Not async: each case starts an operating-system process that steps MuJoCo,
  # and one case sets the interpreter variable for the whole machine.
  use ExUnit.Case, async: false

  alias Monty.Frameworks.Actions.OrientHorizontal
  alias Monty.Simulators.Flygym.World

  # The body is FlyGym in a MuJoCo this application's interpreter cannot hold, so
  # it runs in an interpreter a machine names; one without it runs everything else
  # and says why it cannot run this.
  if not World.available?() do
    @moduletag skip: World.unavailable_reason()
  end

  @agent "agent_id_0"

  # Where the body got to, read the way a run reads it: the motor system's own
  # agent state, not the peer's reply.
  defp agent_state(proprioceptive_state), do: Map.fetch!(proprioceptive_state, @agent)

  defp position(proprioceptive_state), do: agent_state(proprioceptive_state).position

  defp yaw(proprioceptive_state) do
    {w, x, y, z} =
      Monty.Geometry.Rotation.to_quaternion(agent_state(proprioceptive_state).rotation)

    :math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * 180 / :math.pi()
  end

  defp orient(turn_degrees, forward_metres) do
    %OrientHorizontal{
      agent_id: @agent,
      rotation_degrees: turn_degrees,
      left_distance: 0.0,
      forward_distance: forward_metres
    }
  end

  describe "a stride" do
    test "moves the body the distance the action asked for" do
      body = start_body()

      {_observations, state, body} = World.step(body, [orient(0.0, 0.005)])
      [x, _y, _z] = position(state)

      assert_in_delta x, 0.005, 0.001
      World.stop(body)
    end
  end

  describe "a turn" do
    test "turns the body the way the action asked, and the other way for the other sign" do
      body = start_body()

      {_observations, before, body} = World.step(body, [orient(0.0, 0.0)])
      {_observations, left, body} = World.step(body, [orient(25.0, 0.0)])
      {_observations, right, body} = World.step(body, [orient(-25.0, 0.0)])

      assert_in_delta yaw(left) - yaw(before), 25.0, 8.0
      assert_in_delta yaw(right) - yaw(left), -25.0, 8.0
      World.stop(body)
    end
  end

  describe "the eyes" do
    test "answer the compound eye's own percept, one sensor per eye" do
      body = start_body()

      {observations, _state, body} = World.step(body, [orient(0.0, 0.001)])
      eyes = Map.fetch!(observations, @agent)

      assert Map.keys(eyes) |> Enum.sort() == ["left", "right"]

      for {_sensor_id, eye} <- eyes do
        assert eye["what"] == "ommatidia"
        assert length(eye["ommatidia"]) == 721
      end

      World.stop(body)
    end
  end

  describe "a machine without an interpreter" do
    test "says what to do instead of starting a body that cannot step" do
      reason = World.unavailable_reason()

      if World.available?() do
        assert reason == ""
      else
        assert reason =~ "FLYGYM_PYTHON"
      end
    end

    test "refuses to build a body when no interpreter is named" do
      named = System.get_env("FLYGYM_PYTHON")
      System.delete_env("FLYGYM_PYTHON")

      assert_raise ArgumentError, ~r/FLYGYM_PYTHON/, fn -> World.new() end

      if named, do: System.put_env("FLYGYM_PYTHON", named)
    end
  end

  # A body whose process dies with this test: the world starts the peer, and the
  # link is what stops it. `World.stop/1` is exercised in each case because a run
  # stops its world the same way it stops its model.
  defp start_body do
    body = World.new(python: System.get_env("FLYGYM_PYTHON"))
    World.reset(body)
  end
end
