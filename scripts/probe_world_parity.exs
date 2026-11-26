# Do the two MuJoCo worlds see the same thing, given the same actions?
#
#   MIX_ENV=test mix run --no-start scripts/probe_world_parity.exs [experiment]
#
# The same spec, the same four moves, and every image each step: a world that
# renders differently is a different experiment, and this says which sensor's
# picture differs and by how much.

alias Monty.Frameworks.Actions.MoveForward
alias Monty.Studio
alias Monty.Studio.Setup

experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"

# A picture as three bytes a pixel, which is what MuJoCo's renderer answers and
# what a comparison with Python's own render can be made on.
rgb_bytes = fn rgba ->
  for row <- rgba, pixel <- row, into: <<>> do
    [red, green, blue, _alpha] = pixel
    <<red, green, blue>>
  end
end

# The Python world is a GenServer over an embedded interpreter, and this probe
# starts neither: `--no-start` means the application's supervision tree is not
# running.
# `ex_mujoco`'s library has to be in the process first, which is what the
# application does at boot: two MuJoCo libraries resolve their symbols by load
# order (see `ExTbpMonty.Application.load_the_compiled_world/0`).
_version = ExMujoco.version()

{:ok, _python} = Application.ensure_all_started(:pythonx)
{:ok, _host} = Monty.Simulators.Mujoco.Host.start_link([])

# Which two MuJoCos are being compared. A difference between two versions is not
# a difference between two implementations, and this probe used to print its
# numbers without saying which it had.
IO.puts(
  "comparing: compiled world MuJoCo #{ExMujoco.version()} against Python MuJoCo " <>
    Pythonx.decode(
      elem(Pythonx.eval("str(__import__('mujoco').__version__)", %{}), 0)
    ) <> " (pin #{ExMujoco.mujoco_version()})"
)

{:ok, opened} = Studio.open(experiment, world_simulator: :mujoco)
setup = opened.setup
agent_id = Monty.Simulators.Synthetic.Environment.agent_id()

actions = for _ <- 1..4, do: %MoveForward{agent_id: agent_id, distance: 0.004}

# Four steps of one world: what each sensor saw, and where the agent ended up.
run = fn world_atom ->
  world = setup |> Setup.world(world_atom, 0) |> then(& &1.__struct__.reset(&1))

  Enum.map_reduce(actions, world, fn action, world ->
    {observations, state, world} = world.__struct__.step(world, [action])
    {%{observations: observations[agent_id], state: state[agent_id]}, world}
  end)
  |> elem(0)
end

{steps_of_python, _} = {run.(:mujoco), nil}
{steps_of_nif, _} = {run.(:ex_mujoco), nil}

compare = fn label, theirs, ours ->
  if theirs == ours do
    IO.puts("#{label}: identical")
  else
    case {theirs, ours} do
      {a, b} when is_number(a) and is_number(b) ->
        IO.puts("#{label}: #{a} vs #{b}")

      {a, b} when is_list(a) and is_list(b) ->
        flat_theirs = List.flatten(a)
        flat_ours = List.flatten(b)

        if Enum.all?(flat_theirs ++ flat_ours, &is_number/1) and
             length(flat_theirs) == length(flat_ours) do
          widest =
            Enum.zip(flat_theirs, flat_ours)
            |> Enum.map(fn {x, y} -> abs(x - y) end)
            |> Enum.max()

          differing =
            Enum.count(Enum.zip(flat_theirs, flat_ours), fn {x, y} -> x != y end)

          IO.puts(
            "#{label}: #{differing} of #{length(flat_theirs)} values differ, widest #{widest}"
          )
        else
          IO.puts("#{label}: shapes differ (#{length(flat_theirs)} vs #{length(flat_ours)})")
        end

      {a, b} ->
        IO.puts("#{label}: #{inspect(a)} vs #{inspect(b)}")
    end
  end
end

Enum.zip(steps_of_python, steps_of_nif)
|> Enum.with_index()
|> Enum.each(fn {{theirs, ours}, index} ->
  IO.puts("--- step #{index}")

  for sensor_id <- Map.keys(theirs.observations) do
    for key <- ["depth", "rgba", "semantic"] do
      compare.(
        "#{sensor_id} #{key}",
        theirs.observations[sensor_id][key],
        ours.observations[sensor_id][key]
      )
    end
  end

  compare.("agent position", theirs.state.position, ours.state.position)
  compare.("agent rotation", theirs.state.rotation, ours.state.rotation)

  for {sensor_id, pose} <- theirs.state.sensors do
    compare.("#{sensor_id} pose position", pose.position, ours.state.sensors[sensor_id].position)
    compare.("#{sensor_id} pose rotation", pose.rotation, ours.state.sensors[sensor_id].rotation)
  end

  base = "/tmp/parity/step-#{index}"

  for {sensor_id, seen} <- theirs.observations do
    File.mkdir_p!(base)

    File.write!("#{base}/#{sensor_id}-python.rgb", rgb_bytes.(seen["rgba"]))
    File.write!("#{base}/#{sensor_id}-nif.rgb", rgb_bytes.(ours.observations[sensor_id]["rgba"]))
  end
end)
