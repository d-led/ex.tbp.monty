# The studio's own run path, against Monty's own world.
#
#   PYTHON=$(conda info --base)/envs/tbp.monty/bin/python \
#     mix run scripts/probe_world_studio_run.exs [experiment] [steps]
#
# `probe_world_run.exs` and `probe_world_episodes.exs` drive the port directly,
# because they want a step function and an epoch of resets. This one asks the
# question a reader of the studio asks instead: does *the page's* path work when
# the world is Monty's? So it sets `world_simulator: :habitat` the way an
# operator would, opens the experiment, starts a run and steps it.
#
# What it proves, in order: `Setup.world/1` built `HabitatEnvironment`, the
# peer named Monty's checkout and was started on the first step, the experiment's
# positioning procedure ran in the real scene, the sensors came back with depth
# frames each step, and the learning module put its hypotheses on a graph.
#
# It is a probe: a step costs a Habitat step plus the learning module's matching,
# and the scene takes half a minute to build, so nothing here is a test.

alias Monty.Studio

experiment = List.first(System.argv()) || "base_config_10distinctobj_dist_agent"
steps = System.argv() |> Enum.at(1) |> then(&(&1 && String.to_integer(&1))) || 3

Application.put_env(:ex_tbp_monty, :world_simulator, :habitat)

if python = System.get_env("PYTHON") do
  Application.put_env(:ex_tbp_monty, :monty_peer, python: python)
end

{:ok, opened} = Studio.open(experiment)
setup = opened.setup

IO.puts("experiment: #{setup.name}")
IO.puts("world: #{inspect(setup.world)}")
IO.puts("model: #{inspect(Studio.Setup.model_class(setup))}")
IO.puts("findings: #{inspect(Enum.map(setup.findings, & &1.code))}")
IO.puts("peer: #{inspect(Studio.Setup.world(setup).command)}")
IO.puts(String.duplicate("-", 60))

{:ok, run} = Studio.Run.start(setup, steps: steps)
IO.puts("episode seed: #{run.episode_seed}")
IO.puts("positioning: #{inspect(run.positioning)}")

run =
  Enum.reduce(1..steps, run, fn _step, run ->
    {:ok, info, observations, run} = Studio.Run.step(run)
    seen = Map.get(observations, "agent_id_0", %{})

    patch = get_in(seen, ["patch", "depth"])

    IO.puts(
      "step #{info.step} #{info.step_type}: #{inspect(Map.keys(seen))} " <>
        "patch #{inspect(patch && {length(patch), length(hd(patch))})}"
    )

    run
  end)

for {module_id, belief} <- Studio.Run.beliefs(run) do
  hypotheses = belief.graphs |> Map.values() |> Enum.map(& &1.hypotheses) |> Enum.sum()

  IO.puts(
    "#{module_id}: mlh #{inspect(belief.mlh && belief.mlh.graph_id)} " <>
      "ev #{inspect(belief.mlh && belief.mlh.evidence)} " <>
      "hyps #{hypotheses} possible #{inspect(belief.possible_matches)}"
  )
end

IO.inspect(Studio.Run.decision(run), label: "decision")
Studio.Run.stop(run)
IO.puts("stopped")
