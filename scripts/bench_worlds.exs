# What a step costs in each of the two MuJoCo worlds.
#
#   MIX_ENV=test mix run --no-start scripts/bench_worlds.exs [experiment] [steps]
#
# The world is one part of a step — the model's matching is the rest — so this
# measures the part the two worlds differ in: write the poses, forward, render
# every sensor, decode the images to the lists a sensor module reads. Both worlds
# are given the same spec and the same actions, interleaved, because this
# machine's wall clock drifts by tens of percent between one run and the next and
# only a paired measurement means anything.
#
# Read the numbers as a ratio, not as an absolute: the world is a small part of
# an episode, and a run's length is mostly the episodes that spend their whole
# budget (docs/speed.md).

alias Monty.Frameworks.Actions.MoveForward
alias Monty.Studio
alias Monty.Studio.Setup

experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"
steps = System.argv() |> Enum.at(1) |> then(&(if &1, do: String.to_integer(&1), else: 40))

# Both worlds read `ex_mujoco`'s library, and one of them carries MuJoCo itself:
# load the compiled one first, as the application does at boot.
_version = ExMujoco.version()

{:ok, opened} = Studio.open(experiment, world_simulator: :mujoco)
setup = opened.setup
agent_id = Monty.Simulators.Synthetic.Environment.agent_id()

actions = for _ <- 1..steps, do: %MoveForward{agent_id: agent_id, distance: 0.004}

# One world, stepped `steps` times, answering what it cost.
cost = fn world_atom ->
  world = setup |> Setup.world(world_atom, 0) |> then(& &1.__struct__.reset(&1))

  {reductions, _} = :erlang.statistics(:reductions)
  {time, _world} =
    :timer.tc(fn ->
      Enum.reduce(actions, world, fn action, world ->
        {_observations, _state, world} = world.__struct__.step(world, [action])
        world
      end)
    end)

  {reductions_after, _} = :erlang.statistics(:reductions)

  %{
    us_per_step: time / steps,
    reductions_per_step: (reductions_after - reductions) / steps
  }
end

# Warm both paths once, so the first step's compilation is not in the numbers.
_ = cost.(:mujoco)
_ = cost.(:ex_mujoco)

rounds =
  for _ <- 1..3 do
    %{mujoco: cost.(:mujoco), ex_mujoco: cost.(:ex_mujoco)}
  end

for world <- [:mujoco, :ex_mujoco] do
  times = Enum.map(rounds, & &1[world].us_per_step)
  reductions = Enum.map(rounds, & &1[world].reductions_per_step)

  IO.puts(
    "#{world}: #{Float.round(Enum.min(times), 1)}–#{Float.round(Enum.max(times), 1)} µs a step, " <>
      "#{round(Enum.min(reductions))}–#{round(Enum.max(reductions))} reductions"
  )
end

pairs = Enum.map(rounds, fn round -> round.ex_mujoco.us_per_step / round.mujoco.us_per_step end)

IO.puts(
  "ex_mujoco / mujoco: #{Float.round(Enum.min(pairs), 2)}–#{Float.round(Enum.max(pairs), 2)}× the wall"
)
