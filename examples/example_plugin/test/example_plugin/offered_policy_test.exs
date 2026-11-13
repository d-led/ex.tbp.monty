defmodule ExamplePlugin.OfferedPolicyTest do
  @moduledoc """
  The policy as a caller on another node meets it: a process that decides a step,
  hands the policy back as it now stands, and starts an episode over when asked.

  The decision is `ExamplePlugin.Policy`'s and its own cases are there. What is
  specified here is the process around it, reached the way a remote caller
  reaches it — by the name the registry answers with — because "a step is decided
  here and remembered by the caller" is a claim about this process and not about
  the spiral.

  The memory being the caller's is the part with a bug behind it: this process is
  one for the whole cluster, so a sweep of six parts would have walked one spiral
  six ways at once.
  """

  use ExUnit.Case, async: true

  alias ExamplePlugin.{LearningModule, Policy}
  alias Monty.Frameworks.Actions.{LookDown, LookUp, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  setup do
    {:ok, provider} = MontyPlugin.Registry.lookup(:motor_policy, Policy.name(), node())
    %{provider: provider.pid}
  end

  test "a step is answered by the process, from the first leg of the spiral", %{
    provider: provider
  } do
    assert {:ok, %MotorPolicyResult{actions: [%LookUp{rotation_degrees: 5.0}]}, policy} =
             step(provider)

    assert %Policy{} = policy
  end

  test "the step after it starts where the last one stopped", %{provider: provider} do
    {:ok, %MotorPolicyResult{actions: [%LookUp{}]}, policy} = step(provider)
    assert {:ok, %MotorPolicyResult{actions: [%TurnLeft{}]}, _policy} = step(provider, policy)
  end

  # The case the convention exists for: two episodes, one process. Each walks its
  # own spiral because each holds its own policy — the one two legs along is not
  # where the one that has not stepped at all begins.
  test "two episodes are two policies", %{provider: provider} do
    {:ok, %MotorPolicyResult{actions: [%LookUp{}]}, mine} = step(provider)
    {:ok, %MotorPolicyResult{actions: [%TurnLeft{}]}, mine} = step(provider, mine)

    assert {:ok, %MotorPolicyResult{actions: [%LookUp{}]}, theirs} = step(provider)

    assert {:ok, %MotorPolicyResult{actions: [%LookDown{}]}, _mine} = step(provider, mine)
    assert {:ok, %MotorPolicyResult{actions: [%TurnLeft{}]}, _theirs} = step(provider, theirs)
  end

  test "what the spiral recorded is read from the policy the caller holds", %{
    provider: provider
  } do
    {:ok, _result, policy} = step(provider)
    {:ok, _result, policy} = step(provider, policy)

    assert {:ok, %{sensor_id: "sensor_0", current_action_id: 1, steps_per_action: 1}} =
             GenServer.call(provider, {:state_dict, policy})
  end

  test "starting an episode puts the policy back at its first leg", %{provider: provider} do
    {:ok, %MotorPolicyResult{actions: [%LookUp{}]}, policy} = step(provider)

    assert {:ok, %Policy{} = fresh} = GenServer.call(provider, {:reset, policy})
    assert {:ok, %MotorPolicyResult{actions: [%LookUp{}]}, _fresh} = step(provider, fresh)
  end

  test "a plugin of another kind is not a policy, and says so" do
    {:ok, provider} = MontyPlugin.Registry.lookup(:learning_module, LearningModule.name(), node())

    assert {:error, why} =
             GenServer.call(provider.pid, {:call, nil, %{}, nil, %{}, nil, [nil]})

    assert why =~ "is not a motor policy and decides nothing"
  end

  defp step(provider), do: step(provider, new(provider))

  # One step, with the policy the caller holds: the only copy, since the process
  # builds one at `{:new, []}` and keeps none. The goal is the one the framework
  # hands a policy per step; the spiral reads none of it, and its shape is what
  # crosses the cluster.
  defp step(provider, policy),
    do: GenServer.call(provider, {:call, policy, %{}, nil, %{}, nil, [nil]})

  defp new(provider) do
    {:ok, policy} = GenServer.call(provider, {:new, []})
    policy
  end
end
