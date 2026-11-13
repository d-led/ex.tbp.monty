defmodule FlyversePlugin.PolicyTest do
  # Not async: the pack a node steps is application configuration, and one test
  # here is about a node with none.
  use ExUnit.Case, async: false

  alias FlyversePlugin.{Demonstrator, Pack, Policy}

  alias Monty.Frameworks.Actions.{MoveForward, OrientHorizontal}

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

  # A surf agent turns by yawing, which is `OrientHorizontal`'s
  # `rotation_degrees`, and the world yaws by the negative of it: a wish to the
  # left is therefore a negative angle here.
  test "a nearer left side turns the sensor left", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    assert [%OrientHorizontal{agent_id: "agent_id_0", rotation_degrees: -5.0}] = result.actions
  end

  test "a nearer right side turns it right", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[100.0, 100.0, 0.02, 0.02]])

    assert [%OrientHorizontal{agent_id: "agent_id_0", rotation_degrees: 5.0}] = result.actions
  end

  test "a turn keeps the agent where it stands", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    assert [%OrientHorizontal{left_distance: 0.0, forward_distance: 0.0}] = result.actions
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

  # Monty's own opening (`SurfacePolicy._touch_object`), copied because the
  # network cannot do it: a patch that is not on the object has no left-versus-
  # right difference to steer by, so the beginning of the policy is Monty's.
  describe "before the patch is on the object" do
    test "one step takes the sensor to what the view finder sees", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.2, 0.05), away())

      assert [%MoveForward{agent_id: "agent_id_0", distance: distance}] = result.actions
      assert_in_delta distance, 0.175, 1.0e-9, "the gap, minus the standoff"
      assert result.motor_only_step, "nothing on it to learn from yet"
    end

    # The gap is walked whole, which is the difference between one step and the
    # fifty a crawl needs.
    test "walks the whole gap, however wide it is", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.6, 0.05), away())

      assert [%MoveForward{distance: distance}] = result.actions
      assert_in_delta distance, 0.575, 1.0e-9
    end

    test "steps round a search circle when nothing is in sight", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(200.0, 0.05), away())

      assert [%OrientHorizontal{} = searched] = result.actions
      assert searched.rotation_degrees == 30.0

      # Thirty degrees round a circle four standoffs wide: the sideways move is
      # its tangent, the forward one the exsecant that keeps the agent on the
      # circle.
      assert_in_delta searched.left_distance, :math.tan(radians(30.0)) * 0.1, 1.0e-9

      assert_in_delta searched.forward_distance,
                      0.1 * (1.0 - :math.cos(radians(30.0))) / :math.cos(radians(30.0)),
                      1.0e-9

      assert result.motor_only_step
    end

    # A tenth of the patch on the object is the line Monty draws, and past it the
    # network is the policy again.
    test "hands back to the network once the patch is on the object", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.2, 0.05), on_object(0.5))

      assert [%MoveForward{distance: four_millimetres}] = result.actions
      assert_in_delta four_millimetres, 0.004, 1.0e-9
      refute result.motor_only_step
    end

    defp radians(degrees), do: degrees * :math.pi() / 180.0
  end

  defp step(policy, state, depth) do
    step(policy, state, observations(depth), nil)
  end

  defp step(policy, state, observations, percept) do
    {:ok, result, policy, state} =
      Policy.call(policy, {nil, observations, nil, percept, nil}, state)

    {result, policy, state}
  end

  # A perspective on the world: what the wide view sees and what the patch is on.
  defp scene(view_depth, patch_depth) do
    %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[view_depth]]},
        "patch" => %{"depth" => [[patch_depth]]}
      }
    }
  end

  defp away,
    do: %Monty.Cmp.Message{
      sender_id: "patch",
      sender_type: :sm,
      morphological_features: %{"object_coverage" => 0.0}
    }

  defp on_object(coverage) do
    %Monty.Cmp.Message{
      sender_id: "patch",
      sender_type: :sm,
      morphological_features: %{"object_coverage" => coverage}
    }
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
