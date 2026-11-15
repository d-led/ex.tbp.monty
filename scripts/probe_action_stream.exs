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

defmodule ActionStream do
  @moduledoc false

  alias Monty.Experiment.Environment.Interface
  alias Monty.Frameworks.Actions.{MoveForward, MoveTangentially, OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Models.MotorSystem
  alias Monty.Frameworks.Models.SensorModules.CameraSM
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

    world = setup |> Setup.world(0) |> then(& &1.__struct__.reset(&1))

    # The transforms are the run's own. The world is stepped here rather than
    # through `Interface.step`, because a probe gives it *his* action and reads
    # what the sensor made of it.
    interface =
      Interface.new(
        env: world,
        transforms: Setup.built_transforms(setup),
        seed: setup.seed || 0
      )

    {observations, proprioceptive_state, world} = world.__struct__.step(world, [])
    observations = Interface.apply_transforms(interface, observations, proprioceptive_state)

    state = %{
      interface: interface,
      motor: MotorSystem.from_config(setup.motor_system_config),
      observations: observations,
      proprioceptive_state: proprioceptive_state,
      sensor_module: sensor_module,
      world: world,
      rows: []
    }

    seed = setup.seed || 0

    rows =
      recorded
      |> Enum.reduce(state, fn recorded_step, state -> step(recorded_step, state, seed) end)
      |> Map.fetch!(:rows)
      |> Enum.reverse()

    report(rows)
  end

  # One step, his and ours: his percept through our sensor, our policy's answer,
  # then the world moved by his action so the next question is the same one.
  defp step(recorded, state, seed) do
    ctx = Monty.Context.new(seed)

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

    {actions, motor} =
      MotorSystem.call(state.motor, ctx, state.observations, state.proprioceptive_state, percept, [])

    IO.puts(
      "  percept: pose=#{inspect(percept.morphological_features["pose_fully_defined"])} " <>
        "pc=#{inspect(percept.non_morphological_features["principal_curvatures"])} " <>
        "pc_log=#{inspect(percept.non_morphological_features["principal_curvatures_log"])} " <>
        "pose_vectors=#{inspect(percept.morphological_features["pose_vectors"])}"
    )

    IO.puts(
      "  heading: angle=#{inspect(motor.policy_selector.policy.tangential_angle)} " <>
        "vec=#{inspect(motor.policy_selector.policy.tangential_vec)} " <>
        "rotation=#{inspect(state.proprioceptive_state[@agent].rotation)}"
    )

    {observations, proprioceptive_state, world} =
      state.world.__struct__.step(state.world, Enum.map(recorded["actions"], &action/1))

    %{
      state
      | rows: [{recorded["episode_step"], Enum.map(recorded["actions"], &describe/1), Enum.map(actions, &describe/1)} | state.rows],
        motor: motor,
        sensor_module: sensor_module,
        observations: Interface.apply_transforms(state.interface, observations, proprioceptive_state),
        proprioceptive_state: proprioceptive_state,
        world: world
    }
  end

  defp report(rows) do
    Enum.each(rows, fn {step, theirs, ours} ->
      agree? = same?(theirs, ours)

      IO.puts(
        "#{String.pad_leading(to_string(step), 3)}  his:  #{render(theirs)}\\n" <>
          "     ours: #{render(ours)}#{if agree?, do: "  (the same act)", else: "  <- differs"}"
      )
    end)

    case Enum.find(rows, fn {_step, theirs, ours} -> not same?(theirs, ours) end) do
      nil -> IO.puts("\\nevery one of #{length(rows)} steps is his act")
      {step, _theirs, _ours} -> IO.puts("\\nthe streams part at step #{step}")
    end
  end

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

  defp render_value(value) when is_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 9)
  defp render_value(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &render_value/1) <> "]"
  defp render_value(value), do: inspect(value)

  defp read do
    Path.expand(@fixture, Path.join(__DIR__, "..")) |> File.stream!() |> Enum.map(&Jason.decode!/1)
  end

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
