# What the planned classes are for

`mix monty.module_map.verify` counts every class of Monty's tree and says which
of them this application has written. Two of the four answers need nothing
explained — a class whose module is here is `implemented`, and a class that is
here only as far as anything uses it is `partial`
([`partial-classes.md`](partial-classes.md) argues those). Excluded classes are
argued in their map entries. The fourth does:
**70 planned classes in 32 files**, while `mix monty.readiness` says 119 of
Monty's 203 experiments run here and no production class blocks any of them.

This page is the answer, one verdict a file: does this application owe the
class, will it never have it, or does something upstream decide. It replaces the
brief (`next-session.md`) that asked the question.

```
mix monty.module_map.verify     # implemented / partial / planned / excluded, by class
mix monty.readiness             # which experiments run, and what stops the rest
mix monty.module_map.gen        # regenerate after a pull; keeps these decisions
```

## The method

For each file:

1. **Who constructs it?** A `_target_` in Monty's `conf/`, or a constructor site
   in `src/`. Nothing constructs it and nothing here would: it is a candidate for
   `:excluded`.
2. **Who would notice its absence here?** `mix monty.readiness --all` names the
   experiments a class stops. A class no experiment names is not blocking; it may
   still be owed for parity, which is a different claim.
3. **Does TBP still mean to keep the mechanism?** `docs/open-ends.md`, the
   roadmap, and the forum crawl in `ex.tbp.monty.input/posts/`.

Then one verdict, in one of three shapes:

| verdict  | where it goes                                                                |
| -------- | ---------------------------------------------------------------------------- |
| write it | stays `:planned`; this page names the experiment or claim that needs it      |
| never    | `status: :excluded` in `lib/monty/module_map/data.ex` with `reason:`         |
| carry it | stays `:planned` **and** keeps its `stand_in:` — something here runs its job |

`data.ex` is generated. The hand edits it keeps are exactly these decisions:
an excluded entry with its reason, and each excluded class with its own.
`/modules?status=planned` reads the same map, so the page is the answer.

## The rule that made the first four moves one decision

Monty's two simulator packages are **bindings to an engine**: classes that
subclass `habitat_sim`'s controls, wrap its simulator, or build its sensor
specs. Nothing in them is Monty's own arithmetic, and none of it can be written
in Elixir — the engine is C++ and Python.

This application carries exactly one engine, MuJoCo, and carries it as Python in
`priv/monty_py/world.py` behind `Monty.Simulators.Port`. That is why the MuJoCo
classes stay planned **and** keep their stand-in while the Habitat ones are
excluded: the difference is not the kind of code, it is which world this build
steps.

## What was decided (77 classes)

| classes | file(s)                             | verdict | the evidence                                                                                                       |
| ------: | ----------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------ |
|      11 | `simulators/habitat/actions.py`     | never   | `SceneNodeControl` subclasses driving `magnum` scene nodes                                                         |
|       4 | `simulators/habitat/actuator.py`    | never   | habitat-sim's actuator API; here an action crosses `Monty.Simulators.Port`                                         |
|       3 | `simulators/habitat/agents.py`      | never   | habitat-sim agents and scene nodes — the agent belongs to the world                                                |
|       3 | `simulators/habitat/sensors.py`     | never   | builds `habitat_sim.sensor.CameraSensorSpec`s                                                                      |
|       1 | `simulators/habitat/simulator.py`   | never   | a wrapper over `habitat_sim.Simulator`                                                                             |
|       2 | `simulators/habitat/environment.py` | never   | agent configuration nothing here reads (the file's third class is this port's peer handle and stays `implemented`) |
|       1 | `simulators/tacto/agents.py`        | never   | a habitat-sim agent with tacto fingers                                                                             |
|       6 | `simulators/tacto/config.py`        | never   | tacto sensor specs for habitat-sim; no config names tacto                                                          |
|       1 | `simulators/tacto/sensors.py`       | never   | `TactoSensor.get_specs/1` answers `habitat_sim.sensor.CameraSensorSpec`                                            |
|      28 | `frameworks/actions/actions.py`     | never   | the 14 `*ActionSampler` and 14 `*Actuator` classes are `Protocol`s, one signature each                             |
|       2 | `frameworks/experiments/hooks.py`   | never   | `StepHook` is a `Protocol`; `NoOpStepHook` is its no-op, and no config names one                                   |
|      15 | `tbp.teleop/**`                     | never   | matplotlib widgets, panels and draw loops; this app's equivalents are LiveView components and events               |

