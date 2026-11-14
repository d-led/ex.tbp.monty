defmodule FlyversePlugin.Policy do
  @moduledoc """
  A motor policy offered by this node: a spiking connectome decides where the
  sensor looks next.

  This is the plugin the example exists for. Every other decision in an Elixir
  Monty Studio run is made by a function; this one is made by *spikes*. Two
  neuron groups are driven by how close the world is on the left of the view and
  on the right of it, the network steps 20 ms of biology in Rust, and which of
  two readout groups fired more is what turns the sensor.

  ## What is the network's and what is ours

  The network's: how much each neuron integrates, when it fires, and what that
  firing propagates to. That is flyverse's engine and the pack's wiring, and
  nothing here computes it.

  Ours, and said out loud because it is the part a reader should argue with:

    * **nearness is `1 / depth`**, per half of the image (`FlyversePlugin.Percept`);
    * **a rate is nearness times a gain**, 4 Hz per inverse metre, capped
      at 400 Hz — the two numbers that put a drive into a spiking model at all;
    * **a difference of spike counts is a steering wish**, averaged with the
      30 ms time constant flyverse's own body uses for its motor readouts
      (`MOTOR_TAU_S` in `sim.rs`);
    * **a wish becomes an action**: positive turns left, negative turns right,
      and a network with no preference walks straight. A turn is
      `OrientHorizontal`, the surf agent's own, because an action a world does
      not implement is one it skips — and a skipped action is a policy that
      decides and is never obeyed.

  With the demonstrator pack (`mix flyverse_plugin.pack`) that wiring is two
  excitatory edges, so a nearer left side turns the sensor left — towards what
  it is looking at. With the dataset's pack the same code asks the fly's own
  wiring, and what it does is a question this example does not answer: the
  dataset has no ventral nerve cord, no muscles and no donor body state, which
  is flyverse's own sentence about itself, and it is the honest one here too.

  ## Why `:owner_only`

  The simulation is a NIF resource: a term this node's BEAM understands and no
  other's. It also holds the membrane potentials of every neuron in the pack, so
  sending it per step would cost more than the step. So the simulation stays in
  this node's process and the policy value that crosses a cluster is the name of
  it — which is exactly what `:owner_only` means (`MontyPlugin`). A caller that
  reached a copy of this plugin on another node would be refused there, because
  only the node that allocated the name has the state behind it.
  """

  @behaviour FlyversePlugin.Plugin

  alias FlyversePlugin.{Native, Networks, Percept}

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Actions.OrientHorizontal
  alias Monty.Frameworks.Environments.PositioningProcedures
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  @enforce_keys [:sim]
  defstruct [:sim, :agent_id, :sensor_id, :turn_degrees, :distance]

  @type t :: %__MODULE__{
          sim: pos_integer(),
          agent_id: String.t(),
          sensor_id: String.t() | nil,
          turn_degrees: float(),
          distance: float()
        }

  # Monty's own surf-agent experiments turn five degrees and step four
  # millimetres; the same numbers here so a comparison is about the policy and
  # not about the gait.
  @turn_degrees 5.0
  @distance 0.004

  # The most a bend ever turns the fly in one step, in degrees. The network's
  # wish and the centring reflex are added in the same frame, so the sum needs a
  # ceiling: an animal's saccade is a saccade, not a spin.
  @max_turn_degrees 30.0

  # The most the centring reflex turns it in one step: a fly that has lost the
  # object turns at most this far towards whatever the view finder can see.
  @centring_degrees 10.0
  @agent_id "agent_id_0"

  # The ride height of the drive: at 25 mm from a surface, `1/d` is 40 and the
  # drive is 160 Hz, which is the rate flyverse's own world stimulates its
  # sensory population at. It is a gain, not a law.
  @drive_gain 4.0

  # The ceiling on a drive, and the floor at nought, are the *band* the network
  # still answers in. A leaky integrate-and-fire population driven much past this
  # is not driven faster, it is silenced: with a refractory period of a millisecond
  # or two, a rate high enough to put most neurons in refractory most of the time
  # leaves the readouts with nothing to report and the wish clamped at zero — a
  # fly that is stimulated and does not move. 220 Hz is the top of the band and
  # `@tonic_hz` the bottom, so neither a very near surface nor the wander can push
  # a drive out of it.
  @max_hz 220.0

  # What both drives carry whether or not anything is in view. A leaky
  # integrate-and-fire network with no input is silent, and a silent network is a
  # fly that neither walks nor turns: with the nearness drive alone, a flat
  # patch on a table is 0 Hz on both sides, nought spikes, and a wish that says
  # "no preference" because there was nothing to prefer. The tonic rate is the
  # animal's own spontaneous activity — a walking fly in the dark still walks —
  # so what the two halves decide is the *difference* between them, and an empty
  # view is a measurement of balance rather than of silence.
  @tonic_hz 80.0

  # The difference of spike counts a full bend is worth. `tanh` maps it, because
  # counts have no ceiling: one runaway readout should mean "turn hard", not
  # "turn three hundred degrees". Two spikes is the order a demonstrator pack of
  # four neurons produces in a 20 ms window.
  @wish_scale 2.0

  # The animal's steering is asymmetric: its two descending-neuron populations are
  # not identical instruments, and the same imbalance of spikes turns it further
  # one way than the other. That is why a walking fly traces curves and never a
  # line. The gain below one is the weaker side; the wander turns the wish over
  # often enough that the weaker side still gets walked.
  @right_gain 0.8

  # The wander: a small rate added to one side and taken from the other, turning
  # over every `@wander_steps`. A fly with nothing in view is not aimed at
  # anything, and a network perfectly balanced between two halves would walk a
  # straight line for ever — which in a room is one wall and then nothing. The
  # animal wanders, and this is the cheapest honest version of it: a square wave
  # rather than noise, because a run has to be repeatable.
  @wander_hz 20.0
  @wander_steps 40

  # flyverse's `MOTOR_TAU_S`: the low-pass its own body applies to a motor
  # read-out before the body acts on it.
  @motor_tau_s 0.030

  # The loom only counts when the view *doubles* in one step. The first version
  # of this read half again, and a half is what an ordinary approach towards a
  # standoff looks like: the fly then braked on nearly every step and read as too
  # careful. A doubling is the thing that is not an approach.
  @loom_floor 1.0
  @loom_threshold 1.0

  # The bout, which is the animal's own way of exploring: it does not crawl over
  # the first thing it touches for ever. It walks a bout on the surface, leaves,
  # and lands again somewhere else — Monty's `_touch_object` cycle, driven by a
  # timer rather than by a spike.
  #
  # A spiking connectome does not decide *when* to change behaviour over seconds;
  # in the animal that is the neuromodulatory state, and here it is a counter with
  # the one rule a run can be read against: sixty steps of walking, then a turn
  # away that the centring reflex cannot pull back, and a hop off the surface.
  # The hop is the whole of "flight" this world offers — the sensor has no wings,
  # so leaving is a step backwards into open view, and what comes next is the
  # same approach that landed it the first time.
  @bout_steps 60
  @depart_steps 4

  # How long the patch may show the *same* nearness before the policy stops
  # believing it is on the object any more. Twenty steps is `n_steps` in the
  # sensor module's own delta thresholds — the longest the framework will go
  # without a fresh percept — so the number is the framework's, not a taste.
  #
  # It caught the case a bout timer cannot: after two hundred steps on the knife
  # the patch was hanging half a decimetre above the *table*, every image one
  # flat grey, every nearness `20.0`, and the evidence frozen at 124.395 for
  # seventeen hundred steps. The fly was reading a plane that never changed and
  # walking on it for ever. A patch that has shown the same thing for twenty
  # steps is a patch that is not being shown the object, so the step is the
  # search.
  @stall_steps 20

  # How long a look around lasts: six steps of the search circle, which is half a
  # turn — and the circle's own lateral step is what carries the patch off the
  # surface it was reading, because turning on the spot over a table stays over
  # the table.
  @look_steps 6

  # How many looks one bout is worth before the surface is written off. One: a
  # second look at the same unchanging thing is not a second opinion — the fly
  # has already turned towards the most structured part of the view and walked a
  # circle round it, and the view answered the same thing. What it has not done
  # is leave, so leaving is the second answer.
  #
  # The ladder matters because the two timers fought each other without it: every
  # look put the bout's clock back to nought, so the sixty steps that cause a
  # departure could never arrive, and the stall put it back in the same loop. A
  # fly in that loop looks every twenty steps for as long as the episode lasts,
  # and the evidence curve is the flat line it produced — 124.395 from step 400
  # to step 2600 of a run. So a look now *continues* the bout rather than
  # restarting it, and a second stall ends the bout outright.
  @looks_per_bout 1

  # The stride of a bout, and it is one centimetre because the framework says so
  # rather than because it looks right: the patch sensor this config gives the
  # agent (`camera_surf_delta`) sends a new percept when the patch has moved
  # `distance: 0.01`, and the learning module matches locations at
  # `max_match_distance: 0.01`. Four millimetres — Monty's own surf-agent crawl —
  # is therefore less than half a reading, so most of what the module was handed
  # was the place it had just been. That is what a flat stretch in a run's
  # evidence curve is: twenty steps of the same surface. A centimetre is the
  # first stride that hands the module something it has not seen, and it keeps
  # the patch at the standoff: over a centimetre a 4 cm radius curves by about a
  # millimetre, which the crawl step absorbs.
  @explore_stride 0.010

  # The departure's turn is a body saccade — the fast, high-angle yaw the animal
  # uses to change sides — and it is an about-face: 180 degrees, into open space,
  # away from what it was crawling over. Whatever the surface's shape, turning
  # round and walking back off it lands the fly facing the side it came from, so
  # the next approach reads the other half of the object. Its *side* alternates
  # as well, left then right then left, so that two departures in a row cannot
  # return to the same face: the animal traces a figure eight rather than a loop.
  #
  # No geometry is needed for any of that, which is the point: this policy is
  # given `1 / depth` per half of the picture and nothing else about the world —
  # no radius, no centre, no pose — and an about-face is the one instruction that
  # needs none.
  @depart_degrees 180.0

  # flyverse's `DT_MS`, in seconds: the tick a window is counted in. A plan
  # counts ticks, and the wish is a first-order update over the time they took.
  @tick_seconds 0.0001

  # -- Monty's own opening ---------------------------------------------------
  #
  # The network steers a sensor that is already on something. It cannot walk to
  # the object: spikes about where the object is exist only once the object is
  # in the patch, and before that the whole policy is what Monty's surface
  # policy does before its walk — `SurfacePolicy.__call__`'s first branch and
  # `_touch_object`. The numbers are Monty's, quoted from
  # `motor_policies.py` so they can be compared line for line.

  # `object_coverage` below this is a sensor that has left the object, or has
  # not reached it (`SurfPolicy`'s threshold).
  @coverage_to_touch 0.1

  # What the view finder must see to be worth walking at, in metres, and where a
  # `MoveForward` puts the sensor: Monty's `desired_object_distance` in
  # `base_10simobj_surf_agent`, a fingertip from the surface.
  @visible 1.0
  @desired_object_distance 0.025

  # The circle a search steps round, as a multiple of the standoff — ten
  # centimetres in front of the agent, as Monty's comment says — and how far
  # round it one step goes.
  @search_circle_factor 4.0
  @search_degrees 30.0

  # The most one touch step may cover: two standoffs, five centimetres. Monty
  # walks the whole gap in one \u2014 it knows where the object is, because its
  # world has one \u2014 and a scene with a table and a room around it does not:
  # a gap measured past the object is a leap past it, and a run spent a thousand
  # steps in the void that way. Five centimetres closes a hand's width in four
  # steps, and cannot fail that way.
  @touch_stride 0.05
  # A step that could not travel would be a fly pivoting on the spot, which is
  # the one thing its locomotion never does: `action/2` carries the crawl step
  # forward on every step, so the only way to stand still is to have no depth to
  # judge the step by. The touch opening is the fallback when that happens.
  @view_finder "view_finder"
  @patch "patch"

  # The patch's depth is clipped at five centimetres by this config's transform
  # (`depth_clip_sensors: [0]`, `clip_value: 0.05`, and sensor nought is the
  # patch), so a patch reading `0.05` is a patch with **nothing within five
  # centimetres of it**: the value is the ceiling, not a measurement. In inverse
  # metres that ceiling is twenty.
  #
  # It matters because the agent rides a decimetre above the table and cannot
  # descend — `OrientHorizontal` turns and steps, and nothing in it lowers the
  # sensor. So over the table every reading is the clip, and a policy that walked
  # a bout on it would be walking ground it cannot see: the reading says nothing,
  # it does not say "flat". A fly whose patch is at the ceiling has not reached
  # anything, and what it does then is Monty's own opening — walk at what the wide
  # view shows.
  @clip_nearness 20.0

  @doc "The name a cluster registers it under."
  @spec name() :: String.t()
  def name, do: "flyverse_plugin.lif_steering"

  @doc """
  What a cluster asks about it.

  `needs: [:monty]` for the actions and the result it answers with — and only
  that: the network is this package's own dependency, not a tag a caller has to
  carry.
  """
  @impl FlyversePlugin.Plugin
  @spec describe() :: MontyPlugin.description()
  def describe do
    %{
      "name" => name(),
      "kind" => :motor_policy,
      "version" => FlyversePlugin.version(),
      "placement" => :owner_only,
      "needs" => [:monty]
    }
  end

  @doc """
  Nothing yet: a simulation exists per policy, not per plugin.

  The map is where the policies' simulations live. It is in this process on
  purpose — see the moduledoc on `:owner_only` — and it is keyed by the number a
  policy carries, so two episodes of a sweep are two simulations.
  """
  @impl FlyversePlugin.Plugin
  def initial_state, do: %{simulations: %{}, next: 1}

  @doc """
  A policy over this node's pack, and the simulation it steps.

  Refused, with the sentence that says why, when the pack's plan does not name
  exactly two drives and two readouts: this policy maps left and right, and a
  plan that named four groups would make `Enum.at/2` a silent decision about
  which two.
  """
  @impl FlyversePlugin.Plugin
  def new(options, state) do
    with {:ok, network} <- Networks.open(),
         :ok <- two_sided(network.directory, network.plan),
         {:ok, simulation} <- start(network) do
      key = state.next
      policy = policy_of(options, key)

      {:ok, policy,
       %{state | simulations: Map.put(state.simulations, key, simulation), next: key + 1}}
    end
  end

  @doc """
  Steps the network on what the sensor saw, and answers the action that follows.

  Two halves, in Monty's order. While the patch is not on the object —
  `object_coverage` below a tenth — the answer is Monty's `_touch_object` with
  the one thing a fly must add to it: turn towards what the view finder sees
  while closing the gap to the standoff, or step round a search circle when it
  can see nothing. The network is not asked, because it has nothing to steer
  by: its input is how near the left half of the patch is compared with the
  right, and an empty patch says the same thing everywhere.

  Once the patch is on the object, the network decides: the rates are computed
  from the image, the window is stepped in Rust, and the difference of the
  readout counts is the steering wish — added to the same centring turn, so a
  fly that is learning a surface keeps it in the middle of the picture.
  """
  @impl FlyversePlugin.Plugin
  def call(%__MODULE__{} = policy, {_ctx, observations, _motor_state, percept, _goal}, state) do
    simulation = Map.fetch!(state.simulations, policy.sim)
    next = bout(simulation, on_object?(percept) and sees_something?(observations, policy))
    advanced = advance(simulation, next)
    state = put(state, policy.sim, advanced)

    case next do
      :explore -> steer(policy, observations, percept, state)
      :depart -> {:ok, departing(policy, advanced), policy, state}
      :look -> {:ok, looking(policy, observations), policy, state}
      :cruise -> {:ok, touch(policy, observations), policy, state}
    end
  end

  # A patch that sees nothing is not on the object, whatever the percept says. A
  # blank patch and an absent one are the same blindness, and both want the
  # search rather than a steer — a run of this policy walked on into empty space
  # this way: the patch had left the knife, the view finder still showed it as a
  # bar, and the evidence sat at 124.395 for seventeen hundred steps while every
  # frame the patch took was one blank colour.
  #
  # "Nothing" includes the clip. A patch at its own ceiling has seen no surface at
  # all, and a fly that is a hand's width above the table sees exactly that at
  # every step — the case a run spent five thousand steps on.
  defp sees_something?(observations, policy) do
    case patch_nearness(observations, policy) do
      nil -> false
      {left, right} -> max(left, right) > @clip_nearness
    end
  end

  # Which of the animal's three behaviours this step is in. A bout is a walk on
  # the surface; it ends on the timer, and the departure lasts until the patch is
  # off the object — or `@depart_steps` steps, whichever comes first, because an
  # object large enough to walk off for ever must not become a fly that never
  # lands on anything.
  #
  # A patch that has stopped changing outranks both: whatever the percept says,
  # a view that has shown the same thing for twenty steps is not the object. The
  # answer is to look around — the search circle, which turns and moves sideways
  # — and then to walk again, because a fly that only ever turns is a fly that
  # reads one square centimetre for ever, and a fly that only ever walks over the
  # table is one that reads nothing at all.
  #
  # Looking once is looking; looking twice at the same unchanged thing is a fly
  # that will not leave on its own, so the second stall is the departure.
  defp bout(%{look_steps: taken}, true) when taken > 0 and taken < @look_steps, do: :look

  defp bout(%{still: still, looks: looked}, true) when still >= @stall_steps,
    do: if(looked >= @looks_per_bout, do: :depart, else: :look)

  defp bout(_simulation, false), do: :cruise

  defp bout(%{bout: :depart, bout_steps: taken}, true) when taken < @depart_steps, do: :depart

  defp bout(%{bout_steps: taken}, true) when taken >= @bout_steps, do: :depart

  defp bout(_simulation, true), do: :explore

  # A counter counts only while the behaviour it counts is the one being done,
  # and the step that enters a behaviour is its first: landing again is a new
  # bout, not the continuation of the old one. Being off the object is not a
  # behaviour it counts, because there is nothing there to time.
  defp advance(simulation, :cruise),
    do: %{simulation | bout: :cruise, bout_steps: 0, still: 0, look_steps: 0, looks: 0}

  defp advance(simulation, :look) do
    looking_on = simulation.bout == :look

    %{
      simulation
      | bout: :look,
        bout_steps: bout_steps(simulation, :look),
        still: 0,
        look_steps: if(looking_on, do: simulation.look_steps + 1, else: 1),
        looks: if(looking_on, do: simulation.looks, else: simulation.looks + 1)
    }
  end

  defp advance(simulation, next) do
    %{
      simulation
      | bout: next,
        bout_steps: bout_steps(simulation, next),
        look_steps: 0,
        looks: looks(simulation, next),
        departures: departures(simulation, next)
    }
  end

  # Walking and looking are one bout, so each continues the other's clock. It is
  # the whole of the fix for the loop described at `@looks_per_bout`: while a look
  # started the clock again, the departure the clock exists to cause was
  # unreachable, and a stalled fly looked for ever.
  @surface [:explore, :look]

  defp bout_steps(%{bout: bout, bout_steps: taken}, next)
       when bout in @surface and next in @surface,
       do: taken + 1

  defp bout_steps(%{bout: bout, bout_steps: taken}, next) when bout == next, do: taken + 1

  defp bout_steps(_simulation, _next), do: 1

  # The count of looks belongs to the bout, so walking on keeps it — that is how a
  # second stall is recognised as the same surface — and leaving ends it.
  defp looks(%{bout: :depart} = simulation, :depart), do: simulation.looks
  defp looks(_simulation, :depart), do: 0
  defp looks(simulation, :explore), do: simulation.looks

  # One side per departure, counted once — when the departure begins.
  defp departures(%{bout: :depart} = simulation, :depart), do: simulation.departures
  defp departures(simulation, :depart), do: simulation.departures + 1
  defp departures(simulation, _next), do: simulation.departures

  defp steer(policy, observations, percept, state) do
    simulation = Map.fetch!(state.simulations, policy.sim)

    with {:ok, {_sensor_id, rows}} <-
           Percept.image(observations, policy.agent_id, policy.sensor_id),
         {:ok, window} <- step(simulation, rows) do
      wish = smoothed(simulation, window.left - window.right)
      result = result(policy, wish, window, percept, observations)
      patch = patch_nearness(observations, policy)

      simulation = %{
        simulation
        | wish: wish,
          spikes: window.spikes,
          last: window,
          nearness: window.nearness,
          patch_nearness: patch || simulation.patch_nearness,
          still: still(simulation.patch_nearness, patch, simulation.still),
          steps: simulation.steps + 1
      }

      {:ok, result, policy, put(state, policy.sim, simulation)}
    end
  end

  # The two questions this policy asks of a view are not the same question, and
  # they are not asked of the same sensor. "How near is the world on the left, and
  # on the right" is the drive, asked of the wide view, because a fly steers by
  # what looms in the room. "Is the thing I am reading still the same thing" is
  # asked of the patch, because the patch is what the learning module learns from:
  # a wide view whose walls have not moved is not progress, and a patch that has
  # stopped changing is not the object.
  #
  # Asking the wide view both questions cost a run its episode. With the patch
  # reading one flat grey at its five-centimetre clip — `depth_clip_sensors: [0]`
  # in this config's transform, and sensor nought is the patch — the view finder's
  # nearness still changed as the fly walked, so the stall never fired, and the fly
  # crossed the table for seventeen hundred steps with the evidence frozen at
  # 124.395. A config that gives an agent no patch has one view, and both
  # questions are asked of it.
  defp patch_nearness(observations, policy) do
    case Percept.image(observations, policy.agent_id, policy.sensor_id || @patch) do
      {:ok, {_sensor, rows}} ->
        Percept.nearness(rows)

      {:error, _no_patch} ->
        case Percept.image(observations, policy.agent_id, nil) do
          {:ok, {_sensor, rows}} -> Percept.nearness(rows)
          {:error, _nothing} -> nil
        end
    end
  end

  # Whether the patch is on the object at all, which is Monty's own question and
  # his own threshold. A percept carrying no coverage — a policy driven by
  # something other than a surface sensor — leaves the walk to the network.
  defp on_object?(nil), do: true

  defp on_object?(percept) do
    case Message.feature(percept, "object_coverage") do
      {:ok, coverage} when is_number(coverage) -> coverage >= @coverage_to_touch
      _absent -> true
    end
  end

  # Monty's `_touch_object`, with the one thing a fly must add to it: Monty's
  # `MoveForward` walks straight because Monty's world puts the object in the
  # middle of the view finder for it. A fly that has drifted has to turn towards
  # what it sees, and a run of this policy showed why — the mug was centred at
  # step 5 and a sliver at the left edge by step 100, and the patch never landed
  # on it again. So the step is `OrientHorizontal` carrying both: the centring
  # turn, and the distance that closes the gap to the standoff.
  #
  # The gap is not Monty's centre pixel either, and for the reason given below
  # it: Monty's gap is the depth of the view finder's centre pixel, which in a
  # room is whatever the middle of the picture happens to be — a wall across the
  # table, in a run this policy spent a thousand steps recovering from. So the
  # gap is the *nearer* of that pixel and the nearest thing the view can see: a
  # step that lands on what is closest rather than past it.
  defp touch(policy, observations) do
    depth = PositioningProcedures.depth_at_center(observations, policy.agent_id, @view_finder)
    nearest = nearest_in_view(observations, policy.agent_id)
    gap = gap(nearest, depth)
    centring = centring(observations, policy.agent_id)

    action =
      if gap < @visible do
        %OrientHorizontal{
          agent_id: policy.agent_id,
          rotation_degrees: centring,
          left_distance: 0.0,
          forward_distance: approach(gap)
        }
      else
        search(policy)
      end

    %MotorPolicyResult{
      actions: [action],
      # Monty hides one corrective step from the learning module because nothing
      # on an out-of-view object is learnable. A search is not one step: it lasts
      # until something comes into view, and the step it does is the first step
      # with anything on it. So the module is fed every step — `nothing yet`
      # until the patch is on the object, and evidence when it is.
      motor_only_step: false,
      telemetry: %{
        depth_at_center: depth,
        nearest: nearest,
        centring: centring,
        searching: gap >= @visible
      }
    }
  end

  # Lost, and looking. The step keeps the search circle's size and travel, but
  # turns towards the *most structured* column of the view finder rather than a
  # fixed thirty degrees — because the reason to look is a surface with nothing
  # on it, and the one target a policy with no semantics still has is where the
  # depth stops being flat. On a table that is the silhouette of whatever is
  # standing on it.
  defp looking(policy, observations) do
    %MotorPolicyResult{
      actions: [
        %{search(policy) | rotation_degrees: towards(structure(observations, policy.agent_id))}
      ],
      motor_only_step: false,
      telemetry: %{looking: true}
    }
  end

  # Where in the view the depth varies most, as a fraction of the picture's width
  # from the middle: negative is left. `:none` when the view is uniform — nothing
  # in it is worth turning towards — or when there is no view to read.
  defp structure(observations, agent_id) do
    case Percept.image(observations, agent_id, @view_finder) do
      {:ok, {_sensor, rows}} -> most_varied(rows)
      {:error, _sentence} -> :none
    end
  end

  # `Percept.image/3` has already refused an empty picture, so there is a picture
  # here and the width is the narrowest row.
  defp most_varied(rows) do
    width = rows |> Enum.map(&length/1) |> Enum.min()

    if width < 2, do: :none, else: widest(wide_columns(rows, width), width)
  end

  defp wide_columns(rows, width) do
    for column <- 0..(width - 1) do
      rows
      |> Enum.map(&Enum.at(&1, column))
      |> Enum.filter(&(is_number(&1) and &1 > 0.0))
      |> case do
        [] -> 0.0
        depths -> Enum.max(depths) - Enum.min(depths)
      end
    end
  end

  defp widest(columns, width) do
    most = Enum.max(columns, fn -> 0.0 end)

    if most <= 0.0,
      do: :none,
      else: (Enum.find_index(columns, &(&1 == most)) || 0) / (width - 1) - 0.5
  end

  # A fraction of the picture becomes a turn in the same frame as every other
  # rotation here: negative is left. The fraction is of the *turn budget*, not of
  # a field of view this policy is not told — a policy that guessed an angle from
  # an unknown lens would be inventing a number, so it spends the budget it has.
  defp towards(:none), do: @search_degrees

  defp towards(fraction) when is_float(fraction), do: fraction * 2 * @max_turn_degrees

  # The departure. A turn is taken whole — the centring reflex would pull the fly
  # back onto what it is looking at, and this step is the one that must not — and
  # the step is backwards off the surface at the approach stride. It is a hop, not
  # a flight: this world's sensor has no wings, so what a fly does with them is
  # what a step backwards does here.
  defp leave(policy, departures) do
    %OrientHorizontal{
      agent_id: policy.agent_id,
      rotation_degrees: saccade(departures),
      left_distance: 0.0,
      forward_distance: -@touch_stride
    }
  end

  # Right, then left, then right: the first departure turns one way and the next
  # turns the other, so the two landings are on different faces of what it left.
  defp saccade(departures) when rem(departures, 2) == 1, do: @depart_degrees

  defp saccade(_departures), do: -@depart_degrees

  # A departure is a step the network did not decide, so it says so in the
  # telemetry rather than in the wish: a reader of a run can then tell a fly that
  # left from a fly that was steered off.
  defp departing(policy, simulation) do
    %MotorPolicyResult{
      actions: [leave(policy, simulation.departures)],
      motor_only_step: false,
      telemetry: %{leaving: true, turn_degrees: saccade(simulation.departures)}
    }
  end

  # How far the step travels towards something the view finder can see: the
  # shortfall against the standoff, and no more than a stride of it forwards.
  #
  # Backwards when the shortfall is negative, which is the case that cost a run
  # its episode: a sensor nearer than the standoff — pressed against a surface
  # by the slide, with the patch off the object — computes a gap that has
  # already been closed, and a `MoveForward` of nought leaves it exactly where
  # it is. The run then froze: frames from step 480 to step 1331 were identical
  # to the byte, and the evidence stayed at the number it had reached. A step
  # that cannot travel forward travels back — as far as the standoff and no
  # further, because a gap is never negative — which puts the object at the
  # standoff again, where the patch can read it and the network can steer.
  # The gap to close, from the two things the view finder reports: the centre
  # pixel's depth and the nearest thing anywhere in the picture. A depth of nought
  # is not a surface at no distance — it is a reading the world did not give, and
  # both sensors report it when they see nothing at all — so it is not a
  # measurement and does not narrow anything. A run of this policy backed away
  # from a gap of nought for an entire episode this way.
  defp gap(nearest, depth) when is_number(depth) and depth > 0.0 do
    if nearest == :infinity, do: depth, else: min(depth, nearest)
  end

  defp gap(nearest, _no_reading), do: nearest

  defp approach(gap), do: min(gap - @desired_object_distance, @touch_stride)

  # The nearest thing the wide view can see, in metres, or `:infinity` when the
  # horizon holds nothing. `FlyversePlugin.Percept` already answers what a
  # closer half of the picture means (the drive), so the same nearness is the
  # nearest thing here.
  defp nearest_in_view(observations, agent_id) do
    case Percept.image(observations, agent_id, @view_finder) do
      {:ok, {_sensor, rows}} ->
        {left, right} = Percept.nearness(rows)

        case max(left, right) do
          nearness when nearness <= 0.0 -> :infinity
          nearness -> 1.0 / nearness
        end

      {:error, _sentence} ->
        :infinity
    end
  end

  defp search(policy) do
    radius = @desired_object_distance * @search_circle_factor
    radians = rad(@search_degrees)

    %OrientHorizontal{
      agent_id: policy.agent_id,
      rotation_degrees: @search_degrees,
      left_distance: :math.tan(radians) * radius,
      forward_distance: radius * (1.0 - :math.cos(radians)) / :math.cos(radians)
    }
  end

  @doc "Starts the next episode at the connectome's resting state."
  @impl FlyversePlugin.Plugin
  def reset(%__MODULE__{} = policy, state) do
    simulation = Map.fetch!(state.simulations, policy.sim)

    case Native.reset(simulation.sim) do
      :ok ->
        {:ok, policy,
         put(state, policy.sim, %{
           simulation
           | wish: 0.0,
             spikes: 0,
             nearness: {0.0, 0.0},
             patch_nearness: nil,
             still: 0,
             look_steps: 0,
             looks: 0,
             bout: :cruise,
             bout_steps: 0,
             departures: 0
         })}

      {:error, {code, sentence}} ->
        {:error, "#{code}: #{sentence}"}
    end
  end

  @doc """
  What the network did, for a run that wants to be read afterwards.

  Spikes and a steering wish rather than a heading: the heading is the motor
  system's, and what a reader of *this* policy wants to know is whether the
  connectome was saying anything at all.
  """
  @impl FlyversePlugin.Plugin
  def state_dict(%__MODULE__{} = policy, state) do
    simulation = Map.fetch!(state.simulations, policy.sim)

    %{
      simulation: policy.sim,
      ticks_per_step: simulation.ticks,
      wish: simulation.wish,
      spikes: simulation.spikes,
      bout: simulation.bout,
      bout_steps: simulation.bout_steps,
      look_steps: simulation.look_steps,
      looks: simulation.looks,
      departures: simulation.departures,
      still: simulation.still,
      last_counts: [simulation.last.left, simulation.last.right]
    }
  end

  defp policy_of(options, key) do
    %__MODULE__{
      sim: key,
      agent_id: Keyword.get(options, :agent_id, @agent_id),
      sensor_id: Keyword.get(options, :sensor_id),
      turn_degrees: Keyword.get(options, :turn_degrees, @turn_degrees),
      distance: Keyword.get(options, :distance, @distance)
    }
  end

  defp two_sided(directory, %{drives: drives, readouts: readouts}) do
    cond do
      length(drives) != 2 ->
        {:error,
         "the plan in #{directory} names #{length(drives)} drive group(s), and this policy " <>
           "drives two: the left half of the view and the right half of it"}

      length(readouts) != 2 ->
        {:error,
         "the plan in #{directory} names #{length(readouts)} readout(s), and this policy " <>
           "reads two: what the network says about the left and about the right"}

      true ->
        :ok
    end
  end

  # A simulation is the network plus the few numbers this policy keeps beside
  # it — the wish, the spikes so far, and the window it last read. All of them
  # are per policy, which is why they live here and not in the policy value: a
  # policy value is copied by every call, and a wish is not worth a copy.
  defp start(network) do
    rates = Enum.map(network.plan.drives, fn _group -> 0.0 end)

    case Native.new(
           network.connectome,
           network.plan.drives,
           rates,
           network.plan.readouts,
           network.plan.seed
         ) do
      {:ok, simulation} ->
        {:ok,
         %{
           sim: simulation,
           connectome: network.connectome,
           ticks: network.plan.ticks,
           seconds: network.plan.ticks * @tick_seconds,
           wish: 0.0,
           spikes: 0,
           steps: 0,
           nearness: {0.0, 0.0},
           patch_nearness: nil,
           still: 0,
           look_steps: 0,
           looks: 0,
           bout: :cruise,
           bout_steps: 0,
           departures: 0,
           last: %{left: 0, right: 0, spikes: 0, rates: [0.0, 0.0]}
         }}

      {:error, {code, sentence}} ->
        {:error, "#{code}: #{sentence}"}
    end
  end

  defp step(simulation, rows) do
    nearness = Percept.nearness(rows)
    {left_nearness, right_nearness} = nearness
    wander = wander(simulation.steps)

    rates = [
      band(rate(left_nearness) + wander),
      band(rate(right_nearness) - wander)
    ]

    case Native.window(simulation.sim, simulation.connectome, simulation.ticks, rates) do
      {:ok, {counts, spikes, _total}} ->
        {:ok,
         %{
           left: Enum.at(counts, 0, 0),
           right: Enum.at(counts, 1, 0),
           spikes: spikes,
           rates: rates,
           nearness: nearness,
           loom: loom(simulation.nearness, nearness)
         }}

      {:error, {code, sentence}} ->
        {:error, "#{code}: #{sentence}"}
    end
  end

  # The wish is the difference of the two readout counts, low-passed the way
  # flyverse's own body low-passes a motor read-out: a first-order update over
  # the window the network just stepped. A silent network therefore keeps the
  # wish it had instead of snapping to zero, which is what gives the walk its
  # momentum.
  defp smoothed(simulation, differential) do
    alpha = 1.0 - :math.exp(-simulation.seconds / @motor_tau_s)

    simulation.wish + alpha * (differential - simulation.wish)
  end

  defp result(policy, wish, window, percept, observations) do
    [left_hz, right_hz] = window.rates
    depth = mean_depth(percept, @visible)

    %MotorPolicyResult{
      actions: [action(policy, wish, depth, window.loom, observations)],
      telemetry: %{
        left_hz: left_hz,
        right_hz: right_hz,
        left_spikes: window.left,
        right_spikes: window.right,
        spikes: window.spikes,
        wish: wish,
        loom: window.loom
      }
    }
  end

  # Every step walks *and* turns, because that is what a fly does: its
  # locomotion is walking with turns in it — bouts of walking, a saccade, more
  # walking — and an animal that yaws where it stands is an animal standing
  # still. A run of this policy spent a thousand steps like that: the network
  # said "left", the action turned left with no distance, and the patch saw the
  # same three square centimetres of table for ever.
  #
  # So the turn is `OrientHorizontal` — not `TurnLeft`/`TurnRight`, which are the
  # distant agent's actions and which a surf agent has no `actuate_turn_*` for —
  # and it carries the crawl step: the yaw is the spike-driven bend (positive is
  # left, as the drives are named, and the world yaws by `-rotation_degrees`),
  # and `forward_distance` is the four millimetres that make the step a step.
  # A balanced view bends by nought and walks straight; an unbalanced one curves
  # while walking, exactly as much as the readouts differ.
  #
  # The exception is the loom: something nearer than the standoff is something
  # the step would walk into, so the step is a *slide across* that surface rather
  # than a pivot on it — `left_distance`, the same axis Monty's
  # `horizontal_distances` uses to orbit a point while turning. A fly pressed
  # against a mug and turning on the spot is a fly that reads the same flat
  # patch for ever: measured, fifteen hundred steps of it left the hypothesis
  # set exactly as wide as it started, eight objects possible, while the
  # evidence climbed to four hundred. Sliding is what sweeps new surface past
  # the patch, and the network decides which way, because the sign of the wish
  # is the side its readouts preferred. That is Monty's own
  # `MoveTangentially`-between-touches cycle, made one action instead of four.
  defp action(%__MODULE__{} = policy, wish, depth, loom, observations) do
    %OrientHorizontal{
      agent_id: policy.agent_id,
      rotation_degrees: turn(policy, wish, centring(observations, policy.agent_id)),
      left_distance: side(wish) * slide(policy, depth),
      forward_distance: crawl(policy, depth, loom)
    }
  end

  # How far one step slides sideways: the bout's stride when the patch is at the
  # surface, nought while there is still room to walk at it.
  defp slide(_policy, depth),
    do: if(depth < @desired_object_distance, do: @explore_stride, else: 0.0)

  # And how far it travels along its facing, which is the standoff kept rather
  # than a constant. A step of nought at the surface is a step the slide then
  # pushes *into* the object: a run of this policy slid until the patch was
  # inside the mug, where every frame is the same flat colour, and the evidence
  # and the hypothesis set stopped changing for two thousand steps. So a sensor
  # nearer than the standoff backs away by the shortfall, and one further from it
  # takes the crawl step; the surface keeps a fingertip's distance without the
  # policy being told where the surface's normal is.
  #
  # The loom outranks all of that: something already in view that suddenly fills
  # half again as much of it is closing on the sensor, and the step is the other
  # way. It is bounded by the crawl step, so a loom costs a step's retreat rather
  # than a flight, and it is measured from the view rather than from the depth the
  # percept reports, so it needs nothing the world does not already show.
  defp crawl(%__MODULE__{} = policy, _depth, loom) when loom > @loom_threshold do
    -min(loom * policy.distance, @touch_stride)
  end

  # With room to walk, the step is the bout's stride and not Monty's four
  # millimetres, because four millimetres is under the patch's own one-centimetre
  # delta threshold: the patch then reads the same place again and again, and a
  # view that never changes is precisely what the stall counter sees. Watching a
  # run, that is a fly that walks with a frozen picture — an unbroken grey patch
  # for two hundred steps at 4 mm each. Where there is not a stride of room left,
  # the step closes the gap to the standoff and no more.
  defp crawl(%__MODULE__{} = policy, depth, _loom) when depth >= @desired_object_distance,
    do: stride(policy, depth - @desired_object_distance)

  defp crawl(_policy, depth, _loom), do: depth - @desired_object_distance

  defp stride(policy, room), do: room |> min(@explore_stride) |> max(policy.distance)

  # How many steps running the patch has shown the same nearness. The image this
  # is read from is the patch's and not the wide view's — see `patch_nearness/2`.
  defp still(previous, nearness, taken) when previous == nearness, do: taken + 1

  defp still(_previous, _nearness, _taken), do: 0

  # How fast what is in view is growing, as the growth of the nearer half over the
  # nearness it had. A view that held nothing has nothing to have grown from: what
  # arrives there is a landing, and the standoff rule has already spoken about it.
  defp loom({previous_left, previous_right}, {left, right}) do
    before = max(previous_left, previous_right)

    if before < @loom_floor,
      do: 0.0,
      else: max(max(left - previous_left, right - previous_right) / before, 0.0)
  end

  # Which way along the surface the network leans. A wish of nought has no side
  # to prefer, and a step has to go somewhere: left is the fly's own convention
  # for a positive drive, and the wander turns the wish over often enough that
  # the choice is not a bias in the run.
  defp side(wish) when wish < 0.0, do: -1.0

  defp side(_wish), do: 1.0

  # The depth the patch is standing off, as the percept reports it. A percept
  # that reports no depth is a world this policy cannot measure, and `@visible`
  # — a metre, the edge of what it walks at — is the honest assumption there:
  # it walks, which is the one thing the step must do.
  defp mean_depth(nil, fallback), do: fallback

  defp mean_depth(percept, fallback) do
    case Message.feature(percept, "mean_depth") do
      {:ok, [value | _rest] = values} when is_number(value) ->
        Enum.sum(values) / length(values)

      {:ok, value} when is_number(value) ->
        value

      _absent ->
        fallback
    end
  end

  # The angle the step yaws by, in the frame `OrientHorizontal` uses: positive is
  # right and negative is left, because the world yaws by the negative of it.
  #
  # A wish to the left is therefore a negative angle here, and nothing invents a
  # turn the network did not decide: a wish of nought turns by the centring
  # correction alone. The correction is already in this frame — negative is
  # towards the side the view finder sees something on — so the two add, and the
  # sum is held to a full bend so neither term can spin the fly past its gait.
  defp turn(policy, wish, centring) do
    rotation = centring - bend(policy, wish)
    rotation |> max(-@max_turn_degrees) |> min(@max_turn_degrees)
  end

  # The bend the network asked for, at the strength the side it asked for is
  # worth. A wish to the right is a negative angle here, which is the weak side.
  defp bend(policy, wish) when wish < 0.0,
    do: policy.turn_degrees * @right_gain * :math.tanh(wish / @wish_scale)

  defp bend(policy, wish), do: policy.turn_degrees * :math.tanh(wish / @wish_scale)

  # How far to turn to put what the view finder sees back in the middle of the
  # picture, in the frame `rotation_degrees` uses: negative is left. The nearer
  # half is the side the object has drifted to, so the fly turns towards it —
  # the centring reflex every seeing animal has, and the one thing that keeps
  # the patch on the object it is learning. A view with nothing in it is a view
  # with no opinion, and the step goes where it was going.
  defp centring(observations, agent_id) do
    case Percept.image(observations, agent_id, @view_finder) do
      {:ok, {_sensor, rows}} ->
        {left, right} = Percept.nearness(rows)
        total = left + right

        if total <= 0.0,
          do: 0.0,
          else: -@centring_degrees * :math.tanh((left - right) / total)

      {:error, _sentence} ->
        0.0
    end
  end

  defp rate(nearness), do: @tonic_hz + nearness * @drive_gain

  # A drive is a rate in the band the network answers in: never negative, and
  # never past the ceiling that silences it. One function clamps, so a change to
  # the ceiling is a change in one place.
  defp band(hz), do: hz |> max(0.0) |> min(@max_hz)

  # Which way the fly leans when nothing in the view does: one way for a while,
  # then the other. Deterministic on purpose — the same pack and the same scene
  # must step the same way twice.
  defp wander(steps) do
    if rem(div(steps, @wander_steps), 2) == 0, do: @wander_hz, else: -@wander_hz
  end

  defp rad(degrees), do: degrees * :math.pi() / 180.0

  defp put(state, key, simulation),
    do: %{state | simulations: Map.put(state.simulations, key, simulation)}
end
