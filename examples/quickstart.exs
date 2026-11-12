# A model of one sensor and one learning module, stepped five times against the
# stand-in world — no studio, no config files, no Python.
#
#   elixir quickstart.exs

Mix.install([{:ex_tbp_monty_core, "~> 0.1.2"}])

alias Monty.Runtime.Model
alias Monty.Simulators.Synthetic.{Environment, LearningModule, Motor, SensorModule}

sensor_id = "patch"

# The processes the core needs — a registry for the modules' names, and a
# supervisor to start models under — in the host's own tree.
{:ok, _} = Supervisor.start_link([ExTbpMonty.Core.Supervisor], strategy: :one_for_one)

# What is being sensed: one sensor, one learning module, one motor policy. The
# `Monty.Simulators.Synthetic.*` modules are stand-ins this package carries so a
# host can drive the loop before it has written its own — a recognition loop
# swaps in `Monty.Frameworks.Models.EvidenceMatching.EvidenceGraphLM` and
# `Monty.SensorModules.SurfaceAgent.TwoDSensorModule` and nothing else changes.
{:ok, _} =
  Model.start_link(%{
    model_id: :demo,
    sensor_modules: [
      %{
        id: sensor_id,
        agent_id: Environment.agent_id(),
        module: SensorModule,
        state: SensorModule.new(sensor_id)
      }
    ],
    learning_modules: [
      %{id: :lm_0, module: LearningModule, state: LearningModule.new(:lm_0)}
    ],
    sm_to_lm: %{lm_0: [sensor_id]},
    motor: {Motor, Motor.new()}
  })

# Monty tells a model whether the episode trains or evaluates before it steps;
# the policy that ends an episode has no reading for a model that was told
# nothing.
:ok = Model.set_experiment_mode(:demo, :eval)

# The world is a value. `step/2` takes the actions the motor system chose and
# answers what the sensors see, where the agent is, and the world afterwards.
world = Environment.new([sensor_id])
context = Monty.Context.new(42)
{observations, proprioceptive_state, world} = Environment.step(world, [])

Enum.reduce(1..5, {world, observations, proprioceptive_state}, fn step, state ->
  {world, observations, proprioceptive} = state

  {:ok, actions, info} = Model.step(:demo, observations, proprioceptive, context)

  chosen = inspect(Enum.map(actions, & &1.__struct__))
  IO.puts("step #{step}: the motor system chose #{chosen} in #{info.duration_us} us")

  {observations, proprioceptive, world} = Environment.step(world, actions)
  {world, observations, proprioceptive}
end)

# What the model thinks it is doing: the counters a policy reads.
status = Model.status(:demo)
IO.puts("after 5 steps: #{status.matching_steps} matching steps, done? #{status.is_done}")
