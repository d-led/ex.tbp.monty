# Module map

The port is only recognisable if a Monty developer can find any file they know.
One rule does that.

## The rule

```
Monty.<CamelCase dirs>.<CamelCase file>.<Class>
```

with two collapses:

* an immediately repeated segment collapses (`frameworks/actions/actions.py`
  → `Monty.Frameworks.Actions`, not `...Actions.Actions`);
* the class is dropped when it repeats the file name
  (`cmp.py::Message` → `Monty.Cmp.Message`, `hypotheses.py::Hypotheses`
  → `Monty.Frameworks.Models.EvidenceMatching.Hypotheses`).

| Python | Elixir |
| --- | --- |
| `cmp.py::Message` | `Monty.Cmp.Message` |
| `geometry.py::SurfacePoseVectors` | `Monty.Geometry.SurfacePoseVectors` |
| `frameworks/models/buffer.py::FeatureAtLocationBuffer` | `Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer` |
| `frameworks/models/abstract_monty_classes.py::Monty` | `Monty.Frameworks.Models.AbstractMontyClasses.Monty` |
| `frameworks/models/evidence_matching/learning_module.py::EvidenceGraphLM` | `Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM` |
| `frameworks/models/motor_policies.py::SurfacePolicy` | `Monty.Frameworks.Models.MotorPolicies.SurfacePolicy` |
| `frameworks/experiments/monty_experiment.py::MontyExperiment` | `Monty.Frameworks.Experiments.MontyExperiment` |
| `frameworks/actions/actions.py::MoveForward` | `Monty.Frameworks.Actions.MoveForward` |
| `sensor_modules/sensor_module.py::SensorModule` | `Monty.SensorModules.SensorModule` |
| `simulators/mujoco/simulator.py::MuJoCoSimulator` | `Monty.Simulators.MuJoCo.Simulator.MuJoCoSimulator` |

The actor layer is the one addition: `Monty.Runtime.*` has no Python
counterpart, because in Python the loop itself is the runtime.

## The map

`priv/monty/module_map.exs` is generated from a checkout:

```bash
mix monty.module_map.gen            # writes the file
mix monty.module_map.verify         # fails on drift
```

Each entry carries the Python path, the Elixir module, a status
(`implemented`, `planned`, `excluded`) and, for exclusions, a reason. The
verifier fails when:

* a Python file in the checkout has no entry;
* an `implemented` entry points at a module that does not exist;
* an `excluded` entry has no reason.

Current state: 124 modules — 2 implemented, 118 planned, 4 excluded (Hydra's own
tooling, superseded by `Monty.Config`).

The generated file's counts are the honest progress bar for the port: the UI
will show per-experiment how much of the config it needs is already
implemented.

## Claiming a module

1. Pick an entry from `priv/monty/module_map.exs`.
2. Create the module at its mapped name.
3. Port the behaviour as pure functions, keeping Monty's vocabulary.
4. Test it — against a Monty fixture when numbers are involved.
5. `mix monty.module_map.gen && mix monty.module_map.verify`.
6. `scripts/quality.sh`.

Marking something `excluded` is allowed; leaving it unexplained is not.
