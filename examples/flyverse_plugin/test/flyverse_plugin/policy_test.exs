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
    assert walked.forward_distance == 0.01, "and it walks while it turns, by the bout's stride"
  end

  test "a nearer right side turns it right while it walks", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[100.0, 100.0, 0.02, 0.02]])

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.rotation_degrees > 0.0, "right, because the right half is nearer"
    assert walked.forward_distance == 0.01
  end

  # A fly with nothing in view is not aimed at anything, and a network balanced
  # between two halves would walk one straight line for ever. The wander leans it
  # one way for a while and then the other, so the fly sweeps. The patch here is
  # distant but *read*, which is what keeps the step a steer: a patch with no
  # readings at all is the search, and that is a different test.
  test "a fly with nothing in view leans one way, then the other", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {first, policy, state} = step(policy, state, scene(2.0, 0.02), touching(0.025))

    state =
      Enum.reduce(1..40, state, fn _step, state ->
        {_result, _policy, state} = step(policy, state, scene(2.0, 0.02), touching(0.025))
        state
      end)

    {turned, _policy, _state} = step(policy, state, scene(2.0, 0.02), touching(0.025))

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
    assert_in_delta slid.left_distance, 0.01, 1.0e-9, "the bout's centimetre across it, leftwards"
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
  # patch is, and a thing that is *closing* is one the view remembers. A thing
  # already in view that doubles — not one that merely comes nearer, because a
  # half was an approach and read as too careful — is not walked at: the step goes
  # the other way, by no more than a step, because a loom is a reason to stop
  # closing rather than to fly across the room.
  test "something that looms is stepped away from, while a slow approach is not", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    # The patch is at the standoff throughout, so the standoff rule alone would
    # crawl at every one of these steps.
    {_first, policy, state} = step(policy, state, scene(0.2, 0.02), touching(0.025))

    {closer, policy, state} = step(policy, state, scene(0.15, 0.02), touching(0.025))

    {closest, _policy, _state} = step(policy, state, scene(0.07, 0.02), touching(0.025))

    assert [%OrientHorizontal{forward_distance: 0.004}] = closer.actions,
           "a third nearer is an approach, not a loom"

    assert [%OrientHorizontal{forward_distance: retreat}] = closest.actions
    assert retreat < 0.0, "twice as near is a loom: stepped away from"
    assert abs(retreat) <= 0.05, "and no further than a step"
  end

  # A drive past the ceiling does not drive the network harder, it silences it:
  # with a refractory period of a millisecond or two, a rate high enough to hold
  # most neurons in refractory leaves the readouts empty. So a surface close
  # enough to ask for a thousand hertz asks for two hundred and twenty.
  test "a surface close enough to shout is still driven inside the band", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} =
      step(policy, state, observations([[0.005, 0.005, 0.005, 0.005]]), touching(0.02))

    assert result.telemetry.left_hz <= 220.0
    assert result.telemetry.right_hz <= 220.0
  end

  # A patch that sees nothing is not on the object, whatever the percept says: a
  # blank patch and an absent one are the same blindness, and both want the
  # search rather than a steer. A run of this policy walked on into empty space
  # this way — the patch had left the knife, the view finder still showed it as a
  # bar, and the evidence sat at 124.395 for seventeen hundred steps while every
  # frame the patch took was one blank colour.
  test "a patch that sees nothing searches instead of steering", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    blank = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[0.2, 0.2]]},
        "patch" => %{"depth" => [[0.0, 0.0]]}
      }
    }

    {result, _policy, _state} = step(policy, state, blank, touching(0.025))

    assert [%OrientHorizontal{forward_distance: forward}] = result.actions
    assert forward > 0.0, "it goes towards what the view finder can see"
  end

  # A patch that has shown the same thing for twenty steps is not being shown the
  # object, whatever the percept says — the case a bout timer cannot catch, and
  # the one that cost seventeen hundred steps: the patch hanging above the table,
  # every image one flat grey, every nearness the same, the evidence frozen at
  # 124.395. Twenty steps is `n_steps` in the sensor module's own thresholds, so
  # this is the framework's answer and not a taste.
  test "a patch that stops changing sends the fly looking again", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    table = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[0.0, 0.0]]},
        "patch" => %{"depth" => [[0.03, 0.03], [0.03, 0.03]]}
      }
    }

    {_first, policy, state} = step(policy, state, table, touching(0.03))

    state =
      Enum.reduce(1..20, state, fn _step, state ->
        {_result, _policy, state} = step(policy, state, table, touching(0.03))
        state
      end)

    {result, _policy, _state} = step(policy, state, table, touching(0.03))

    assert [%OrientHorizontal{} = searching] = result.actions
    assert searching.rotation_degrees == 30.0, "round the search circle, looking for the object"
  end

  # And a patch at its own ceiling has seen nothing at all: the clip is the
  # sensor's answer above five centimetres, and the agent rides a decimetre above
  # the table and cannot descend, so over the table every reading is the ceiling.
  # Nothing says "flat"; it says "nothing". What the fly does then is Monty's own
  # opening — walk at what the wide view shows.
  test "a patch reading its own clip walks at what the view finder shows", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, scene(0.2, 0.05), touching(0.05))

    assert [%OrientHorizontal{} = hopped] = result.actions
    assert hopped.forward_distance > 0.0, "towards the object the wide view can see"
    assert hopped.left_distance == 0.0, "a hop, not a slide along nothing"
  end

  # And the look aims at where the view is *not* flat: the one target a policy
  # without semantics has. A table is uniform; an object standing on it is an
  # edge.
  test "a look turns towards the most structured part of the view", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    table = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[0.5, 0.5, 0.2, 0.5]]},
        "patch" => %{"depth" => [[0.03, 0.03], [0.03, 0.03]]}
      }
    }

    {_first, policy, state} = step(policy, state, table, touching(0.03))

    state =
      Enum.reduce(1..20, state, fn _step, state ->
        {_result, _policy, state} = step(policy, state, table, touching(0.03))
        state
      end)

    {result, _policy, _state} = step(policy, state, table, touching(0.03))

    assert [%OrientHorizontal{rotation_degrees: degrees}] = result.actions
    assert degrees > 0.0, "the near thing is on the right of the picture: turn right"
    assert abs(degrees) <= 30.0
  end

  # Looking once is looking. Looking twice at the same unchanged thing is a fly
  # that will not leave on its own — and the two timers used to make that for
  # ever: a look put the bout's clock back to nought, so the sixty steps that
  # cause a departure could never arrive, and the stall put the clock back again
  # as soon as walking resumed. A fly in that loop looks every twenty steps for as
  # long as the episode lasts; one run's evidence curve was a flat line at 124.395
  # from step 400 to step 2600 because of it.
  test "a second stall on the same surface leaves instead of looking twice", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {first, policy, state} = table_steps(policy, state, 22)
    assert [%OrientHorizontal{rotation_degrees: 30.0}] = first.actions, "the first look"

    # The look itself, and the twenty stalled steps it bought nothing from.
    {second, _policy, _state} = table_steps(policy, state, 6 + 20)

    assert [%OrientHorizontal{} = left] = second.actions
    assert abs(left.rotation_degrees) == 180.0, "an about-face, not a third look"
    assert left.forward_distance < 0.0, "and off the surface, not along it"
  end

  # And off the object the same frozen patch is the same answer, which `:cruise`
  # had no clock to notice: a plane that has not changed under the sensor for
  # twenty steps is not being searched, and one run walked a straight line across
  # a tabletop for 5000 steps reading one flat value at every step because nothing
  # off the object ever counted the steps.
  #
  # The step is a leg of a sweep and not the search circle: a circle is for
  # orbiting something, and a lost fly that aims at the most structured column of a
  # room aims at a wall — the episode that took four percepts in five thousand
  # steps did exactly that. A quarter turn and a stride, alternating sides, fans
  # out over the ground.
  test "a blank plane under the patch is swept, a quarter turn at a time", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    blank = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[0.2, 0.2]]},
        "patch" => %{"depth" => [[0.05, 0.05], [0.05, 0.05]]}
      }
    }

    {result, _policy, _state} =
      Enum.reduce(1..22, {nil, policy, state}, fn _step, {_result, policy, state} ->
        step(policy, state, blank, touching(0.05))
      end)

    assert [%OrientHorizontal{} = swept] = result.actions
    assert_in_delta abs(swept.rotation_degrees), 90.0, 1.0e-9, "a quarter turn"
    assert swept.left_distance == 0.0, "no orbit: there is nothing here to go round"
    assert swept.forward_distance > 0.0, "and a stride"
  end

  # A look is a step of the bout it interrupts, not the start of a new one: sixty
  # steps of surface is sixty steps, looked at or not.
  test "a look does not restart the bout's clock", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {_looking, policy, state} = table_steps(policy, state, 22)
    {leaving, _policy, _state} = walk(policy, state, 39)

    assert [%OrientHorizontal{forward_distance: hop}] = leaving.actions
    assert hop < 0.0, "the bout ends on its own clock: at step 61, not at step 81"
  end

  # And the step over open ground is the bout's stride, not four millimetres.
  # Four millimetres is under the patch's own one-centimetre delta threshold, so
  # the patch reads the same place again and again and the view never changes —
  # which is what makes the stall counter fire and the fly look at nothing. Where
  # less than a stride of room is left, the step is the room.
  test "a patch with room to walk is stepped at the bout's stride", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, scene(0.5, 0.045), touching(0.045))

    assert [%OrientHorizontal{forward_distance: distance}] = result.actions
    assert_in_delta distance, 0.01, 1.0e-9
  end

  # The animal does not crawl over the first thing it touches for ever: it walks a
  # bout, leaves, and lands again somewhere else. Sixty steps is the bout, and
  # what ends it is an about-face — 180 degrees, which the centring reflex cannot
  # pull back — and a hop off the surface.
  test "a bout on the surface ends with the fly leaving it", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {_walking, policy, state} = walk(policy, state, 60)
    {leaving, _policy, _state} = step(policy, state, observations(mug()), touching(0.025))

    assert [%OrientHorizontal{} = left] = leaving.actions
    assert left.rotation_degrees == 180.0, "an about-face the centring reflex cannot pull back"
    assert left.forward_distance < 0.0, "and a hop off the surface, not along it"
    assert left.left_distance == 0.0
  end

  # And the side it turns alternates, so two departures cannot return it to the
  # same face of what it left: left, then right.
  test "successive departures turn opposite ways", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {_walking, policy, state} = walk(policy, state, 60)
    {first, policy, state} = step(policy, state, observations(mug()), touching(0.025))
    {_off, policy, state} = step(policy, state, scene(0.2, 0.3), away())
    {_walking, policy, state} = walk(policy, state, 60)
    {second, _policy, _state} = step(policy, state, observations(mug()), touching(0.025))

    assert [%OrientHorizontal{rotation_degrees: one_way}] = first.actions
    assert [%OrientHorizontal{rotation_degrees: other_way}] = second.actions

    assert one_way * other_way < 0.0,
           "one departure one way, the next the other: #{one_way} then #{other_way}"
  end

  # And the departure is not a second behaviour it gets stuck in: the moment the
  # patch is off the object the search is the policy again, which is Monty's own
  # `_touch_object` walking back to what it left.
  test "the departure ends when the patch is off the object, and it approaches again", %{
    state: state
  } do
    {:ok, policy, state} = Policy.new([], state)

    {_walking, policy, state} = walk(policy, state, 60)
    {_leaving, policy, state} = step(policy, state, observations(mug()), touching(0.025))
    {returning, _policy, _state} = step(policy, state, scene(0.2, 0.3), away())

    assert [%OrientHorizontal{rotation_degrees: degrees, forward_distance: forward}] =
             returning.actions

    assert forward > 0.0, "back towards what it left"
    assert abs(degrees) <= 10.0, "and the turn is the view finder's, not the departure's"
  end

  # Landing again is the start of a new bout, not the continuation of the old one:
  # the first step back on the object is a slide, not another departure.
  test "landing again starts a new bout", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {_walking, policy, state} = walk(policy, state, 60)
    {_leaving, policy, state} = step(policy, state, observations(mug()), touching(0.025))
    {_returning, policy, state} = step(policy, state, scene(0.2, 0.3), away())

    {landed, _policy, _state} = step(policy, state, observations(mug()), touching(0.01))

    assert [%OrientHorizontal{} = walked] = landed.actions
    assert_in_delta walked.left_distance, 0.01, 1.0e-9, "a bout's slide, not a departure"
    refute walked.rotation_degrees == 180.0
  end

  # The slide is what the fly does *at* the surface. While there is room to walk
  # there is nothing to slide along, and the step travels forward as it always
  # did.
  test "in open view the step walks, and does not slide", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} =
      step(policy, state, observations([[0.02, 0.02, 100.0, 100.0]]), touching(0.4))

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.forward_distance == 0.01, "a stride of open view, and no slide across it"
    assert walked.left_distance == 0.0
  end

  # An empty patch is not a reason to keep walking. The fly has lost the object,
  # so what it does is search — the circle Monty's surface policy draws — rather
  # than steer on a wish that has nothing to be about. (The tonic floor, which is
  # what makes the network say "no preference" rather than nothing at all, is
  # asserted where it is observable: the drives in the telemetry.)
  test "a patch with nothing in it searches rather than walking on", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.0, 0.0, 0.0, 0.0]])

    assert [%OrientHorizontal{} = searched] = result.actions
    assert searched.rotation_degrees == 30.0, "a step round the search circle"
    assert searched.left_distance > 0.0
  end

  test "the telemetry is the spikes the decision was made of", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[0.02, 0.02, 100.0, 100.0]])

    assert result.telemetry.left_spikes > 0
    assert result.telemetry.right_spikes == 0
    assert result.telemetry.wish > 0.0

    assert result.telemetry.left_hz == 220.0,
           "the tonic plus 200 Hz of nearness, held at the ceiling the network answers in"

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

    # The wide view always holds the ground at the standoff — its nearest pixel is
    # the floor under the sensor — so a step computed from that pixel is nought on
    # every step of an approach. A fly that steps nought is a fly whose patch is
    # handed the same frame for the rest of the episode: one run's evidence sat at
    # 201.1 with 152 hypotheses for 4700 steps that way. So the cruise step always
    # travels, by a crawl at least.
    test "still travels when the nearest thing in view is at the standoff", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.025, 0.05), away())

      assert [%OrientHorizontal{forward_distance: distance}] = result.actions
      assert_in_delta distance, 0.004, 1.0e-9, "a crawl, and never a pivot on the spot"
    end

    # A lost fly walks at the structure of the view, not at the floor: the nearest
    # pixel of a room is the ground under the sensor, a hand's width away and
    # directly below, so aiming at it aims at the fly's own feet. One run crossed
    # the room for 4700 steps that way with the patch's image byte-identical at
    # every step while the wide view changed under it.
    test "walks at the column where the view is not flat", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      # A floor at a decimetre, and one column of it that is a wall a metre away.
      floor = [[0.1, 0.1, 0.1, 0.1], [0.1, 0.1, 0.9, 0.1]]

      {result, _policy, _state} = step(policy, state, scene(floor, 0.05), touching(0.05))

      assert [%OrientHorizontal{} = walked] = result.actions
      assert walked.rotation_degrees > 0.0, "the far column is right of the middle"
      assert walked.forward_distance > 0.0, "and the step still travels"
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
    # network is the policy again: the turn is the readouts' and not the search's.
    test "hands back to the network once the patch is on the object", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.2, 0.02), on_object(0.5))

      assert [%OrientHorizontal{} = walked] = result.actions
      assert walked.rotation_degrees == 0.0, "the search would be thirty degrees"
      assert Map.has_key?(result.telemetry, :wish), "the pair of readouts decided the turn"
      assert_in_delta walked.forward_distance, 0.01, 1.0e-9, "a bout's stride, not a hop"
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

  # Steps of a bout on the surface: the patch sits at the standoff on something,
  # and the fly walks it. The depth changes a little from step to step because
  # that is what walking over a surface looks like — a still picture is a stall,
  # and the policy now says so.
  defp walk(policy, state, steps) do
    Enum.reduce(1..steps, {nil, policy, state}, fn step, {_result, policy, state} ->
      depth = 0.02 + rem(step, 5) * 0.001
      step(policy, state, observations([[depth, depth, 100.0, 100.0]]), touching(0.025))
    end)
  end

  defp mug, do: [[0.02, 0.02, 100.0, 100.0]]

  # A patch on a plain surface it cannot tell from the object, with a view finder
  # that holds nothing: the same reading, step after step. This is what the stall
  # counter is for. Three centimetres is inside the clip, so the patch is on
  # something — it is the reading that never changes, not the reading that says
  # nothing.
  defp table_steps(policy, state, steps) do
    table = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[0.0, 0.0]]},
        "patch" => %{"depth" => [[0.03, 0.03], [0.03, 0.03]]}
      }
    }

    Enum.reduce(1..steps, {nil, policy, state}, fn _step, {_result, policy, state} ->
      step(policy, state, table, touching(0.03))
    end)
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
