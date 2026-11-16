# Where does our action stream leave Monty's?
#
#   MIX_ENV=test mix run --no-start scripts/probe_action_stream.exs [experiment] [steps]
#
# Everything else has been measured and agrees: his percepts are ours bit for bit
# when the world is given his actions (`probe_percept_parity.exs`), and his filter
# reaches his verdicts on them (`probe_read_rate.exs`). So what decides the cost of
# a run — how often a percept is worth matching — is the action stream. This asks
# the experiment's own motor system and surface policy what they would do at every
# step of his episode, while the world is moved by *his* actions, so both answers
# answer the same question. The step they part at is the step to read.
#
# What it reads before that: the patch's own view. On the first step ours is 4096
# pixels at a flat five centimetres with no semantic id on any of them — the table
# beside the object — where his episode opens with the object 6.1 cm into the
# patch. So the streams part at step 1 for a reason that is not the policy: the
# positioning procedure that puts Monty's agent where his episode starts has not
# put ours in the same place, and no comparison of actions means anything until it
# has. The finding is the probe's, and it is why the first line of the report is
# the observation rather than a verdict.

defmodule ActionStream do
  @moduledoc false

  alias Monty.Cmp
  alias Monty.Experiment.Environment.Interface
  alias Monty.Frameworks.Actions.{MoveForward, MoveTangentially, OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Models.MotorSystem
  alias Monty.Frameworks.Models.SensorModules.CameraSM
  alias Monty.Runtime.Positioning
  alias Monty.Studio
  alias Monty.Studio.Setup

  @agent "agent_id_0"
  @channel "patch"
  @fixture "test/fixtures/monty_base_10simobj_episode.jsonl"

  # A micro-metre and a microdegree: what a policy or a filter could see is
  # millimetres and degrees, so what is below this is float arithmetic on the way.
  @tolerance 1.0e-6

  def main do
    experiment = System.argv() |> Enum.at(0) || "base_10simobj_surf_agent"
    steps = System.argv() |> Enum.at(1, "10") |> String.to_integer()

    recorded = read() |> Enum.take(steps)

    # The Python world is a GenServer over an embedded interpreter, and a probe
    # runs with `--no-start`, so the two pieces it needs are started here.
    {:ok, _python} = Application.ensure_all_started(:pythonx)
    {:ok, _host} = Monty.Simulators.Mujoco.Host.start_link([])

    {:ok, opened} = Studio.open(experiment, world_simulator: :mujoco)
    setup = opened.setup

    {:ok, sensor_module} =
      CameraSM.from_config(Enum.find(setup.sensors, &(&1.id == @channel)).config)

    # The transforms are the run's own, and so is the way the world is stepped:
    # `Interface.step/2` also tells the world *which* sensors to render, which
    # `DepthTo3DLocations` needs to find a surface at all.
    interface =
      Interface.new(
        env: setup |> Setup.world(0) |> then(& &1.__struct__.reset(&1)),
        transforms: Setup.built_transforms(setup),
        seed: setup.seed || 0
      )

    # And the episode starts where a run starts it, not where the scene's own
    # reset leaves the arm: Monty's `pre_episode` positions the agent at
    # `desired_object_distance` from its object before the first step, and an
    # agent that has not been positioned looks at the floor — a patch with no
    # pixel on an object, so the first action compared would be the policy's
    # answer to scenery.
    {:ok, factories} = Setup.positioning_procedures(setup)

    {:ok, interface, _positioning} =
      Positioning.prepare(
        factories,
        Setup.target_semantic_id(setup, 0),
        interface,
        fn interface, actions -> Interface.step(interface, actions) end,
        distractors: Setup.distractors(setup)
      )

    # The episode's own stream, which is what a policy draws from in a run:
    # without it the probe would be asking the policy a different question from
    # the one a run asks.
    {:ok, _registry} = Registry.start_link(keys: :unique, name: Monty.Runtime.Registry)
    model_id = "probe-#{System.unique_integer([:positive])}"
    {:ok, _stream} = Monty.Random.Stream.start_link(%{model_id: model_id, seed: setup.seed || 0})

    {observations, proprioceptive_state, interface} = Interface.step(interface, [])

    # What the patch was handed on the first step. A percept with no pixel on an
    # object has two very different causes — a sensor that rendered nothing, and
    # a surface the transform refused — and an action alone cannot say which.
    describe_observation(observations[@agent][@channel])

    state = %{
      interface: interface,
      motor: MotorSystem.from_config(setup.motor_system_config),
      observations: observations,
      proprioceptive_state: proprioceptive_state,
      sensor_module: sensor_module,
      model_id: model_id,
      rows: []
    }

    seed = setup.seed || 0

    # The replay stops at an episode boundary: the experiment repositions the
    # agent between episodes with an action the policy never takes, so a step
    # past it would ask the policy a question about a body that was moved for it.
    {steps, boundary?} =
      recorded
      |> Enum.reduce_while({[], false}, fn recorded_step, {steps, _boundary} ->
        if positioned?(recorded_step),
          do: {:halt, {Enum.reverse(steps), true}},
          else: {:cont, {[recorded_step | steps], false}}
      end)

    rows =
      steps
      |> Enum.reduce(state, fn recorded_step, state -> step(recorded_step, state, seed) end)
      |> Map.fetch!(:rows)
      |> Enum.reverse()

    report(rows)
    if boundary?, do: IO.puts("(the replay stopped where the experiment moved the agent)")
  end

  # One step, his and ours: his percept through our sensor, our policy's answer,
  # then the world moved by his action so the next question is the same one.
  defp step(recorded, state, seed) do
    ctx = %{Monty.Context.new(seed) | rng: Monty.Random.Stream.via(state.model_id)}

    sensor_module = CameraSM.update_state(state.proprioceptive_state[@agent], state.sensor_module)

    {percept, sensor_module} =
      CameraSM.step(
        state.observations[@agent][@channel],
        MotorSystem.motor_only_step(state.motor),
        ctx,
        sensor_module
      )

    {actions, motor} =
      MotorSystem.call(state.motor, ctx, state.observations, state.proprioceptive_state, percept, [])

    # The world moves by his action, so the next question is the same one.
    {observations, proprioceptive_state, interface} =
      Interface.step(state.interface, Enum.map(recorded["actions"], &action/1))

    %{
      state
      | rows:
          [{recorded["episode_step"], Enum.map(recorded["actions"], &describe/1),
            Enum.map(actions, &describe/1), inputs(percept)} | state.rows],
        motor: motor,
        sensor_module: sensor_module,
        observations: observations,
        proprioceptive_state: proprioceptive_state,
        interface: interface
    }
  end

  # What our policy had to go on at that step. Two steps can differ for two
  # different reasons — a percept that says the object is somewhere else, or a
  # policy that reads the same percept another way — and the action alone does
  # not say which. `min_depth` is the number `move_forward` is built from
  # (`min_depth - desired_object_distance`), so a stream that keeps answering
  # `move_forward` while his answers zero shows here as a depth that does not
  # close, rather than as a puzzle.
  defp inputs(percept) do
    %{
      min_depth: feature(percept, "min_depth"),
      coverage: feature(percept, "object_coverage"),
      on_object: Cmp.Message.on_object?(percept)
    }
  end

  defp feature(percept, name) do
    case Cmp.Message.feature(percept, name) do
      {:ok, value} -> value
      {:error, _absent} -> nil
    end
  end

  defp report(rows) do
    Enum.each(rows, fn {step, theirs, ours, inputs} ->
      agree? = same?(theirs, ours)

      IO.puts(
        "#{String.pad_leading(to_string(step), 3)}  his:  #{render(theirs)}\n" <>
          "     ours: #{render(ours)}#{if agree?, do: "  (the same act)", else: "  <- differs"}" <>
          "   #{render_inputs(inputs)}"
      )
    end)

    case Enum.find(rows, fn {_step, theirs, ours, _inputs} -> not same?(theirs, ours) end) do
      nil ->
        IO.puts("\nevery one of #{length(rows)} steps is his act")

      {step, _theirs, _ours, inputs} ->
        IO.puts("\nthe streams part at step #{step}")
        IO.puts("  our percept there: #{render_inputs(inputs)}")
    end
  end

  defp render_inputs(inputs) do
    "[min_depth=#{render_value(inputs.min_depth)} coverage=#{render_value(inputs.coverage)} " <>
      "on_object=#{inputs.on_object}]"
  end

  # What the sensor module is given, before it is asked to make a percept of it.
  # The keys are the answer: a patch that arrives with `depth` can be turned into
  # points and a mask here, and one that arrives with the transform's own
  # `point`/`distance`/`on_surface` instead is a surface already found — or a
  # surface the transform found nothing in.
  defp describe_observation(patch) when is_map(patch) do
    depth = Map.get(patch, "depth") || Map.get(patch, :depth)

    depth =
      if is_list(depth) do
        flat = List.flatten(depth)
        "#{length(flat)} pixels, #{Enum.count(flat, &(&1 == 0.0))} of them zero, " <>
          "max #{Enum.max(flat)}, min on surface #{Enum.min(flat)}"
      else
        "none"
      end

    IO.puts("the patch on the first step: depth #{depth}; keys #{inspect(Map.keys(patch))}")
  end

  defp describe_observation(other),
    do: IO.puts("the patch on the first step: #{inspect(other, limit: 3)}")

  defp same?(theirs, ours) do
    length(theirs) == length(ours) and
      Enum.zip(theirs, ours)
      |> Enum.all?(fn {{their_name, their_values}, {our_name, our_values}} ->
        their_name == our_name and Map.keys(their_values) == Map.keys(our_values) and
          Enum.all?(their_values, fn {key, value} -> close?(value, our_values[key]) end)
      end)
  end

  defp close?(theirs, ours) when is_number(theirs) and is_number(ours),
    do: abs(theirs - ours) <= @tolerance

  defp close?(theirs, ours) when is_list(theirs) and is_list(ours),
    do: length(theirs) == length(ours) and Enum.zip(theirs, ours) |> Enum.all?(fn {a, b} -> close?(a, b) end)

  defp close?(theirs, ours), do: theirs == ours

  # An action as its name and the numbers that decide where it goes, from a
  # struct this port chose or a map the recording kept.
  defp describe(%MoveForward{distance: distance}), do: {"move_forward", %{"distance" => distance}}

  defp describe(%MoveTangentially{distance: distance, direction: direction}),
    do: {"move_tangentially", %{"distance" => distance, "direction" => direction}}

  defp describe(%OrientHorizontal{} = action),
    do:
      {"orient_horizontal",
       %{"rotation_degrees" => action.rotation_degrees, "left_distance" => action.left_distance,
         "forward_distance" => action.forward_distance}}

  defp describe(%OrientVertical{} = action),
    do:
      {"orient_vertical",
       %{"rotation_degrees" => action.rotation_degrees, "down_distance" => action.down_distance,
         "forward_distance" => action.forward_distance}}

  defp describe(%{"action" => name} = recorded), do: {name, Map.drop(recorded, ["action", "agent_id"])}
  defp describe(other), do: {inspect(other), %{}}

  defp render(actions), do: Enum.map_join(actions, " + ", fn {name, values} -> name <> render_values(values) end)

  defp render_values(values) when map_size(values) == 0, do: ""

  defp render_values(values),
    do: " " <> (values |> Enum.sort() |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{render_value(value)}" end))

  defp render_value(nil), do: "none"
  defp render_value(value) when is_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 9)
  defp render_value(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &render_value/1) <> "]"
  defp render_value(value), do: inspect(value)

  defp read do
    Path.expand(@fixture, Path.join(__DIR__, "..")) |> File.stream!() |> Enum.map(&Jason.decode!/1)
  end

  defp positioned?(%{"actions" => actions}),
    do: Enum.any?(actions, &(&1["action"] == "set_agent_pose"))

  defp action(%{"action" => "move_forward"} = recorded),
    do: %MoveForward{agent_id: @agent, distance: recorded["distance"]}

  defp action(%{"action" => "move_tangentially"} = recorded),
    do: %MoveTangentially{agent_id: @agent, distance: recorded["distance"], direction: recorded["direction"]}

  defp action(%{"action" => "orient_horizontal"} = recorded),
    do: %OrientHorizontal{
      agent_id: @agent,
      rotation_degrees: recorded["rotation_degrees"],
      left_distance: recorded["left_distance"],
      forward_distance: recorded["forward_distance"]
    }

  defp action(%{"action" => "orient_vertical"} = recorded),
    do: %OrientVertical{
      agent_id: @agent,
      rotation_degrees: recorded["rotation_degrees"],
      down_distance: recorded["down_distance"],
      forward_distance: recorded["forward_distance"]
    }
end

ActionStream.main()
