defmodule FlyversePlugin.PolicyTest do
  # Not async: the pack a node steps is application configuration, and one test
  # here is about a node with none.
  use ExUnit.Case, async: false

  alias FlyversePlugin.{Demonstrator, Pack, Policy}

  alias Monty.Frameworks.Actions.{MoveForward, TurnLeft, TurnRight}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "flyverse_policy_#{System.unique_integer([:positive])}")

    {:ok, _written} = Pack.write(directory, Demonstrator.spec())

    previous = Application.get_env(:flyverse_plugin, :pack)
    Application.put_env(:flyverse_plugin, :pack, directory)

    on_exit(fn ->
      Application.put_env(:flyverse_plugin, :pack, previous)
      File.rm_rf!(directory)
    end)

    {:ok, state: Policy.initial_state()}
  end

  test "a nearer left side turns the sensor left", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    assert [%TurnLeft{agent_id: "agent_id_0", rotation_degrees: 5.0}] = result.actions
  end

  test "a nearer right side turns it right", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[100.0, 100.0, 0.02, 0.02]])

    assert [%TurnRight{rotation_degrees: 5.0}] = result.actions
  end

  test "a view with nothing in reach walks straight", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.0, 0.0, 0.0, 0.0]])

    assert [%MoveForward{distance: 0.004}] = result.actions
  end

  test "the telemetry is the spikes the decision was made of", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    assert result.telemetry.left_spikes > 0
    assert result.telemetry.right_spikes == 0
    assert result.telemetry.wish > 0.0
    assert result.telemetry.left_hz == 200.0
  end

  test "a reset starts the same episode, and so decides the same way", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)
    depth = [[0.02, 0.02, 100.0, 100.0]]

    {first, policy, state} = step(policy, state, depth)
    {:ok, policy, state} = Policy.reset(policy, state)
    {again, _policy, _state} = step(policy, state, depth)

    assert again.actions == first.actions
    assert again.telemetry == first.telemetry
  end

  test "what the policy recorded is the network's own numbers", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)
    {_result, policy, state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    recorded = Policy.state_dict(policy, state)

    assert recorded.ticks_per_step == Demonstrator.spec().plan["ticks"]
    assert [left, 0] = recorded.last_counts
    assert left > 0
    assert recorded.wish > 0.0
  end

  test "a plan that does not name two sides is refused, and the sentence says why", %{
    state: state
  } do
    directory =
      Path.join(System.tmp_dir!(), "flyverse_one_sided_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, _written} =
      Pack.write(directory, %{
        neuron_ids: [1, 2],
        edges: [{0, 1, 200}],
        plan: %{"drives" => [[0]], "readouts" => [[1]], "ticks" => 200, "seed" => 7}
      })

    Application.put_env(:flyverse_plugin, :pack, directory)

    assert {:error, sentence} = Policy.new([], state)
    assert sentence =~ "names 1 drive group(s)"
  end

  test "a node with no pack named says what to do", %{state: state} do
    Application.delete_env(:flyverse_plugin, :pack)
    System.delete_env("FLYVERSE_PACK")

    assert {:error, sentence} = Policy.new([], state)
    assert sentence =~ "mix flyverse_plugin.pack"
  end

  defp step(policy, state, depth) do
    {:ok, result, policy, state} =
      Policy.call(policy, {nil, observations(depth), nil, nil, nil}, state)

    {result, policy, state}
  end

  # Two sensors, because a config usually gives an agent both: the policy reads
  # the wide one, and the test says so by giving both the same image.
  defp observations(depth) do
    %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => depth},
        "patch" => %{"depth" => depth}
      }
    }
  end
end
