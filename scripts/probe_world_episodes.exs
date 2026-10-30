# A config's whole eval epoch, running against Monty's own world.
#
#   PYTHON=$(conda info --base)/envs/tbp.monty/bin/python \
#     MIX_ENV=test mix run scripts/probe_world_episodes.exs [experiment] [episodes] [steps]
#
# One episode is not a comparison: Monty's eval epoch walks the target's
# rotations, and the world decides which object and pose each episode starts
# from. So this runs the epoch the way Monty runs it — reset the world, run an
# episode, reset the world again — and prints what each episode concluded and how
# long it took, which is the row Monty writes to its `eval_stats.csv`.
#
# The peer keeps one environment interface for the whole epoch, as Monty's does:
# the first reset opens the epoch, every reset after that closes an episode and
# opens the next, so the objects come in Monty's order from Monty's own seed.
#
# It is a probe: a step costs a Habitat step plus the learning module's matching,
# so ten episodes take minutes, and all of it needs the `tbp.monty` conda env,
# `$MONTY_DATA` and `$MONTY_MODELS`.

alias Monty.Frameworks.Actions.ActionJSONEncoder
alias Monty.Frameworks.Experiments.Seed
alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
alias Monty.Simulators.Port.Environment
alias Monty.Studio.Setup

experiment = Enum.at(System.argv(), 0) || "base_config_10distinctobj_dist_agent"
episodes = Enum.at(System.argv(), 1) |> then(&(&1 && String.to_integer(&1))) || 10
steps = Enum.at(System.argv(), 2) |> then(&(&1 && String.to_integer(&1))) || 60
out = Enum.at(System.argv(), 3)

python = System.get_env("PYTHON") || "python3"
monty_root = System.get_env("MONTY_ROOT") || Path.expand("../../monty-orig", __DIR__)
peer = Path.expand("monty_simulator_peer.py", __DIR__)

{:ok, opened} = Monty.Studio.open(experiment)
setup = opened.setup

IO.puts("experiment: #{experiment}")
IO.puts("findings: #{inspect(Enum.map(setup.findings, & &1.code))}")
IO.puts(String.duplicate("-", 60))

{:ok, world} =
  Environment.start_link(
    command: [python, peer, "--experiment", experiment, "--monty-root", monty_root],
    sensor_ids: ["patch", "view_finder"],
    timeout: 300_000
  )

run_episode = fn episode ->
  :ok = Environment.reset(world)

  model_id = "world-#{episode}"
  spec = Setup.model_spec(setup, model_id)
  module_id = hd(spec.learning_modules).id

  {:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})

  # The world is the environment: the episode loop asks for observations for the
  # actions the model chose, and this is where they come from. What the model
  # asked for is written down as it goes, so a run can be held to Monty's own
  # action sequence step by step rather than only to its last number.
  environment = fn actions ->
    if out do
      record =
        Jason.encode!(%{
          "episode" => episode,
          "actions" => Enum.map(actions, &ActionJSONEncoder.encode/1)
        })

      File.write!(out, record <> "\n", [:append])
    end

    {:ok, observations, proprioceptive_state} = Environment.step(world, actions)
    {observations, proprioceptive_state}
  end

  result =
    Episode.run(model_id, environment,
      mode: :eval,
      max_steps: steps,
      # Monty's experiment reseeds per episode from `episode_seed`; a run that
      # used one seed for the whole epoch would draw the same policy numbers
      # every episode and drift from Monty on the second one.
      seed: Seed.episode_seed(setup.seed, :eval, episode - 1)
    )
  lm = LearningModuleServer.state(Registry.via({:learning_module, model_id, module_id}))

  Model.stop(model_id)

  %{
    episode: episode,
    steps: result.steps,
    terminal: result.terminal_states[module_id],
    detected: lm.detected_object,
    possible: lm.possible_matches
  }
end

Enum.each(1..episodes, fn episode ->
  run = run_episode.(episode)

  IO.puts(
    "episode #{run.episode}: #{run.steps} steps, #{inspect(run.terminal)}, " <>
      "detected #{inspect(run.detected)}, possible #{inspect(run.possible)}"
  )
end)

Environment.stop(world)
