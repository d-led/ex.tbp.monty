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
    {:ex_tbp_monty_core, "~> 0.1.1"}
  ]
end
```

## What is here

| area | modules | what it does |
| --- | --- | --- |
| the loop | `Monty.Runtime.*` | one process per learning and sensor module, a coordinator that steps them, and the barrier that waits for a round |
| hypotheses | `Monty.Frameworks.Models.EvidenceMatching.*` | evidence over a graph, burst sampling, the slope tracker that culls hypotheses |
| learning modules | `Monty.Frameworks.Models.*` | `EvidenceGraphLM`, `DisplacementGraphLM`, `FeatureGraphLM`, the graph memories they match against |
| sensors | `Monty.SensorModules.*` | camera (`CameraSM`), surface-agent sensor (`TwoDSensorModule`), salience (`SalienceSM`) |
| actions | `Monty.Frameworks.Actions.*` | the fourteen actions as structs, and the samplers that draw their parameters |
| motor | `Monty.Frameworks.Models.MotorPolicies.*` | surface, informed, naive-scan and predefined policies |
| the world's side | `Monty.Simulators.Port`, `Monty.Simulators.Environment` | the behaviour a world implements, and a process boundary for one in another language |
| attention | `Monty.Attention.*` | voxel grids, decay, merging and goal filtering |
| maths | `Monty.Geometry.*`, `Monty.Math`, `Monty.Cmp.*` | rotations, orthonormal frames, the messages between modules |

Every module keeps Monty's own name: Python `a/b.py::C` is `Monty.A.B.C` here,
one to one, enforced by the module map in the application that ships with this
package. That is the point of the port — a reader of Monty's source can find the
same file here.

## Driving it

A model is a tree of processes; a host starts them in its own supervisor:

```elixir
children = [
  Monty.Runtime.Registry,
  {DynamicSupervisor, name: Monty.Runtime.ModelSupervisor},
  MyApp.Motor
]
```

Then a step is a call: observations in, actions out. The world is whatever
implements `Monty.Simulators.Environment` — a robot driver, a simulator, or the
stand-in scene this package carries for tests. `examples/` beside the packages
in the repository is a program that does exactly this, and does not use the
studio.

## What is deliberately not here

- The experiment catalogue and Hydra configs — those are the application's, and
  they are what makes a *recognised Monty experiment* rather than a system.
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
