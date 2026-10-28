defmodule Monty.Frameworks.Models.MotorPoliciesTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{LookDown, LookUp, MoveForward, MoveTangentially, SetAgentPose}
  alias Monty.Frameworks.Models.MotorPolicies

  describe "undoing an action" do
    test "a look down is undone by the same look down, the other way round" do
      assert MotorPolicies.undo_last_action(%LookDown{
               agent_id: "agent",
               rotation_degrees: 30.0,
               constraint_degrees: 45.0
             }) == %LookDown{agent_id: "agent", rotation_degrees: -30.0, constraint_degrees: 45.0}
    end

    test "a look up is undone by a look up" do
      assert %LookUp{rotation_degrees: -10.0} =
               MotorPolicies.undo_last_action(%LookUp{agent_id: "agent", rotation_degrees: 10.0})
    end

    test "a move forward is undone by moving back the same distance" do
      assert %MoveForward{distance: -0.01} =
               MotorPolicies.undo_last_action(%MoveForward{agent_id: "agent", distance: 0.01})
    end

    test "a tangential move keeps its direction and goes the other way" do
      action = %MoveTangentially{agent_id: "agent", distance: 0.005, direction: [0.0, 1.0, 0.0]}

      assert MotorPolicies.undo_last_action(action) == %{action | distance: -0.005}
    end

    test "an action with no opposite is refused by name" do
      action = %SetAgentPose{
        agent_id: "agent",
        location: [0.0, 0.0, 0.0],
        rotation_quat: {1.0, 0.0, 0.0, 0.0}
      }

      assert_raise ArgumentError, ~r/cannot undo Monty.Frameworks.Actions.SetAgentPose/, fn ->
        MotorPolicies.undo_last_action(action)
      end
    end
  end
end
