defmodule ExamplePlugin.OfferedPolicyTest do
  @moduledoc """
  The policy as a caller on another node meets it: a process that answers a step,
  remembers where it stopped, and starts an episode over when asked.

  The decision is `ExamplePlugin.Policy`'s and its own cases are there. What is
  specified here is the process around it, reached the way a remote caller
  reaches it — by the name the registry answers with — because "the state lives
  on the plugin's node" is a claim about this process and not about the spiral.
  """

  use ExUnit.Case, async: true

  alias ExamplePlugin.{LearningModule, Policy}
  alias Monty.Frameworks.Actions.{LookUp, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  setup do
    {:ok, provider} = MontyPlugin.Registry.lookup(:motor_policy, Policy.name(), node())
    GenServer.call(provider.pid, :reset)

    %{policy: provider.pid}
  end

  test "a step is answered by the process, from the first leg of the spiral", %{
    policy: policy
  } do
    assert {:ok, %MotorPolicyResult{actions: [%LookUp{rotation_degrees: 5.0}]}} = step(policy)
  end

  test "the step after it starts where the last one stopped", %{policy: policy} do
    assert {:ok, %MotorPolicyResult{actions: [%LookUp{}]}} = step(policy)
    assert {:ok, %MotorPolicyResult{actions: [%TurnLeft{}]}} = step(policy)
  end

  test "what the spiral recorded is read from the process that holds it", %{policy: policy} do
    {:ok, _result} = step(policy)
    {:ok, _result} = step(policy)

    assert GenServer.call(policy, :state_dict) == %{
             sensor_id: "sensor_0",
             current_action_id: 1,
             steps_per_action: 1
           }
  end

  test "starting an episode puts the policy back at its first leg", %{policy: policy} do
    {:ok, %MotorPolicyResult{actions: [%LookUp{}]}} = step(policy)

    assert GenServer.call(policy, :reset) == :ok
    assert {:ok, %MotorPolicyResult{actions: [%LookUp{}]}} = step(policy)
  end

  test "a plugin of another kind is not a policy, and says so" do
    {:ok, provider} = MontyPlugin.Registry.lookup(:learning_module, LearningModule.name(), node())

    assert {:error, why} = GenServer.call(provider.pid, {:call, %{}, nil, %{}, nil, [nil]})

    assert why =~ "is not a motor policy and decides nothing"
  end

  # The one goal the framework hands a policy per step; the spiral reads none of
  # it, and the shape is what crosses the cluster.
  defp step(policy), do: GenServer.call(policy, {:call, %{}, nil, %{}, nil, [nil]})
end
