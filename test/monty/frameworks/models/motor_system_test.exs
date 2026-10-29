defmodule Monty.Frameworks.Models.MotorSystemTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Goal
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelector
  alias Monty.Frameworks.Models.MotorSystem

  # Actions are whatever a policy says they are; the vocabulary that an
  # environment understands is `Monty.Frameworks.Actions`, which is the next
  # file of the port. A map is what the runtime already passes around.
  @look_down %{action: "look_down", agent_id: "agent_id_0", rotation_degrees: 30.0}
  @move_forward %{action: "move_forward", agent_id: "agent_id_0", distance: 0.01}

  @proprioceptive_state %{
    "agent_id_0" => %{
      sensors: %{},
      position: [0.0, 0.0, 0.0],
      rotation: Monty.Geometry.Rotation.identity()
    }
  }

  defp motor_system(result) do
    MotorSystem.new(
      SinglePolicySelector.new(policy: Monty.Test.RecordingPolicy.new(result_options(result)))
    )
  end

  defp result_options(%MotorPolicyResult{} = result) do
    [
      actions: result.actions,
      status: result.status,
      motor_only_step: result.motor_only_step,
      telemetry: result.telemetry
    ]
  end

  defp step(motor_system) do
    MotorSystem.call(motor_system, Context.new(0), nil, @proprioceptive_state, nil, [])
  end

  describe "asking for this step's actions" do
    test "answers what the policy chose" do
      assert {[@move_forward], _motor_system} =
               step(motor_system(%MotorPolicyResult{actions: [@move_forward]}))
    end

    test "answers nothing when the policy decided to stay put" do
      assert {[], _motor_system} = step(motor_system(MotorPolicyResult.new()))
    end
  end

  describe "what it remembers" do
    test "keeps the actions with the state they were chosen in" do
      {_actions, motor_system} = step(motor_system(%MotorPolicyResult{actions: [@look_down]}))

      assert MotorSystem.action_sequence(motor_system) == [{[@look_down], @proprioceptive_state}]
    end

    test "keeps every step, in the order they happened" do
      motor_system = motor_system(%MotorPolicyResult{actions: [@look_down]})

      {_actions, motor_system} = step(motor_system)
      {_actions, motor_system} = step(motor_system)

      assert [{[@look_down], _first_state}, {[@look_down], _second_state}] =
               MotorSystem.action_sequence(motor_system)
    end

    test "starts the next episode with nothing remembered" do
      {_actions, motor_system} = step(motor_system(%MotorPolicyResult{actions: [@look_down]}))
      motor_system = MotorSystem.reset(motor_system)

      assert MotorSystem.action_sequence(motor_system) == []

      assert MotorSystem.state_dict(motor_system) == %{
               policy: %{asked_about: []},
               selected_goals: []
             }
    end
  end

  describe "whether learning modules should sit the step out" do
    test "says so when the policy was only moving" do
      {_actions, motor_system} =
        step(motor_system(%MotorPolicyResult{actions: [@look_down], motor_only_step: true}))

      assert MotorSystem.motor_only_step(motor_system)
    end

    test "does not, by default" do
      {_actions, motor_system} = step(motor_system(%MotorPolicyResult{actions: [@look_down]}))

      refute MotorSystem.motor_only_step(motor_system)
    end

    test "forgets it when the next episode starts" do
      {_actions, motor_system} =
        step(motor_system(%MotorPolicyResult{actions: [@look_down], motor_only_step: true}))

      refute motor_system |> MotorSystem.reset() |> MotorSystem.motor_only_step()
    end
  end

  describe "what it reports" do
    test "the goals its selector chose" do
      believed = %Goal{sender_id: "LM_0", sender_type: :gsg, confidence: 0.8}

      MotorSystem.new(SinglePolicySelector.new(policy: Monty.Test.RecordingPolicy.new()))
      |> MotorSystem.call(Context.new(0), nil, @proprioceptive_state, nil, [believed])
      |> then(fn {_actions, motor_system} -> MotorSystem.state_dict(motor_system) end)
      |> then(&assert(&1 == %{policy: %{asked_about: [believed]}, selected_goals: [believed]}))
    end

    test "the surface policy's account of why it chose them, step by step" do
      motor_system =
        motor_system(%MotorPolicyResult{
          actions: [@look_down],
          telemetry: %{pc_heading: :max, avoidance_heading: false, z_defined_pc: nil}
        })

      {_actions, motor_system} = step(motor_system)
      {_actions, motor_system} = step(motor_system)

      assert motor_system.telemetry.pc_heading == [:max, :max]
      assert motor_system.telemetry.avoidance_heading == [false, false]
    end

    test "nothing extra from a step with no telemetry" do
      {_actions, motor_system} = step(motor_system(%MotorPolicyResult{actions: [@look_down]}))

      assert motor_system.telemetry.pc_heading == []
      assert motor_system.telemetry.avoidance_heading == []
    end
  end
end
