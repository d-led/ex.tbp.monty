# Next session: which of the planned classes does this port need?

Written 2026-11-08, for the session that starts with
`/modules?status=planned`. Nothing here is a verdict yet — it is the state, the
two traps in reading it, and the method that turns the list into one.

## The observation

`mix monty.readiness` (203 experiments in Monty's tree):

| answer                          | count |
| ------------------------------- | ----- |
| runs here                       | 119   |
| waiting for prerequisites       | 0     |
| cannot run here                 | 3     |
| not planned (world not carried) | 81    |

`mix monty.module_map.verify` (131 files, 360 classes):

| status      | classes                                         |
| ----------- | ----------------------------------------------- |
| implemented | 211                                             |
| planned     | 147                                             |
| excluded    | 2 — the conf-only scripts, each with its reason |

The three experiments that cannot run here name **test-only fakes**
(`tests.unit.frameworks.models.fakes.learning_modules.FakeLearningModule`,
`…sensor_modules.FakeSensorModule`, `…profile_experiment_mixin_test.ProfiledExperiment`)
and one whose world holds no object. So no production class blocks any
experiment today — which is the question the next session answers: what are the
147 for?

## What is measured already

147 planned classes across 50 files. The blocks, by size:

| classes | file(s)                                                                                  |
| ------- | ---------------------------------------------------------------------------------------- |
| 28      | `frameworks/actions/actions.py` — the `*ActionSampler` / `*Actuator` pairs               |
| 23      | `simulators/habitat/**` (actions, sensors, agents, actuator, simulator, environment)     |
| 13      | `simulators/mujoco/**` (simulator, agents, objects)                                      |
| 12      | `frameworks/models/**` (abstract_monty_classes, evidence_matching, monty_base, salience) |
| 11      | `frameworks/environments/**`                                                             |
| 8       | `simulators/tacto/config.py`                                                             |
| 15      | `tbp.teleop/**` (GUI: panels, controls, plotter, policies, helpers)                      |
| ~37     | the rest, one to six at a time (loggers, utils, experiment/*, telemetry)                 |

Two measurements, each reproducible:

1. **Named by a config.** Only **11 of the 147** appear as a `_target_` anywhere
   in `monty-orig/src/tbp/monty/conf/**`:

   ```
   simulators/mujoco/agents.py            4
   frameworks/loggers/wandb_handlers.py   2
   experiment/recognition_policy.py       1
   experiment/sensor_modules/telemetry.py 1
   frameworks/sensors.py                  1
   simulators/habitat/sensors.py          1
   teleop/default.py                      1
   ```

2. **Mentioned by other code.** 80 of the 147 are mentioned by no other file in
   `src/tbp/monty`; the most-mentioned are the ones that are not choices but
   shapes:

   | mentions | class                                                       |
   | -------- | ----------------------------------------------------------- |
   | 34       | `frameworks/models/abstract_monty_classes.py::Monty`        |
   | 23       | `context.py::RuntimeContext`                                |
   | 20       | `frameworks/models/abstract_monty_classes.py::Observations` |
   | 13       | `teleop/default.py::Default`                                |
   | 8        | `simulators/mujoco/agents.py::Agent`                        |

## The two traps

- **"No config names it" is not "nothing needs it".** A base class is not a
  choice: `Monty`, `RuntimeContext` and `Observations` are the shape every
  implemented module already has an Elixir counterpart for, and none of them is
  a `_target_`.
- **"Monty has the class" is not "the port must have it".** The 28
  `*ActionSampler`/`*Actuator` pairs are what Python's `simulators/*/agents.py`
  instantiates; here an action is data that crosses `Monty.Simulators.Port`.
  Their absence may be the consequence of a decision already made, and then it
  belongs in the map as `:excluded` with that reason rather than sitting in
  `:planned` for ever.

## The method

For each file in `/tmp/planned.tsv`-style form (or `mix monty.module_map.verify`
output), answer three questions:

1. **Who constructs it?** `grep -rn "_target_:.*<Class>" src/tbp/monty/conf`, and
   the constructor sites in `src/`. If nothing constructs it and nothing of ours
   would, it is a candidate for `:excluded`.
2. **Who would notice its absence here?** `mix monty.readiness --all` names the
   experiments and the classes that stop them. A class no experiment names is not
   blocking — it may still be owed for parity, which is a different claim.
3. **Does TBP still mean to keep the mechanism?** `docs/open-ends.md` harvests
   the roadmap and the forum (`monty_roadmap` in the assistant reads the same
   roadmap data). Already known: _Simplify Simulator Protocol_ is **completed**
   upstream, and the roadmap has no Habitat task — the reason Habitat configs are
   _postponed_ rather than refused (`docs/readiness.md`). Teleop is a matplotlib
   GUI; `docs/module-map.md` already says its landing here is LiveView
   components, so its 15 classes are a decision about drawing, not about maths.

Then one verdict a file, in one of three shapes:

| verdict  | where it goes                                                       |
| -------- | ------------------------------------------------------------------- |
| write it | leave `:planned`, say in the doc which experiment or claim needs it |
| never    | `status: :excluded` in `lib/monty/module_map/data.ex` + `reason:`   |
| postpone | leave `:planned`, say which upstream change would decide it         |

`data.ex` is generated (`mix monty.module_map.gen`); the hand-edits it keeps are
`:excluded` and the reason. `/modules?status=planned` reads the same map, so the
page becomes the answer once the verdicts are in.

## First moves, in this order

1. **`simulators/habitat/**` (23).** The build does not carry the world and
   upstream is dropping it; write the verdict and the reason, and let the 81
   "not planned" experiments keep saying so.
2. **`frameworks/actions/actions.py` (28).** Compare one pair (`MoveForwardActionSampler`
   / `MoveForwardActuator`) against `Monty.Frameworks.Actions.MoveForward` and
   `Monty.Simulators.Port` — does the actuator exist here at all, or is the port
   the actuator?
3. **`simulators/mujoco/**` (13) and `simulators/tacto/config.py` (8).** MuJoCo is
   carried; say which classes of it this build uses and which it replaces.
4. **`tbp.teleop/**` (15).** The GUI half of teleop. `docs/module-map.md` says how
   it lands; decide whether "the class exists" means a LiveView or nothing.

## Ground rules for the session

- The map is the contract: a mapped module is never renamed to a prettier name,
  and `mix monty.module_map.verify` stays green.
- Nothing is stubbed. A class that is not written is `:planned` or `:excluded`
  with a reason, never a stand-in that pretends.
- Tests are translations of Monty's own, one case for one case; a verdict of
  "never" needs its evidence in the commit message, not just in the map.
- `./scripts/reformat.sh`, `./scripts/quality.sh` and `MIX_ENV=test mix dialyzer`
  before the commit; `mix monty.readiness` after, to see the counts move.