Totals: **147 planned → 70**, 211 implemented unchanged, 79 excluded. The
counts that matter did not move — `mix monty.readiness` still answers **119 run /
0 waiting / 3 cannot / 81 not planned**, because none of the 77 is named by a
runnable experiment.

### Why the action protocols are excluded, though the actions are written

Monty declares, for each of its fourteen actions, a sampler interface and an
actuator interface:

```python
class MoveForwardActionSampler(Protocol):
    def sample_move_forward(self, agent_id, rng) -> MoveForward: ...

class MoveForwardActuator(Protocol):
    def actuate_move_forward(self, action: MoveForward) -> None: ...
```

There is no code in either: they are the shape a simulator's actuator and a
policy's sampler must have. Here both jobs already have homes —

- sampling is `ConstantSampler` / `UniformlyDistributedSampler`, which answer
  `sample_move_forward/3` and its thirteen siblings (`surface_policy.ex` calls
  them through the sampler's own module);
- acting is the world's: an action is a struct (`Monty.Frameworks.Actions.*`)
  that becomes a map and crosses `Monty.Simulators.Port`.

This is the same verdict the map already gave `ResettableSensorModule` — "a
Protocol for isinstance checks; the port's sensor behaviour already requires
reset/1".

### Why the teleop GUI is excluded, though teleop is not deprecated

`tbp.teleop` is a matplotlib window: a `StepHook` that draws the figure and
waits for a click, buttons, a speed slider, a live plotter, and two policy
adapters that turn a click into an action. It is 3,224 lines across seven
modules, and none of it is about the maths.

This application already draws the same information — the run page's panels,
the per-module chart, the sensor frames, the centre view — with LiveView
components over a run record, and its controls are `phx-click` events. So the
classes are `:excluded` with the counterpart named in each reason, not left
`planned` for a `lib/teleop/` that will never exist. `Monty.ModuleMap`'s own
moduledoc already said it: the namespace exists so a teleop developer can find
the module that _replaces_ what they wrote.

An interactive surface is a feature, not this port of these names. If one is
built, it adds the step seam it needs at that point — a motor policy and a
LiveView event, written from that requirement.

## What is left: 70 planned in 32 files

Of these, **19 are carried and owe nothing**: MuJoCo's simulator, agents and
objects (17), each with `stand_in:` naming `priv/monty_py/world.py`, plus the two
shell classes `Monty` and `MontyBase`, whose job `Monty.Runtime.*` does. They stay
planned on purpose — the counter reaching zero means the other 51 are written,
not that these were renamed.

The **51 owed** fall into five groups:

| classes | files                                                                                            | what it is                                                                                             |
| ------: | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
|      12 | `frameworks/models/abstract_monty_classes.py` (6), `frameworks/environments/environment.py` (6)  | the shapes: two `Dict` typedefs, seven `Protocol`s, three ABCs — the base class is not a config choice |
|       5 | `frameworks/loggers/wandb_handlers.py`                                                           | real code, owed: the transport landed, the handlers did not                                            |
|       6 | `frameworks/environments/two_d_data.py`, `experiment/environment.py`                             | Omniglot and Saccade-on-image — the same question the Habitat verdict answered, one layer up           |
|      11 | `experiment/motor_system.py`, `object_init_samplers.py`, `frameworks/sensors.py`, `telemetry/**` | experiment-side classes a config can name                                                              |
|      17 | one each, across the tree                                                                        | `RuntimeContext`, `MatchCriteria`, `RecognitionConclusion`, `SlicMerge`, `NumpyGraph`, …               |

The first group is the largest and the one the brief warned about: a Protocol is
not a thing to write, it is a thing to _be_. Before excluding them, ask what
would fail if the class vanished — our behaviours (`Monty.Simulators.Environment`,
`Monty.SensorModules.SensorModule`, `Monty.Observations`) are the counterparts,
and the map's reason should name the one that carries the shape.

## Moving a verdict back

The exclusions are data, and `mix monty.module_map.gen` keeps them — that is the
point, and also the trap: a decision once recorded is not revisited by a
regeneration. To reverse one, delete its `reason:` and `status: :excluded` (or
its entry in `data.ex`), run `mix monty.module_map.verify`, and the class returns
to `:planned` or `:implemented` on its own. Nothing in the code reads a status to
decide how to run — `Setup` classifies a config from its own classes — so moving
a verdict changes the map, the page and the counts, and no behaviour.

The evidence behind each one is in the commit that made it, not only here: a
verdict of "never" is a claim about somebody's code, and the proof belongs beside
it.
