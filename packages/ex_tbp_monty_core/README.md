# ExTbpMonty.Core

The Thousand Brains Project's Monty, ported module for module to the BEAM — as
a library you can drive, not only as an experiment runner.

Monty is a sensorimotor inference system: sensors produce observations, learning
modules propose and test hypotheses about what is being sensed, and a motor
system acts on the result. This package is that loop. It carries no database, no
web interface and no Python: what it needs from the outside, a live system
supplies.

```elixir
def deps do
  [
    {:ex_tbp_monty_core, "~> 0.1.3"}
  ]
end
```

## What is here

| area             | modules                                                 | what it does                                                                                                      |
| ---------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| the loop         | `Monty.Runtime.*`                                       | one process per learning and sensor module, a coordinator that steps them, and the barrier that waits for a round |
| hypotheses       | `Monty.Frameworks.Models.EvidenceMatching.*`            | evidence over a graph, burst sampling, the slope tracker that culls hypotheses                                    |
| learning modules | `Monty.Frameworks.Models.*`                             | `EvidenceGraphLM`, `DisplacementGraphLM`, `FeatureGraphLM`, the graph memories they match against                 |
| sensors          | `Monty.SensorModules.*`                                 | camera (`CameraSM`), surface-agent sensor (`TwoDSensorModule`), salience (`SalienceSM`)                           |
| actions          | `Monty.Frameworks.Actions.*`                            | the fourteen actions as structs, and the samplers that draw their parameters                                      |
| motor            | `Monty.Frameworks.Models.MotorPolicies.*`               | surface, informed, naive-scan and predefined policies                                                             |
| the world's side | `Monty.Simulators.Port`, `Monty.Simulators.Environment` | the behaviour a world implements, and a process boundary for one in another language                              |
| attention        | `Monty.Attention.*`                                     | voxel grids, decay, merging and goal filtering                                                                    |
| maths            | `Monty.Geometry.*`, `Monty.Math`, `Monty.Cmp.*`         | rotations, orthonormal frames, the messages between modules                                                       |

Every module keeps Monty's own name: Python `a/b.py::C` is `Monty.A.B.C` here,
one to one, enforced by the module map in the application that ships with this
package. That is the point of the port — a reader of Monty's source can find the
same file here.

## Driving it: a model, a world, five steps

One sensor, one learning module, one motor policy, stepped against the stand-in
world this package carries. Copy it into `quickstart.exs` and run
`elixir quickstart.exs`: it is `examples/quickstart.exs` beside the packages in
the repository, word for word, and it downloads nothing but the package.

```elixir
# A model of one sensor and one learning module, stepped five times against the
# stand-in world — no studio, no config files, no Python.
#
#   elixir quickstart.exs

Mix.install([{:ex_tbp_monty_core, "~> 0.1.3"}])

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
```

```text
step 1: the motor system chose [Monty.Frameworks.Actions.MoveForward] in 658 us
step 2: the motor system chose [Monty.Frameworks.Actions.MoveForward] in 29 us
...
after 5 steps: 0 matching steps, done? false
```

(The microseconds are a laptop's, not a promise; everything else is what the
script prints.)

That is the whole loop of Monty: a step asks every sensor module what it sees,
turns percepts into votes, asks the motor system what to do next, and hands the
actions back to whoever owns the world. What is _in_ it is what a config
decides — `Monty.Simulators.Synthetic.*` are stand-ins this package carries so a
host can drive the loop before it has written its own, and a recognition run
swaps `Monty.Frameworks.Models.EvidenceMatching.EvidenceGraphLM` and
`Monty.SensorModules.SurfaceAgent.TwoDSensorModule` in and changes nothing else
about the shape above.

Two ways to supply a world: implement `Monty.Simulators.Environment` (a value
with `new/1`, `step/2`, `reset/1`) for a simulator in this VM, or put it in
another process — or another language — through `Monty.Simulators.Port`.

### Dependencies and what has to be started

|                |                                                                    |
| -------------- | ------------------------------------------------------------------ |
| `:jason`       | JSON, no application callback                                      |
| `:yaml_elixir` | Monty's configs are YAML; needed only when a config _file_ is read |
| `:rustler`     | build-time only: it compiles `native/` into `priv/native/*.so`     |
| Elixir         | `~> 1.20`                                                          |

**Nothing is started on your behalf.** `:ex_tbp_monty_core` has no application
callback, `:jason` and `:yaml_elixir` have none either, and the only app in the
tree with one (`:yamerl`, under `:yaml_elixir`) starts no processes. The tree
above is one a host writes: `ExTbpMonty.Core.Supervisor` is a child to put in
_your_ supervisor, not a service that starts itself. A release that starts every
dependency therefore starts `:logger` and three libraries, and no supervisor of
this package's.

### Monty's own data is not downloaded here

An experiment needs two things this package does not ship: Monty's Hydra configs
(`conf/experiment/…`) and, for recognition, its pretrained memories (several
gigabytes, from Monty's own releases). The quickstart above needs neither — the
stand-in world and stand-in modules are enough to drive the loop — and a library
that answered what a sensor saw should not decide to fill a disk.

The application beside this package does own that: `Monty.Prerequisites` reads a
manifest of Monty's documented URLs, is idempotent (`present?/1` decides before
anything is fetched, and a fetch already running is joined rather than started
twice), and reports progress on a pub/sub topic. It needs a Phoenix endpoint and
a supervisor of its own, which is the reason it is there and not here.

## What is deliberately not here

- The experiment catalogue and Hydra configs — those are the application's, and
  they are what makes a _recognised Monty experiment_ rather than a system.
- The run store, the web interface and the Python world.
- Anything requiring a database, a web server or a Python interpreter.

## Speed

The hot loops cross into Rust (`native/`): the k-d index, the feature-evidence
kernel, the curvature fit. Every one of them has an Elixir path that is the
reference and the fallback, so a machine without a Rust toolchain runs
everything, slower. `config :ex_tbp_monty_core, native_kernels?: false` forces
the Elixir paths.

## Licence

MPL-2.0. Monty itself is MIT; the copied parts say so where they are copied
(`priv/monty/LICENSE`) and `docs/from-monty.md` in the repository explains what
came from where.
