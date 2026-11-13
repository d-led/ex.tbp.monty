defmodule FlyversePlugin.PolicyTest do
  # Not async: the pack a node steps is application configuration, and one test
  # here is about a node with none.
  use ExUnit.Case, async: false

  alias FlyversePlugin.{Demonstrator, Pack, Policy}

  alias Monty.Frameworks.Actions.OrientHorizontal

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

  # A surf agent walks by `OrientHorizontal`: `left_distance` is the slide and the
  # world yaws by `-rotation_degrees`, so a left turn is a negative angle and a
  # positive leftward slide. Every walk bends by the policy's base turn, so the
  # two direction cases are stated against it: `-5.0` is the spiral a silent
  # network walks (the next test pins it).
  test "a nearer left side bends the walk left, past the base turn", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.005, 0.005, 100.0, 100.0]])

    assert [%OrientHorizontal{agent_id: "agent_id_0"} = walked] = result.actions
    assert walked.rotation_degrees < -5.0, "left of where a silent network walks"
    assert walked.left_distance > 0.0, "with a slide to match"
  end

  test "a nearer right side bends it right, back from the base turn", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[100.0, 100.0, 0.005, 0.005]])

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.rotation_degrees > -5.0
    assert walked.left_distance < 0.0
  end

  test "a silent view still crawls, on the policy's own spiral", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.0, 0.0, 0.0, 0.0]])

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.rotation_degrees == -5.0, "the base turn, and no more"
    assert walked.left_distance > 0.0
  end

  test "every step travels, and keeps the sensor at its standoff", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.005, 0.005, 100.0, 100.0]])

    assert [walked] = result.actions
    assert walked.forward_distance > 0.0, "pressed back onto the surface"
  end

  # The same view, seen after the sides swapped, is a harder turn than the same
  # view seen fresh: a fly caught between two sides snaps across rather than
  # easing through the middle.
  test "a swap of sides snaps the walk further than the view alone would", %{state: state} do
    near_left = [[0.005, 0.005, 100.0, 100.0]]
    near_right = [[100.0, 100.0, 0.005, 0.005]]

    {:ok, snapped, state} = Policy.new([], state)
    {_first, snapped, state} = step(snapped, state, near_left)
    {after_swap, _policy, _state} = step(snapped, state, near_right)

    {:ok, fresh, state} = Policy.new([], state)
    {seen_fresh, _policy, _state} = step(fresh, state, near_right)

    [%OrientHorizontal{rotation_degrees: after_swap_angle}] = after_swap.actions
    [%OrientHorizontal{rotation_degrees: fresh_angle}] = seen_fresh.actions

    assert abs(after_swap_angle) > abs(fresh_angle)
  end

  test "a surface filling the view is walked faster than one far away", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {close, _policy, _state} = step(policy, state, [[0.005, 0.005, 100.0, 100.0]])
    {far, _policy, _state} = step(policy, state, [[0.5, 0.5, 100.0, 100.0]])

    assert close.telemetry.walk_speed > far.telemetry.walk_speed
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
