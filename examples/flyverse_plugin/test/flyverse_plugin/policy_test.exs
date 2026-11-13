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
  # The step walks whatever the network says: a fly's locomotion is walking with
  # turns in it, so a turn carries the crawl step and can never leave it standing.
  test "a nearer left side turns the sensor left while it walks", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.agent_id == "agent_id_0"
    assert walked.rotation_degrees < 0.0, "left, because the left half is nearer"
    assert walked.forward_distance == 0.004, "and it walks while it turns"
  end

  test "a nearer right side turns it right while it walks", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[100.0, 100.0, 0.02, 0.02]])

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.rotation_degrees > 0.0, "right, because the right half is nearer"
    assert walked.forward_distance == 0.004
  end

  # A fly with nothing in view is not aimed at anything, and a network balanced
  # between two halves would walk one straight line for ever. The wander leans it
  # one way for a while and then the other, so the fly sweeps.
  test "a fly with nothing in view leans one way, then the other", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {first, policy, state} = step(policy, state, [[0.0, 0.0, 0.0, 0.0]])

    state =
      Enum.reduce(1..40, state, fn _step, state ->
        {_result, _policy, state} = step(policy, state, [[0.0, 0.0, 0.0, 0.0]])
        state
      end)

    {turned, _policy, _state} = step(policy, state, [[0.0, 0.0, 0.0, 0.0]])

    assert [%OrientHorizontal{rotation_degrees: first_way}] = first.actions
    assert [%OrientHorizontal{rotation_degrees: other_way}] = turned.actions

    assert first_way * other_way <= 0.0,
           "the lean turns over: #{first_way} then #{other_way}"
  end

  # The loom: something nearer than the standoff is something the step would
  # walk into. The step stops travelling and the turn takes the whole bend, so
  # the fly swings away from what it is touching rather than pressing through it.
  test "against something, the step stops travelling and the bend is taken", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} =
      step(policy, state, observations([[0.02, 0.02, 100.0, 100.0]]), touching(0.01))

    assert [%OrientHorizontal{} = swung] = result.actions
    assert swung.forward_distance == 0.0, "no step into what it is touching"
    assert swung.rotation_degrees < 0.0, "and the turn is the way it was already leaning"
  end

  # An empty view still walks: the tonic drive is what makes the network say
  # "no preference" as a measurement rather than as silence.
  test "a view with nothing in reach walks, and barely bends", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.0, 0.0, 0.0, 0.0]])

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.forward_distance == 0.004
    assert abs(walked.rotation_degrees) <= 5.0, "at most a base turn's worth"
  end

  test "the telemetry is the spikes the decision was made of", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    assert result.telemetry.left_spikes > 0
    assert result.telemetry.right_spikes == 0
    assert result.telemetry.wish > 0.0

    assert result.telemetry.left_hz >= 280.0,
           "the tonic 80 Hz plus 200 Hz of nearness, leaned by the wander"

    assert result.telemetry.right_hz <= 81.0, "and the other half carries the tonic alone"
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
    # A hop of the stride, not the whole gap: Monty can walk the whole gap
    # because its world holds one object, and a scene with a table and a room in
    # it cannot be trusted to have measured the object rather than the wall.
    test "hops towards what the view finder sees, five centimetres at a time", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.2, 0.05), away())

      assert [%MoveForward{agent_id: "agent_id_0", distance: distance}] = result.actions
      assert_in_delta distance, 0.05, 1.0e-9, "the stride"

      refute result.motor_only_step,
             "a search is fed too: the step it finds the object is the one with a view"
    end

    test "closes a gap shorter than the stride by all of it", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.06, 0.05), away())

      assert [%MoveForward{distance: distance}] = result.actions
      assert_in_delta distance, 0.035, 1.0e-9, "the gap, minus the standoff"
    end

    test "stops at the standoff when it is already there", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.02, 0.05), away())

      assert [%MoveForward{distance: 0.0}] = result.actions
    end

    # The centre pixel is not always the thing to walk at: in a room the middle
    # of the picture is often the wall across the table, and a step of that
    # length lands past everything — which is where a run of this policy spent a
    # thousand steps. The step is the nearer of the centre and the nearest thing
    # in view.
    test "lands on the nearest thing, not on whatever the centre pixel sees", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      # Centre pixel 0.9 m (the wall), something 0.2 m in the corner of the view.
      wall_ahead = [[0.2, 0.9], [0.9, 0.9]]

      {result, _policy, _state} = step(policy, state, scene(wall_ahead, 0.05), away())

      assert [%MoveForward{distance: distance}] = result.actions
      assert_in_delta distance, 0.05, 1.0e-9, "towards the 0.2 m thing, and no further than a hop"
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

      refute result.motor_only_step
    end

    # A tenth of the patch on the object is the line Monty draws, and past it the
    # network is the policy again.
    test "hands back to the network once the patch is on the object", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.2, 0.05), on_object(0.5))

      assert [%OrientHorizontal{forward_distance: four_millimetres}] = result.actions
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
    view = if is_list(view_depth), do: view_depth, else: [[view_depth]]

    %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => view},
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

  # A percept that says how far the patch is standing off what it is on.
  defp touching(depth) do
    %Monty.Cmp.Message{
      sender_id: "patch",
      sender_type: :sm,
      morphological_features: %{
        "mean_depth" => List.duplicate(depth, 16),
        "object_coverage" => 0.5
      }
    }
  end

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
