defmodule Monty.Simulators.Port.ProtocolTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{MoveForward, TurnLeft}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Port.Protocol

  describe "asking for a step" do
    test "the actions travel in Monty's own action shape" do
      request =
        Protocol.request(7, {:step, [%MoveForward{agent_id: "agent_id_0", distance: 0.004}]})

      assert request == %{
               "id" => 7,
               "command" => "step",
               "actions" => [
                 %{"action" => "move_forward", "agent_id" => "agent_id_0", "distance" => 0.004}
               ]
             }
    end

    test "and every action of a step is there, in order" do
      actions = [
        %MoveForward{agent_id: "agent_id_0", distance: 0.01},
        %TurnLeft{agent_id: "agent_id_0", rotation_degrees: 5.0}
      ]

      assert %{"actions" => [%{"action" => "move_forward"}, %{"action" => "turn_left"}]} =
               Protocol.request(1, {:step, actions})
    end
  end

  describe "asking for a fresh episode" do
    test "names the sensors the simulator should report" do
      assert Protocol.request(3, {:reset, ["patch", "view_finder"]}) == %{
               "id" => 3,
               "command" => "reset",
               "sensor_ids" => ["patch", "view_finder"]
             }
    end
  end

  describe "reading a reply" do
    test "a step answer is the two payloads Monty steps with" do
      body =
        Jason.encode!(%{
          "id" => 2,
          "observations" => %{"agent_id_0" => %{}},
          "proprioceptive_state" => %{"agent_id_0" => %{}}
        })

      assert Protocol.reply(body, 2) ==
               {:ok, %{"agent_id_0" => %{}}, %{"agent_id_0" => %{}}}
    end

    test "a reset is acknowledged rather than answered" do
      assert Protocol.reply(~s({"id": 2, "ok": true}), 2) == {:ok, %{}, %{}}
    end

    test "the simulator's own error is carried, not dressed up as a step" do
      assert Protocol.reply(~s({"id": 2, "error": "no such sensor"}), 2) ==
               {:error, {:simulator_error, "no such sensor"}}
    end

    test "a reply to a request that timed out is not taken for this one" do
      assert Protocol.reply(~s({"id": 1, "ok": true}), 2) ==
               {:error, {:wrong_reply, %{expected: 2, got: 1}}}
    end

    test "and a reply that makes no sense to this contract is reported" do
      assert Protocol.reply(~s({"id": 2, "surprise": true}), 2) ==
               {:error, {:unexpected_reply, %{"id" => 2, "surprise" => true}}}

      assert {:error, {:not_json, _reason}} = Protocol.reply("not json", 2)
    end
  end

  describe "reading proprioception" do
    # Monty writes its quaternions `wxyz`; the port's own are `xyzw`. A quarter
    # turn about z is the smallest case where reading one as the other is
    # visible: (w, x, y, z) = (cos 45, 0, 0, sin 45).
    @quarter_turn [0.7071067811865476, 0.0, 0.0, 0.7071067811865476]

    test "is the agent's place and turn, in the port's own state" do
      proprio =
        Protocol.proprioceptive_state(%{
          "agent_id_0" => %{
            "position" => [0.0, 1.5, 0.2],
            "rotation" => @quarter_turn,
            "sensors" => %{
              "patch" => %{"position" => [0.0, 0.0, 0.1], "rotation" => @quarter_turn}
            }
          }
        })

      assert %{"agent_id_0" => %AgentState{} = agent} = proprio
      assert agent.position == [0.0, 1.5, 0.2]

      assert %{"patch" => %SensorState{} = patch} = agent.sensors
      assert patch.position == [0.0, 0.0, 0.1]

      assert Rotation.to_xyzw(agent.rotation) == [
               0.0,
               0.0,
               0.7071067811865476,
               0.7071067811865476
             ]
    end

    test "an agent without a place or a turn is a simulator that has drifted" do
      assert_raise ArgumentError, ~r/position and a rotation/, fn ->
        Protocol.proprioceptive_state(%{"agent_id_0" => %{"sensors" => %{}}})
      end
    end
  end
end
