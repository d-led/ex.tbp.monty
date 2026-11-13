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
  alias Monty.Frameworks.Actions.{MoveForward, OrientHorizontal}
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
  @agent_id "agent_id_0"

  # The ride height of the drive: at 25 mm from a surface, `1/d` is 40 and the
  # drive is 160 Hz, which is the rate flyverse's own world stimulates its
  # sensory population at. It is a gain, not a law.
  @drive_gain 4.0
  @max_hz 400.0

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
  `object_coverage` below a tenth — the answer is Monty's `_touch_object`: one
  `MoveForward` across the whole gap the view finder can see, or a step round a
  search circle when it can see nothing. The network is not asked, because it
  has nothing to steer by: its input is how near the left half of the patch is
  compared with the right, and an empty patch says the same thing everywhere.

  Once the patch is on the object, the network decides: the rates are computed
  from the image, the window is stepped in Rust, and the difference of the
  readout counts is the steering wish.
  """
  @impl FlyversePlugin.Plugin
  def call(%__MODULE__{} = policy, {_ctx, observations, _motor_state, percept, _goal}, state) do
    if on_object?(percept) do
      steer(policy, observations, percept, state)
    else
      {:ok, touch(policy, observations), policy, state}
    end
  end

  defp steer(policy, observations, percept, state) do
    simulation = Map.fetch!(state.simulations, policy.sim)

    with {:ok, {_sensor_id, rows}} <-
           Percept.image(observations, policy.agent_id, policy.sensor_id),
         {:ok, window} <- step(simulation, rows) do
      wish = smoothed(simulation, window.left - window.right)
      result = result(policy, wish, window, percept)

      simulation = %{
        simulation
        | wish: wish,
          spikes: window.spikes,
          last: window,
          steps: simulation.steps + 1
      }

      {:ok, result, policy, put(state, policy.sim, simulation)}
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

  # Monty's `_touch_object`, step for step: the object is in view, so walk the
  # whole gap in one step — twenty centimetres, where a four-millimetre crawl is
  # fifty steps of no new view — and when it is not in view, step round a circle
  # ten centimetres ahead until it is.
  #
  # One departure from Monty's line, and the reason for it: Monty's gap is the
  # depth of the view finder's centre pixel, which in a room is whatever the
  # middle of the picture happens to be — a wall across the table, in a run this
  # policy spent a thousand steps recovering from. So the gap is the *nearer* of
  # that pixel and the nearest thing the view can see: a step that lands on what
  # is closest rather than past it.
  defp touch(policy, observations) do
    depth = PositioningProcedures.depth_at_center(observations, policy.agent_id, @view_finder)
    nearest = nearest_in_view(observations, policy.agent_id)
    gap = if nearest == :infinity, do: depth, else: min(depth, nearest)

    action =
      if gap < @visible do
        %MoveForward{
          agent_id: policy.agent_id,
          distance: min(max(gap - @desired_object_distance, 0.0), @touch_stride)
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
      telemetry: %{depth_at_center: depth, nearest: nearest, searching: gap >= @visible}
    }
  end

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
        {:ok, policy, put(state, policy.sim, %{simulation | wish: 0.0, spikes: 0})}

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
           last: %{left: 0, right: 0, spikes: 0, rates: [0.0, 0.0]}
         }}

      {:error, {code, sentence}} ->
        {:error, "#{code}: #{sentence}"}
    end
  end

  defp step(simulation, rows) do
    {left_nearness, right_nearness} = Percept.nearness(rows)
    wander = wander(simulation.steps)

    rates = [
      spread(rate(left_nearness) + wander),
      spread(rate(right_nearness) - wander)
    ]

    case Native.window(simulation.sim, simulation.connectome, simulation.ticks, rates) do
      {:ok, {counts, spikes, _total}} ->
        {:ok,
         %{
           left: Enum.at(counts, 0, 0),
           right: Enum.at(counts, 1, 0),
           spikes: spikes,
           rates: rates
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

  defp result(policy, wish, window, percept) do
    [left_hz, right_hz] = window.rates

    %MotorPolicyResult{
      actions: [action(policy, wish, mean_depth(percept, @visible))],
      telemetry: %{
        left_hz: left_hz,
        right_hz: right_hz,
        left_spikes: window.left,
        right_spikes: window.right,
        spikes: window.spikes,
        wish: wish
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
  # The one exception is the loom: something nearer than the standoff is
  # something the step would walk into, so the step stops travelling and the
  # bend is taken whole — the fly swings away from what it is touching instead of
  # pressing through it. A lofty `LC4` firing rate is Monty's own standoff, and
  # here it is the patch's own depth that says it.
  defp action(%__MODULE__{} = policy, wish, depth) do
    %OrientHorizontal{
      agent_id: policy.agent_id,
      rotation_degrees: -bend(policy, wish),
      left_distance: 0.0,
      forward_distance: if(depth < @desired_object_distance, do: 0.0, else: policy.distance)
    }
  end

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

  # Positive is left and negative is right, and nothing here invents a turn the
  # network did not decide: a wish of nought is a straight step.
  defp bend(policy, wish), do: policy.turn_degrees * :math.tanh(wish / @wish_scale)

  defp rate(nearness), do: min(@tonic_hz + nearness * @drive_gain, @max_hz)

  defp spread(hz), do: max(hz, 0.0)

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
