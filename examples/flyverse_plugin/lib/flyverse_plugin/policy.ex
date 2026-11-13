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
      and a network with no preference still walks — a base turn is added to
      what the spikes ask for, because a turn with no slide is a turn on the
      spot, and a sensor that turns on the spot gathers one percept for ever.
      The action is `OrientHorizontal`, the surf agent's own: its
      `rotation_degrees` is the turn, its `left_distance` the slide that turn is
      worth at this depth, and its `forward_distance` the press back to the
      standoff. An action a world does not implement is one it skips.

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
  # not about the gait. The five degrees are a *base* turn, kept even when the
  # network is indifferent — see `crawl/3` for why that is what makes a step a
  # step rather than a turn on the spot.
  @turn_degrees 5.0
  @distance 0.004
  @agent_id "agent_id_0"

  # How far a spike of disagreement may bend the base turn, each way. A fly does
  # not spin on one leg because one readout fired; thirty degrees is a corner,
  # and the low-pass already keeps the wish from changing that fast.
  @max_turn_degrees 30.0

  # The difference of spike counts a full bend is worth. `tanh` maps it, because
  # counts have no ceiling: one runaway readout should mean "turn hard", not
  # "turn three hundred degrees". Two spikes: a demonstrator pack of four neurons
  # over a 20 ms window produces counts of that order, and a scale that ignored
  # them would make the base turn the whole of the steering.
  @wish_scale 2.0

  # A saccade: the sides swapped, so the bend is taken twice as hard. A fly pushed
  # left and then right does not ease across. The smoothed wish already has a
  # magnitude, so a crossing is the whole of the condition — doubling a wish that
  # is near zero doubles nothing worth seeing.
  @saccade_gain 2.0

  # How fast it walks. A crawler driven by nothing still shuffles; a crawler with
  # a surface filling its view steps out. In multiples of the four millimetres.
  @min_walk 0.25
  @max_walk 1.5

  # A patch with no relief is the table between the agent and the object: there is
  # nothing in it to learn from, and crawling across it is the long stretch at the
  # start of a run where no theory has any evidence. While the surface is that
  # flat the step is taken `@flight_walk` times over and the bend is damped, so the
  # flat is crossed rather than spiralled around.
  @flat_relief 0.001
  @flight_walk 3.0
  @flight_bend 0.25

  # The ride height of the drive: at 25 mm from a surface, `1/d` is 40 and the
  # drive is 160 Hz, which is the rate flyverse's own world stimulates its
  # sensory population at. It is a gain, not a law.
  @drive_gain 4.0
  @max_hz 400.0

  # flyverse's `MOTOR_TAU_S`: the low-pass its own body applies to a motor
  # read-out before the body acts on it.
  @motor_tau_s 0.030

  # flyverse's `DT_MS`, in seconds: the tick a window is counted in. A plan
  # counts ticks, and the wish is a first-order update over the time they took.
  @tick_seconds 0.0001

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

  The rates are computed from the image, the window is stepped in Rust, and the
  difference of the readout counts is the steering wish. What this function does
  *not* do is decide anything about the world: it decides how hard to drive, and
  the network decides the rest.
  """
  @impl FlyversePlugin.Plugin
  def call(
        %__MODULE__{} = policy,
        {_ctx, observations, _motor_state, percept, _goal},
        state
      ) do
    simulation = Map.fetch!(state.simulations, policy.sim)

    with {:ok, {_sensor_id, rows}} <-
           Percept.image(observations, policy.agent_id, policy.sensor_id),
         {:ok, window} <- step(simulation, rows) do
      previous = simulation.wish
      wish = smoothed(simulation, window.left - window.right)
      result = result(policy, %{previous: previous, wish: wish}, window, percept)

      simulation = %{simulation | wish: wish, spikes: window.spikes, last: window}

      {:ok, result, policy, put(state, policy.sim, simulation)}
    end
  end

  @doc "Starts the next episode at the connectome's resting state."
  @impl FlyversePlugin.Plugin
  def reset(%__MODULE__{} = policy, state) do
    simulation = Map.fetch!(state.simulations, policy.sim)

    case Native.reset(simulation.sim) do
      :ok -> {:ok, policy, put(state, policy.sim, %{simulation | wish: 0.0, spikes: 0})}
      {:error, {code, sentence}} -> {:error, "#{code}: #{sentence}"}
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
           last: %{left: 0, right: 0, spikes: 0, rates: [0.0, 0.0]}
         }}

      {:error, {code, sentence}} ->
        {:error, "#{code}: #{sentence}"}
    end
  end

  defp step(simulation, rows) do
    {left_nearness, right_nearness} = Percept.nearness(rows)
    rates = [rate(left_nearness), rate(right_nearness)]

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

  defp result(policy, %{previous: previous, wish: wish}, window, percept) do
    [left_hz, right_hz] = window.rates
    depth = mean_depth(percept, policy.distance)
    relief = relief(percept)
    flight? = relief == nil or relief < @flat_relief
    turn = turn_degrees(policy, wish, saccade?(previous, wish), flight?)
    walk = if flight?, do: @flight_walk, else: walk_speed(driven(left_hz, right_hz))

    %MotorPolicyResult{
      actions: [crawl(policy, turn, depth, walk)],
      telemetry: %{
        left_hz: left_hz,
        right_hz: right_hz,
        left_spikes: window.left,
        right_spikes: window.right,
        spikes: window.spikes,
        wish: wish,
        turn_degrees: turn,
        mean_depth: depth,
        relief: relief,
        walk_speed: walk
      }
    }
  end

  # Positive is left, because that is how the drives were named. Nothing here
  # ever returns zero: the base turn is added to what the network asks for, so a
  # silent or perfectly balanced network still walks its spiral instead of
  # standing still and gathering the same percept for ever.
  defp turn_degrees(policy, wish, saccade?, flight?) do
    bend = @max_turn_degrees * :math.tanh(wish / @wish_scale)
    bend = if saccade?, do: @saccade_gain * bend, else: bend
    bend = if flight?, do: @flight_bend * bend, else: bend
    limit = @saccade_gain * @max_turn_degrees

    (policy.turn_degrees + bend)
    |> max(-limit)
    |> min(limit)
  end

  # The sides swapped places.
  defp saccade?(previous, wish), do: previous * wish < 0.0

  # How hard the world is driving the network, as a fraction of the rate cap:
  # the same two numbers that made the spikes, so how fast it walks and how it
  # decided where to walk come from one place.
  defp driven(left_hz, right_hz) do
    ((left_hz + right_hz) / (2 * @max_hz))
    |> max(0.0)
    |> min(1.0)
  end

  defp walk_speed(driven), do: @min_walk + (@max_walk - @min_walk) * driven

  # Monty's own surface arithmetic (`SurfacePolicy.distances/2`): a slide whose
  # length the angle and the depth decide, and the press that keeps the sensor at
  # its standoff. `left_distance` is the travel — an angle with no distance is a
  # turn on the spot, which is what made 1275 steps of evidence rise for every
  # object at once — and `walk` is how much of that travel this step takes.
  #
  # The world yaws by `-rotation_degrees`, so a left turn is a negative angle
  # while `left_distance` is positive leftwards.
  defp crawl(policy, turn, depth, walk) do
    radians = rad(abs(turn))

    %OrientHorizontal{
      agent_id: policy.agent_id,
      rotation_degrees: -turn,
      left_distance: walk * sign(turn) * depth * :math.tan(radians),
      forward_distance: depth * (1.0 - :math.cos(radians)) / :math.cos(radians)
    }
  end

  # The percept's own depth, when it carries one. A policy that hears nothing
  # about the surface steps its own four millimetres rather than refusing to walk.
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

  # How much the depths under the patch differ: zero on a flat surface, and the
  # question this policy asks to tell a table from a thing on it.
  defp relief(nil), do: nil

  defp relief(percept) do
    with {:ok, max} when is_number(max) <- Message.feature(percept, "max_depth"),
         {:ok, min} when is_number(min) <- Message.feature(percept, "min_depth") do
      max - min
    else
      _absent -> nil
    end
  end

  defp rad(degrees), do: degrees * :math.pi() / 180.0

  defp sign(value) when value > 0.0, do: 1.0
  defp sign(value) when value < 0.0, do: -1.0
  defp sign(_zero), do: 0.0

  defp rate(nearness), do: min(nearness * @drive_gain, @max_hz)

  defp put(state, key, simulation),
    do: %{state | simulations: Map.put(state.simulations, key, simulation)}
end
