# The planned classes

`mix monty.module_map.verify` counts Monty's classes and says which ones this app
has written.

Two of its answers are obvious:

- `implemented` — the module is here.
- `partial` — here, as far as anything uses it ([`partial-classes.md`](partial-classes.md)).

Excluded classes carry their reason in the map. This page is about **`planned`**.

## Get the numbers. Don't quote them.

```shell
mix monty.module_map.verify                                  # the counts
MIX_ENV=test mix run --no-start scripts/planned_classes.exs  # which, and what they cost
```

`Monty.ModuleMap.Data.sources/0` names the Monty commit the map was read from.

## Short answer

**Most planned classes are named by no config.** No `_target_` under
`priv/monty/conf/` points at them. They cannot stop a run.

Four groups:

- **Shapes** — Protocols, ABCs, base classes: `Observations`, `Monty`, `MontyBase`,
  the `Environment` hierarchy. In Elixir they are behaviours, structs or maps.
- **Records** — dataclasses a config fills in: `ObjectInitParams`, `LoggerArgs`,
  `Resolution2D`, `TelemetrySchema`. A config is a map here.
- **Dev tools** — `LivePlotter`, `PolicyPlot`, `JsonFormatter`, `SlicMerge`, Monty's
  own test doubles. The studio's pages replace them.
- **2-D and Omniglot** — `Omniglot*`, `SaccadeOnImage*`. Their world is not carried,
  so `mix monty.readiness` calls them `not_planned`.

## The few a config does name

| class                        | named by                    | what happens                                                       |
| ---------------------------- | --------------------------- | ------------------------------------------------------------------ |
| MuJoCo agents, `SensorConfig` | every MuJoCo environment    | Runs — as Monty's Python in `priv/monty_py/world.py`. On purpose.   |
| two wandb handlers           | two logging groups          | Skipped by name. A note in the run log, not a refusal.              |
| `…telemetry.Snapshot`        | the `camera_*` / `3sm_*` groups | Not built. That sensor falls back to the stand-in. Telemetry only. |
| `Any`, `MatchCriteria`       | every training config       | **Do not build. The run refuses.**                                  |

## The two that stop runs

Monty renamed `AnyPolicy` to `Any`, and its option `policies` to `strategies`.
The port still has the old name and option. It has no `MatchCriteria` at all.

So this termination fails:

```yaml
recognition_strategy:
  _target_: …MinEvalMaxTotalSteps
  wrapped:
    _target_: …Any
    strategies: [ …StepLimit …, …MatchCriteria ]
```

`Setup.recognition_strategy/1` answers:

    {:error, "no recognition policy named Any"}

and `Run.start/2` refuses the episode.

`mix monty.readiness` does not check this. It looks at worlds and module classes.
So the page offers these runs, and the worker refuses them.

**Treat "runs here" as an upper bound until this is fixed.**
`scripts/planned_classes.exs` lists the configs.

The fix is small:

- `Any` — the existing `AnyPolicy`, renamed, taking `strategies`.
- `MatchCriteria` — new. It reads a model's `match_criterion`, whose classes
  already exist and are implemented.
- Spec — Monty's own tests, translated case for case.

## Excluded classes

Already argued in the map. Three groups:

- **Action Protocols** (`*ActionSampler`, `*Actuator`) — one signature each, no code.
- **`tbp.teleop`** — a matplotlib window. The studio's pages replace it.
- **Experiment hooks and abstract bases** — `StepHook`, `NoOpStepHook`, the two
  `sensor_module.py` bases.

**Habitat and tacto are not in the map at all.** Monty deleted the sources; only
`__pycache__` is left. A Habitat config is still refused at open time
(`:world_not_carried`).

## Changing a verdict

Exclusions are data. `mix monty.module_map.gen` keeps them.

To reverse one:

1. Delete its `reason:` and `status: :excluded` in
   [`data.ex`](../packages/ex_tbp_monty_core/lib/monty/module_map/data.ex).
2. Run `mix monty.module_map.verify`.

The class returns to `planned` or `implemented`. No behaviour changes — `Setup`
reads a config, not the map.

A verdict of "never" is a claim about someone's code. Keep the proof beside it:
`git log -S'<phrase you remember>'` finds it.

A class on a running path, like `Any`, is not a verdict. It is a defect.
