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
  # walk into. So the step does not travel forward — it slides along that
  # surface, the way Monty's surface policy moves tangentially between touches,
  # and the bend is taken whole so the fly swings along what it is touching
  # rather than pressing through it. A fly that pivots on the spot reads the same
  # flat patch for ever, which is what a run of fifteen hundred steps showed.
  test "against something, the step slides along it instead of pivoting", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} =
      step(policy, state, observations([[0.02, 0.02, 100.0, 100.0]]), touching(0.01))

    assert [%OrientHorizontal{} = slid] = result.actions
    assert_in_delta slid.left_distance, 0.004, 1.0e-9, "the step goes across it, leftwards"
    assert_in_delta slid.forward_distance, -0.015, 1.0e-9, "and back to the standoff"
    assert slid.rotation_degrees < 0.0, "the turn is the way it was already leaning"
  end

  # The standoff is held, not a constant step: a sensor at 20 mm with 25 mm
  # wanted backs away by the 5 mm it is too close, and one further off than the
  # standoff crawls at the four millimetres a step has always been.
  test "a patch at the standoff crawls, and one nearer it backs away", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {at, _policy, _state} =
      step(policy, state, observations([[0.02, 0.02, 100.0, 100.0]]), touching(0.025))

    {:ok, policy, state} = Policy.reset(policy, state)

    {nearer, _policy, _state} =
      step(policy, state, observations([[0.02, 0.02, 100.0, 100.0]]), touching(0.02))

    assert [%OrientHorizontal{forward_distance: crawl}] = at.actions
    assert_in_delta crawl, 0.004, 1.0e-9

    assert [%OrientHorizontal{forward_distance: back}] = nearer.actions
    assert_in_delta back, -0.005, 1.0e-9
  end

  # Which way across the surface is the network's decision, not the policy's:
  # the side its readouts preferred is the side the step goes.
  test "the slide goes the way the network leaned", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {left, policy, state} =
      step(policy, state, observations([[0.02, 0.02, 100.0, 100.0]]), touching(0.01))

    {:ok, policy, state} = Policy.reset(policy, state)

    {right, _policy, _state} =
      step(policy, state, observations([[100.0, 100.0, 0.02, 0.02]]), touching(0.01))

    assert [%OrientHorizontal{left_distance: one_way}] = left.actions
    assert [%OrientHorizontal{left_distance: other_way}] = right.actions

    assert one_way * other_way < 0.0,
           "a lean one way slides one way: #{one_way} then #{other_way}"
  end

  # The animal's steering is asymmetric: its two descending-neuron populations
  # are not identical instruments, and the same imbalance of spikes turns it
  # further one way than the other. A mirrored scene is the same imbalance, so a
  # mirrored scene is where the asymmetry shows.
  test "the same imbalance bends it further to the left than to the right", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {left, policy, state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])
    {:ok, policy, state} = Policy.reset(policy, state)
    {right, _policy, _state} = step(policy, state, [[100.0, 100.0, 0.02, 0.02]])

    assert [%OrientHorizontal{rotation_degrees: leftwards}] = left.actions
    assert [%OrientHorizontal{rotation_degrees: rightwards}] = right.actions

    assert abs(leftwards) > abs(rightwards),
           "left #{leftwards} against right #{rightwards}"
  end

  # LC4's reflex, which the standoff rule cannot see: the standoff says where the
  # patch is, and a thing that is *closing* is one the view remembers. Something
  # already in view that suddenly fills half again as much of it is not walked
  # at — the step goes the other way, by no more than a step, because a loom is
  # a reason to stop closing rather than to fly across the room.
  test "something that looms is stepped away from, while a slow approach is not", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    # The patch is at the standoff throughout, so the standoff rule alone would
    # crawl at every one of these steps.
    {_first, policy, state} =
      step(policy, state, observations([[0.2, 0.2, 100.0, 100.0]]), touching(0.025))

    {closer, policy, state} =
      step(policy, state, observations([[0.15, 0.15, 100.0, 100.0]]), touching(0.025))

    {closest, _policy, _state} =
      step(policy, state, observations([[0.08, 0.08, 100.0, 100.0]]), touching(0.025))

    assert [%OrientHorizontal{forward_distance: 0.004}] = closer.actions,
           "a third nearer is an approach, not a loom"

    assert [%OrientHorizontal{forward_distance: retreat}] = closest.actions
    assert retreat < 0.0, "half again as large is a loom: stepped away from"
    assert abs(retreat) <= 0.05, "and no further than a step"
  end

  # The slide is what the fly does *at* the surface. While there is room to walk
  # there is nothing to slide along, and the step travels forward as it always
  # did.
  test "in open view the step walks, and does not slide", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} =
      step(policy, state, observations([[0.02, 0.02, 100.0, 100.0]]), touching(0.4))

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.forward_distance == 0.004
    assert walked.left_distance == 0.0
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

      assert [%OrientHorizontal{agent_id: "agent_id_0"} = hopped] = result.actions
      assert_in_delta hopped.forward_distance, 0.05, 1.0e-9, "the stride"

      refute result.motor_only_step,
             "a search is fed too: the step it finds the object is the one with a view"
    end

    # Monty's `MoveForward` walks straight because Monty's world centres the
    # object for it. A fly does not get that: one run had the mug centred at step
    # 5 and a sliver at the edge of the picture by step 100, and the patch never
    # landed on it again. So the step turns towards the side the view finder
    # sees something on, and the turn is the same sign as the network's.
    test "turns towards what the view finder sees while it closes the gap", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} =
        step(policy, state, scene([[0.2, 0.9], [0.9, 0.9]], 0.05), away())

      assert [%OrientHorizontal{} = turned] = result.actions
      assert turned.rotation_degrees < 0.0, "left, because what is in view is on the left"
      assert turned.left_distance == 0.0
    end

    test "walks straight at it when the picture is already centred", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.2, 0.05), away())

      assert [%OrientHorizontal{rotation_degrees: turn}] = result.actions
      assert_in_delta turn, 0.0, 1.0e-9
    end

    test "closes a gap shorter than the stride by all of it", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.06, 0.05), away())

      assert [%OrientHorizontal{forward_distance: distance}] = result.actions
      assert_in_delta distance, 0.035, 1.0e-9, "the gap, minus the standoff"
    end

    # A sensor nearer than the standoff has no gap left to close, and a step of
    # nought is a fly that never moves again: frames from step 480 to step 1331
    # of one run were identical to the byte. So the step backs off to the
    # standoff, where the patch can read the object and the network can steer.
    test "backs off when it is nearer than the standoff", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      # 20 mm from the thing in front, standing where 25 mm is wanted.
      {result, _policy, _state} = step(policy, state, scene(0.02, 0.05), away())

      assert [%OrientHorizontal{forward_distance: distance}] = result.actions
      assert_in_delta distance, -0.005, 1.0e-9, "back to the standoff, no further"
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

      assert [%OrientHorizontal{forward_distance: distance}] = result.actions
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
    # Two columns, so the two halves the drive reads are the two halves this
    # scene means: a one-column image is a picture with nothing on the right of
    # it, and the centring reflex would turn away from it every step.
    view = if is_list(view_depth), do: view_depth, else: [[view_depth, view_depth]]

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
