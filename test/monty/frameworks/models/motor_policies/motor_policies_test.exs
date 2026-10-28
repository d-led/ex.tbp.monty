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

  describe "angles and directions" do
    test "a change of direction is the short way round, not the long one" do
      # Three quarters of a turn forward is a quarter turn back.
      assert_in_delta MotorPolicies.theta_change(0.0, 3.0 * :math.pi() / 2.0),
                      :math.pi() / 2.0,
                      1.0e-12

      assert_in_delta MotorPolicies.theta_change(3.0 * :math.pi() / 2.0, 0.0),
                      -:math.pi() / 2.0,
                      1.0e-12
    end

    test "an angle beyond half a turn comes back inside it" do
      assert_in_delta MotorPolicies.enforce_pi_bounds(3.0 * :math.pi()), :math.pi(), 1.0e-12
      assert_in_delta MotorPolicies.enforce_pi_bounds(-3.0 * :math.pi()), -:math.pi(), 1.0e-12
      assert_in_delta MotorPolicies.enforce_pi_bounds(0.5), 0.5, 1.0e-12
    end

    test "an angle of zero points up in the agent's frame, not right" do
      [x, y, z] = MotorPolicies.projected_vec_from_angle(0.0)

      assert_in_delta x, 0.0, 1.0e-12
      assert_in_delta y, 1.0, 1.0e-12
      assert_in_delta z, 0.0, 1.0e-12
    end

    test "and a quarter turn points right" do
      [x, y, _z] = MotorPolicies.projected_vec_from_angle(:math.pi() / 2.0)

      assert_in_delta x, 1.0, 1.0e-12
      assert_in_delta y, 0.0, 1.0e-12
    end

    test "a direction and an angle say the same thing" do
      for angle <- [-3.0, -1.0, 0.0, 0.5, 2.0] do
        vector = MotorPolicies.projected_vec_from_angle(angle)

        assert_in_delta MotorPolicies.projected_angle_from_vec(vector), angle, 1.0e-12
      end
    end
  end
end
