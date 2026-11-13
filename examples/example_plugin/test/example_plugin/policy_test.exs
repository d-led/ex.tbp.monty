defmodule ExamplePlugin.PolicyTest do
  @moduledoc """
  The spiral, at the boundary of the plugin: an episode starts by looking up,
  each leg is as long as the spiral says, and starting over goes back to the
  first leg.

  The ported policy's own cases live with it; what is specified here is that the
  plugin carries its state from one call to the next, which is the part wrapping
  a pure policy in a struct can get wrong.
  """

  use ExUnit.Case, async: true

  alias ExamplePlugin.Policy
  alias Monty.Frameworks.Actions.{LookUp, TurnLeft}

  test "an episode begins by looking up, by the amount the spiral was built with" do
    assert {%{actions: [%LookUp{rotation_degrees: 5.0, agent_id: "agent_id_0"}]}, _policy} =
             step(Policy.new(), 1)
  end

  test "the leg turns left once the first has had its one step" do
    policy = Policy.new()

    assert {%{actions: [%LookUp{}]}, policy} = step(policy, 1)
    assert {%{actions: [%TurnLeft{rotation_degrees: 5.0}]}, _policy} = step(policy, 1)
  end

  test "starting the next episode goes back to the first leg" do
    {_result, policy} = step(Policy.new(), 1)
    policy = Policy.reset(policy)

    assert Policy.state_dict(policy).current_action_id == 0
    assert {%{actions: [%LookUp{}]}, _policy} = step(policy, 1)
  end

  test "what it reports is where on the spiral it stopped" do
    {_result, policy} = step(Policy.new(), 2)

    assert Policy.state_dict(policy) == %{
             sensor_id: "sensor_0",
             current_action_id: 1,
             steps_per_action: 1
           }
  end

  # A policy is called once per step with everything the framework has at that
  # point; the spiral reads none of it, and this is the shape it is passed.
  defp step(policy, times) do
    Enum.reduce(1..times, {nil, policy}, fn _step, {_result, policy} ->
      Policy.call(policy, %{}, nil, %{}, nil, nil)
    end)
  end
end
