defmodule FlyversePlugin.PolicyTest do
  # Not async: the pack a node steps is application configuration, and one test
  # here is about a node with none.
  use ExUnit.Case, async: false

  alias FlyversePlugin.{Demonstrator, Pack, Policy}

  alias Monty.Frameworks.Actions.{OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Geometry.Rotation

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

    {result, _policy, _state} = step(policy, state, [[0.04, 0.04, 100.0, 100.0]])

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.agent_id == "agent_id_0"
    assert walked.rotation_degrees < 0.0, "left, because the left half is nearer"
    assert walked.forward_distance == 0.01, "and it walks while it turns, by the bout's stride"
  end

  test "a nearer right side turns it right while it walks", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, [[100.0, 100.0, 0.04, 0.04]])

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
      step(policy, state, at(0.01, [[0.02, 0.02, 100.0, 100.0]]), touching(0.01))

    assert [%OrientHorizontal{} = slid] = result.actions
    assert_in_delta slid.left_distance, 0.01, 1.0e-9, "the bout's centimetre across it, leftwards"
    assert_in_delta slid.forward_distance, -0.015, 1.0e-9, "and back to the standoff"
    assert slid.rotation_degrees < 0.0, "the turn is the way it was already leaning"
  end

  # The standoff is read from the *nearest* thing in the patch, not from the mean
  # of its image, and clipping is why the two differ. This config replaces every
  # reading past five centimetres with five, so a patch pressed against a curve has
  # half its pixels at the ceiling: the mean of one centimetre and five is three,
  # which is outside the standoff and asks for one more step into the surface. A
  # run's frames are the evidence — a dark curved sliver, clipped white everywhere
  # else, for a whole episode, the sensor pressing into the thing it stands off
  # from while its own percept reported room.
  test "a half-clipped patch is measured from its nearest pixel, and back off it goes",
       %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    clipped = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[2.0, 2.0]]},
        "patch" => %{"depth" => [[0.01, 0.05], [0.01, 0.05]]}
      }
    }

    {result, _policy, _state} = step(policy, state, clipped, touching(0.03))

    assert [%OrientHorizontal{} = backed] = result.actions

    assert_in_delta backed.forward_distance,
                    -0.015,
                    1.0e-9,
                    "one centimetre from the surface is too close, whatever the rest of the image averages"
  end

  # The standoff is held, not a constant step: a sensor at 20 mm with 25 mm
  # wanted backs away by the 5 mm it is too close, and one further off than the
  # standoff crawls at the four millimetres a step has always been.
  # The outline is what tells two objects apart. The middle of a mug's top and the
  # middle of a can's top are the same flat square; the curvature where the top
  # turns down is not — and a patch that cannot descend will never read anything
  # else that differs. So the patch's own halves pull the heading: the clip makes
  # each half a switch, surface under it or nothing within reach, and the half that
  # still has surface is the half the object is on.
  test "a patch straddling an edge turns towards the object it is on", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    straddling = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[2.0, 2.0]]},
        "patch" => %{"depth" => [[0.05, 0.02], [0.05, 0.02]]}
      }
    }

    {result, _policy, _state} = step(policy, state, straddling, touching(0.02))

    assert [%OrientHorizontal{} = walked] = result.actions

    assert_in_delta walked.rotation_degrees,
                    10.0,
                    1.0,
                    "right, because the object is under the right half"
  end

  test "the same edge on the other side turns the other way", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    straddling = %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[2.0, 2.0]]},
        "patch" => %{"depth" => [[0.02, 0.05], [0.02, 0.05]]}
      }
    }

    {result, _policy, _state} = step(policy, state, straddling, touching(0.02))

    assert [%OrientHorizontal{} = walked] = result.actions
    assert_in_delta walked.rotation_degrees, -10.0, 1.0, "left, and by the same amount"
  end

  test "a patch wholly on the object has no edge to follow", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = step(policy, state, at(0.02), touching(0.02))

    assert [%OrientHorizontal{} = walked] = result.actions
    assert walked.rotation_degrees == 0.0, "both halves on it is no side to prefer"
  end

  # What a top-down patch cannot see at all costs a whole episode: the spoon lies
  # one and a half centimetres up while the patch reaches five from a decimetre, so
  # six baseline episodes reached the step ceiling without ever reading it, and one
  # never took a percept of it at all.
  #
  # Two swept legs without surface is the fly's own evidence that the *height* is
  # wrong rather than the direction, and the answer is twelve steps of vertical
  # probe: six down, six back. It is the only motion this policy has that can put a
  # table into reach, and giving the altitude back matters because the tall objects
  # are visible from it.
  test "a fly that has swept twice without finding surface dives, then climbs back",
       %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {dive, policy, state} = until_vertical(policy, state, 150)

    assert [%OrientVertical{} = down] = dive.actions
    assert_in_delta down.down_distance, 0.01, 1.0e-9, "a centimetre at a time"
    assert down.forward_distance == 0.0, "a dive is a height, not a walk"
    assert dive.motor_only_step, "and the module is not shown a step with nothing under it"

    # Down for six, then the same six back up.
    {_results, {policy, state}} =
      Enum.map_reduce(1..5, {policy, state}, fn _step, {policy, state} ->
        {result, policy, state} = step(policy, state, blank(), away())
        {result, {policy, state}}
      end)

    {climbing, _policy, _state} = step(policy, state, blank(), away())

    assert [%OrientVertical{} = up] = climbing.actions

    assert_in_delta up.down_distance,
                    -0.01,
                    1.0e-9,
                    "back up, because the height the tall objects need is not given away"
  end

  # One frozen patch is the ordinary case — a fly crossing a table sees its clip on
  # every step — so the first stall is still a look, not a probe.
  test "a fly that has only just stalled looks around rather than diving", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = still_steps(policy, state, pose([0.0, 0.0, 0.1]), 25)

    assert [%OrientHorizontal{}] = result.actions, "a swept leg, not a dive"
  end

  # A patch at the standoff crawls, and one nearer it backs away
  test "a patch at the standoff crawls, and one nearer it backs away", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {standing, _policy, _state} = step(policy, state, at(0.025), touching(0.025))

    {:ok, policy, state} = Policy.reset(policy, state)

    {nearer, _policy, _state} = step(policy, state, at(0.02), touching(0.02))

    assert [%OrientHorizontal{forward_distance: crawl}] = standing.actions
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
    {_first, policy, state} = step(policy, state, scene(0.2, 0.025), touching(0.025))

    {closer, policy, state} = step(policy, state, scene(0.15, 0.025), touching(0.025))

    {closest, _policy, _state} = step(policy, state, scene(0.07, 0.025), touching(0.025))

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

    {result, _policy, _state} =
      Enum.reduce(1..22, {nil, policy, state}, fn _step, {_result, policy, state} ->
        step(policy, state, blank(), touching(0.05))
      end)

    assert [%OrientHorizontal{} = swept] = result.actions
    assert_in_delta abs(swept.rotation_degrees), 90.0, 1.0e-9, "a quarter turn"
    assert swept.left_distance == 0.0, "no orbit: there is nothing here to go round"
    assert swept.forward_distance > 0.0, "and a stride"
  end

  # A fly can be stuck in the way that no turn fixes: the actions come, the body
  # does not move. The stall machinery cannot answer that, because it answers
  # "this picture has not changed" with a turn — and a turn is what the fly was
  # already doing when it did not move. So the policy measures the body instead:
  # the same pose for twelve steps is idle, and an idle fly struggles, swinging a
  # quarter period at a time.
  test "a fly that has not moved is nudged, and the swing turns over", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)
    stuck = pose([0.0, 1.5, 0.1])

    {one_way, policy, state} = still_steps(policy, state, stuck, 23)
    {other_way, _policy, _state} = still_steps(policy, state, stuck, 20)

    assert [%OrientHorizontal{} = swung] = one_way.actions
    assert_in_delta swung.rotation_degrees, 90.0, 1.0e-6, "the peak of the swing"
    assert swung.forward_distance > 0.0, "and a stride with every swing"

    assert [%OrientHorizontal{} = back] = other_way.actions
    assert_in_delta back.rotation_degrees, -90.0, 1.0e-6, "half a period later, the other way"
  end

  # And a fly that is walking is never swung: the nudge is for standing still, not
  # a gait of its own. It walks over new ground here — a patch that changes every
  # step — because a fly that walks over the same square centimetre for twenty
  # steps is a stall, and a stall is the sweep's business, not the nudge's.
  test "a fly that is moving is never nudged", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    turns =
      Enum.map_reduce(1..40, {policy, state}, fn step, {policy, state} ->
        walking = pose([0.0, 1.5, 0.1 + step * 0.01])
        ground = scene(0.2, 0.02 + step * 0.001)

        {result, policy, state} = step(policy, state, ground, away(), walking)
        {result.actions, {policy, state}}
      end)
      |> elem(0)
      |> List.flatten()
      |> Enum.map(& &1.rotation_degrees)

    assert Enum.all?(turns, &(abs(&1) <= 30.0)),
           "a walking fly turns within its gait, never by the nudge's quarter turn: #{inspect(turns)}"
  end

  # A world that reports no agents cannot be called idle: with no two poses to
  # compare there is no evidence of standing still, and a policy that invented one
  # would swing a fly that is walking perfectly well.
  test "a fly whose world reports no pose is never called idle", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} = still_steps(policy, state, nil, 40)

    assert [%OrientHorizontal{} = stepped] = result.actions
    assert abs(stepped.rotation_degrees) <= 30.0
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
  # did. The room has to be *inside* the patch's five-centimetre reach: further
  # off than that the patch reads its ceiling, which is a fly that has lost the
  # object rather than one with room to walk at it.
  test "in open view the step walks, and does not slide", %{state: state} do
    {:ok, policy, state} = Policy.new([], state)

    {result, _policy, _state} =
      step(policy, state, at(0.045, 0.02), touching(0.045))

    assert [%OrientHorizontal{} = walked] = result.actions

    assert_in_delta walked.forward_distance,
                    0.01,
                    1.0e-9,
                    "a stride of open view, and no slide across it"

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

      assert result.motor_only_step,
             "and the module is not shown it: a five-centimetre hop is five times the " <>
               "distance it can associate a feature across"
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

      assert result.motor_only_step, "and the module is not shown a step off the object"
    end

    # A tenth of the patch on the object is the line Monty draws, and past it the
    # network is the policy again: the turn is the readouts' and not the search's.
    test "hands back to the network once the patch is on the object", %{state: state} do
      {:ok, policy, state} = Policy.new([], state)

      {result, _policy, _state} = step(policy, state, scene(0.2, 0.04), on_object(0.5))

      assert [%OrientHorizontal{} = walked] = result.actions
      assert walked.rotation_degrees == 0.0, "the search would be thirty degrees"
      assert Map.has_key?(result.telemetry, :wish), "the pair of readouts decided the turn"
      assert_in_delta walked.forward_distance, 0.01, 1.0e-9, "a bout's stride, not a hop"

      refute result.motor_only_step,
             "and the module is shown it: there is a surface under the patch"
    end

    defp radians(degrees), do: degrees * :math.pi() / 180.0
  end

  defp step(policy, state, depth) do
    step(policy, state, observations(depth), nil)
  end

  defp step(policy, state, observations, percept) do
    step(policy, state, observations, percept, nil)
  end

  # The same step with the motor system's own report of where the body is.
  defp step(policy, state, observations, percept, motor_state) do
    {:ok, result, policy, state} =
      Policy.call(policy, {nil, observations, motor_state, percept, nil}, state)

    {result, policy, state}
  end

  # Steps of a fly whose patch reads its clip, with nothing ever changing under it,
  # until the step turns out to be vertical. Returns the pair and the state it
  # happened in, so the steps of the dive that follow are the same fly's.
  defp until_vertical(policy, state, within) do
    Enum.reduce_while(1..within, {nil, policy, state}, fn _step, {_result, policy, state} ->
      {result, policy, state} = step(policy, state, blank(), away())

      if match?([%OrientVertical{}], result.actions),
        do: {:halt, {result, policy, state}},
        else: {:cont, {result, policy, state}}
    end)
  end

  # Steps of a fly that is not moving: the same blank patch and the same pose, over
  # and over.
  defp still_steps(policy, state, motor_state, steps) do
    Enum.reduce(1..steps, {nil, policy, state}, fn _step, {_result, policy, state} ->
      step(policy, state, blank(), away(), motor_state)
    end)
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
    # it, and the centring reflex would turn away from it every step. The patch
    # is two columns for the same reason — its halves are what says which way the
    # edge of an object runs.
    view = if is_list(view_depth), do: view_depth, else: [[view_depth, view_depth]]

    %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => view},
        "patch" => %{"depth" => [[patch_depth, patch_depth]]}
      }
    }
  end

  # A patch with nothing within its five-centimetre clip — the tabletop the agent
  # rides a decimetre above — and a wide view that holds nothing worth walking at.
  defp blank do
    %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => [[0.2, 0.2]]},
        "patch" => %{"depth" => [[0.05, 0.05], [0.05, 0.05]]}
      }
    }
  end

  defp away,
    do: %Monty.Cmp.Message{
      sender_id: "patch",
      sender_type: :sm,
      morphological_features: %{"object_coverage" => 0.0}
    }

  # What the patch is lying on, as the patch itself reports it: the nearest thing
  # in its image, which is the number the standoff is held against. The wide view
  # is the fly's drive and is a room rather than a surface, so a test that means
  # one of them says which.
  defp at(depth, view \\ 2.0) do
    view = if is_list(view), do: view, else: [[view, view]]

    %{
      "agent_id_0" => %{
        "view_finder" => %{"depth" => view},
        "patch" => %{"depth" => [[depth, depth], [depth, depth]]}
      }
    }
  end

  # A percept that says how much of the patch is on the object, and what the
  # surface it is on averages. The standoff is not read from this: it is read from
  # the patch's own image, because clipping makes an average over that image lie.
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

  # Where the body is: the proprioceptive state Monty hands every policy. The idle
  # counter reads it, so a test that means "this fly has not moved" has to say
  # where it is — step after step, at the same place.
  defp pose([_x, _y, _z] = position) do
    %{
      "agent_id_0" => %AgentState{
        sensors: %{},
        position: position,
        rotation: Rotation.identity()
      }
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
