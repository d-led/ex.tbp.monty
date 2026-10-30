# Monty's own world, on the other side of the port.
#
#   MIX_ENV=test mix run scripts/probe_simulator_peer.exs [experiment]
#
# `scripts/monty_simulator_peer.py` runs Monty's `HabitatEnvironment` and the
# experiment's environment interface — the world a Monty experiment actually
# names, not a stand-in — and answers `Monty.Simulators.Port.Protocol`. This
# starts it from Elixir, resets it the way an episode starts, takes one step and
# prints what came back: the first time the BEAM has looked at Monty's world
# through its own eyes rather than through a recording.
#
# It starts a Python process and Habitat, so it takes about half a minute and is
# a probe, not a test.
#
# What is missing: the proprioceptive state comes back as Monty's own maps
# (`position`, `rotation` as a `wxyz` quaternion, `sensors`), and the port's
# motor system works in `AgentState` and `SensorState` structs. Decoding the
# reply into those is the next step; until it lands this probe stops after the
# step and says so.

alias Monty.Simulators.Port.Environment

experiment = List.first(System.argv()) || "base_config_10distinctobj_dist_agent"

python = System.get_env("PYTHON") || "python3"
monty_root = System.get_env("MONTY_ROOT") || Path.expand("../../monty-orig", __DIR__)
peer = Path.expand("monty_simulator_peer.py", __DIR__)

shape = fn
  value when is_list(value) -> "#{length(value)}"
  value -> inspect(value)
end

# What came back, as shapes rather than values: enough to see that Monty's world
# answered, without printing four thousand pixels.
report = fn
  {:ok, observations, proprioceptive_state}, shape ->
    for {agent_id, sensors} <- Enum.sort(observations),
        {sensor_id, observation} <- Enum.sort(sensors) do
      fields =
        observation
        |> Enum.sort()
        |> Enum.map_join(", ", fn {name, value} -> "#{name} #{shape.(value)}" end)

      IO.puts("  #{agent_id}/#{sensor_id}: #{fields}")
    end

    IO.puts("proprioception: #{inspect(Map.keys(proprioceptive_state))}")

  {:error, reason}, _shape ->
    IO.puts("step failed: #{inspect(reason)}")
end

case Environment.start_link(
       command: [python, peer, "--experiment", experiment, "--monty-root", monty_root],
       sensor_ids: ["patch", "view_finder"],
       timeout: 300_000
     ) do
  {:ok, world} ->
    IO.puts("started #{experiment}")

    case Environment.reset(world) do
      :ok ->
        report.(Environment.step(world, []), shape)

      {:error, reason} ->
        IO.puts("reset failed: #{inspect(reason)}")
    end

    Environment.stop(world)

  {:error, reason} ->
    IO.puts("the world would not start: #{inspect(reason)}")
end
