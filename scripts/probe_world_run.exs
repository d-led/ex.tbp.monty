# A config's model, running against Monty's own world.
#
#   PYTHON=$(conda info --base)/envs/tbp.monty/bin/python \
#     MIX_ENV=test mix run scripts/probe_world_run.exs [experiment] [steps]
#
# Everything here is the experiment's own: the sensors the config names, the
# learning module with the memory its `model_name_or_path` points at, the motor
# system and its policy, and — for the first time — the world, which is Monty's
# `HabitatEnvironment` behind `Monty.Simulators.Port`. No stand-in is left in
# this path except the ones the port has not written (listed by the setup's
# findings, which this prints).
#
# It is a probe: each step costs a Habitat step plus the learning module's
# matching, and the first start takes about half a minute.

alias Monty.Frameworks.Experiments.Seed
alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
alias Monty.Simulators.Port.Environment
alias Monty.Studio.Setup

experiment = List.first(System.argv()) || "base_config_10distinctobj_dist_agent"
steps = System.argv() |> Enum.at(1) |> then(&(&1 && String.to_integer(&1))) || 8

python = System.get_env("PYTHON") || "python3"
monty_root = System.get_env("MONTY_ROOT") || Path.expand("../../monty-orig", __DIR__)
peer = Path.expand("monty_simulator_peer.py", __DIR__)

{:ok, opened} = Monty.Studio.open(experiment)
setup = opened.setup

IO.puts("experiment: #{experiment}")
IO.puts("findings: #{inspect(Enum.map(setup.findings, & &1.code))}")

model_id = "world-#{System.unique_integer([:positive])}"
spec = Setup.model_spec(setup, model_id)
module_id = hd(spec.learning_modules).id

case Environment.start_link(
       command: [python, peer, "--experiment", experiment, "--monty-root", monty_root],
       sensor_ids: ["patch", "view_finder"],
       timeout: 300_000
     ) do
  {:ok, world} ->
    :ok = Environment.reset(world)
    IO.puts("world: reset")

    {:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})

    # The world is the environment: the episode loop asks for observations for
    # the actions the model chose, and this is where they come from.
    environment = fn actions ->
      {:ok, observations, proprioceptive_state} = Environment.step(world, actions)
      {observations, proprioceptive_state}
    end

    result =
      Episode.run(model_id, environment,
        mode: :eval,
        max_steps: steps,
        seed: Seed.episode_seed(setup.seed, :eval, 0)
      )

    IO.puts("steps: #{result.steps}, timed out: #{result.timed_out?}")
    IO.puts("terminal states: #{inspect(result.terminal_states)}")

    lm = LearningModuleServer.state(Registry.via({:learning_module, model_id, module_id}))
    IO.puts("detected: #{inspect(lm.detected_object)}, possible: #{inspect(lm.possible_matches)}")

    Model.stop(model_id)
    Environment.stop(world)

  {:error, reason} ->
    IO.puts("the world would not start: #{inspect(reason)}")
end
