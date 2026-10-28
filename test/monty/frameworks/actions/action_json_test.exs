defmodule Monty.Frameworks.Actions.ActionJSONTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{
    ActionJSONDecoder,
    ActionJSONEncoder,
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    SetAgentPitch,
    SetAgentPose,
    SetSensorPitch,
    SetSensorPose,
    SetSensorRotation,
    SetYaw,
    TurnLeft,
    TurnRight
  }

  @agent "agent_id_0"
  @quaternion {0.9238795325112867, 0.0, 0.0, 0.3826834323650898}

  # One of every action Monty defines, because the pair of mappings — the map an
  # action becomes and the action a map becomes — is only right if it is right
  # for all of them.
  @actions [
    %LookDown{agent_id: @agent, rotation_degrees: 30.0},
    %LookDown{agent_id: @agent, rotation_degrees: 30.0, constraint_degrees: 45.0},
    %LookUp{agent_id: @agent, rotation_degrees: 30.0},
    %MoveForward{agent_id: @agent, distance: 0.01},
    %MoveTangentially{agent_id: @agent, distance: 0.005, direction: [0.0, 1.0, 0.0]},
    %OrientHorizontal{
      agent_id: @agent,
      rotation_degrees: 90.0,
      left_distance: 0.02,
      forward_distance: 0.03
    },
    %OrientVertical{
      agent_id: @agent,
      rotation_degrees: 45.0,
      down_distance: 0.01,
      forward_distance: 0.02
    },
    %SetAgentPitch{agent_id: @agent, pitch_degrees: -15.0},
    %SetAgentPose{agent_id: @agent, location: [1.0, 2.0, 3.0], rotation_quat: @quaternion},
    %SetSensorPitch{agent_id: @agent, pitch_degrees: 10.0},
    %SetSensorPose{agent_id: @agent, location: [0.5, 0.5, 0.5], rotation_quat: @quaternion},
    %SetSensorRotation{agent_id: @agent, rotation_quat: @quaternion},
    %SetYaw{agent_id: @agent, rotation_degrees: 180.0},
    %TurnLeft{agent_id: @agent, rotation_degrees: 5.0},
    %TurnRight{agent_id: @agent, rotation_degrees: 5.0}
  ]

  describe "writing and reading an action" do
    test "every action survives the round trip unchanged" do
      for action <- @actions do
        assert {:ok, ^action} =
                 action |> ActionJSONEncoder.encode() |> ActionJSONDecoder.decode()
      end
    end

    test "the map names the action under `action`, and then its parameters" do
      action = %SetAgentPose{
        agent_id: @agent,
        location: [0.1, 0.2, 0.3],
        rotation_quat: @quaternion
      }

      assert ActionJSONEncoder.encode(action) == %{
               "action" => "set_agent_pose",
               "agent_id" => @agent,
               "location" => [0.1, 0.2, 0.3],
               "rotation_quat" => @quaternion
             }
    end

    test "an action names itself in snake case, as Monty derives it from the class" do
      for action <- @actions do
        module = action.__struct__
        derived = module |> Module.split() |> List.last() |> Macro.underscore()

        assert module.name() == derived
      end
    end

    test "a quaternion written as a JSON list comes back as the tuple the struct holds" do
      object = %{
        "action" => "set_sensor_rotation",
        "agent_id" => @agent,
        "rotation_quat" => [0.0, 1.0, 0.0, 0.0]
      }

      assert {:ok, %SetSensorRotation{rotation_quat: quaternion}} =
               ActionJSONDecoder.decode(object)

      assert quaternion == {0.0, 1.0, 0.0, 0.0}
    end
  end

  describe "reading a map that is not an action" do
    test "names the action it does not know" do
      assert ActionJSONDecoder.decode(%{"action" => "hop"}) == {:error, {:unknown_action, "hop"}}
    end

    test "says the map has no action in it" do
      assert ActionJSONDecoder.decode(%{"agent_id" => @agent}) ==
               {:error, {:missing_action, %{"agent_id" => @agent}}}
    end

    test "names the parameter an action leaves out rather than guessing it" do
      assert ActionJSONDecoder.decode(%{"action" => "move_forward", "agent_id" => @agent}) ==
               {:error, {:missing_parameter, "distance"}}
    end
  end
end
