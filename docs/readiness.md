# Which experiments run here, and what the rest need

`mix monty.readiness` opens every experiment Monty ships and says what stops
each one. This page explains how to read its answer. Re-run the command rather
than quoting its numbers: a class that lands moves every row, and so does a pull
from Monty (`mix monty.refresh` does the pull, the copy and this).

```
mix monty.readiness            # the counts and the class ranking
mix monty.readiness --all      # ...and every experiment that does not run, with its reasons
mix monty.readiness --world synthetic
mix monty.readiness --json /tmp/readiness.json
```

The experiments page (`/experiments`) shows the same answer as its first facet,
**Runs here?** `Monty.Studio.Readiness.catalog/1` is the one place it is
computed. It is cached until the catalogue, the libraries on the machine or the
configured world moves.

## Four answers

| answer                      | meaning                                                                          |
| --------------------------- | -------------------------------------------------------------------------------- |
| `runs here`                 | no finding stops it                                                              |
| `waiting for prerequisites` | every finding is a file a download fills — nothing about this port is in the way |
| `cannot run here`           | something this port is missing: a class, a library, a setting it cannot resolve  |
| `not planned`               | its **world** is one this build does not carry                                   |

`waiting for prerequisites` is separate from `cannot run here` because the two
are different facts. A run whose objects are still downloading is not a run whose
class this port never wrote. The finding is an error, and the run does not start,
but it carries the download: the message says the run is waiting, and the link
goes to `/prerequisites?fetch=<archive>`, which starts it.

## A world is what steps the scene; an environment is the config's own

Three questions were being asked as one, and the third is nobody's to ask:

- **the world** is what steps a scene: MuJoCo through the interpreter this
  application carries, MuJoCo through the compiled binding `ex_mujoco`, or
  Monty's own stand-in. A MuJoCo config steps on this deployment's engine.
- **the environment** is the config's own, read out of its tree: a captured
  scene (`SaccadeOnImageEnvironment`), a drawing (`OmniglotEnvironment`), a MuJoCo
  scene. A captured scene is its own world, because no simulator steps it.
  Offering such a config MuJoCo, and then refusing it, read as "cannot run here"
  about experiments that run.
- **the input** is the data a config names: the captures under
  `worldimages/bright_scenes`, the Omniglot dataset, a CAD part. It is not a
  choice — a different set is a different experiment — so the page shows it
  instead of offering it.

`--world` is an override, and the usual answer is none: each config steps the
world it names, and `Setup.world_for/1` is the one place that decides it. The page
states the world for a config with nothing to choose; the panel states the input
beside the modules (`Setup.input_name/1`).

## Run it in dev, and read one column

`mix monty.readiness` prints one column per world. With no argument, each config
steps its own world; `--world synthetic` forces the stand-in.

Run it in **dev**. `config/test.exs` sets `world_simulator: :synthetic` for the
suite, so `MIX_ENV=test mix monty.readiness` reports the stand-in's refusals as
the port's. The stand-in column also refuses more than the MuJoCo one, because a
supervised experiment cannot state an object a sphere never showed
(`no_target_to_supervise`). Neither column is evidence about the other.

An experiment can carry more than one reason, so a column does not add up to the
number of experiments.

## The world the config names, as a filter of its own

The page's second facet is **World**: the simulator the _config_ names, which is
not the same question as the world a run steps. It is read through
`Setup.engine/1`, the same rule that decides `not planned`, so the two cannot
disagree.

## Why an experiment does not run

Each finding names one reason. `mix monty.readiness --all` lists them per
experiment.

| reason                        | what it is                                                          |
| ----------------------------- | ------------------------------------------------------------------- |
| `no_pretrained_memory`        | the config's model is not exported on this machine                  |
| `test_fixture_class`          | a class the module map cannot place — Monty's own test doubles      |
| `sensor_module_not_buildable` | a sensor's own layers — no experiment of Monty's is stopped by one  |
| `modules_not_ported`          | image-dataset classes                                               |
| `world_not_carried`           | a world this build does not carry                                   |
| `world_holds_no_object`       | the data is there and none of the meshes this config names is in it |

`no_pretrained_memory` is one family and one file: the `dogs/inference*` configs
load `trained/dogs_surf_unsupervised`, which `dogs/surf_unsupervised` writes. The
objects are a prerequisite the app exports (`objaverse_dogs`), so the run that
writes the memory is what closes them. Readiness says so in the same words the
page does.

No experiment is stopped for a _module class_ this port has not written, or for a
**sensor's** own layers. The cows family's `Vocus2` and `SlicMerge` are written
(`docs/monty-differences.md` §2.34, §2.36), and those configurations run. `Setup`
still refuses a sensor whose layers are missing rather than stepping a stand-in;
no experiment is left that needs one.

A fixture that names one of Monty's own test doubles (`FakeSensorModule`,
`FakeLearningModule`) cannot run here. The module map cannot place the name at
all, so there is nothing to look up and nothing to stand in for. A run under a
name nobody can resolve would be a run of something else.

## The classes, ranked by what each one alone unblocks

_Alone_ counts the experiments that **cannot run here** whose **only** reason is
that class: write it, and exactly those run. _Naming_ also counts the ones that
name it while something else stops them too. A class named only by postponed
experiments is not ranked at all.

Nothing is blocked by a class alone. `MontyBase`, the attention package, the
Saccade-on-image and Omniglot environment/interface pairs, and `GraphLM` were the
last ones ranked here, and all are written (§2.37–§2.39, §23, §24, §31).

## What is left

1. **The image world's memory.** The `*_world_image_on_scanned_model` family is
   written: the class, its interface, the PNG decoder its colour needs and a
   world kind that opens a config's captures (§2.37, §2.38). `mix monty.run
world_image_on_scanned_model` steps a real capture in 80–150 ms a step. A
   whole episode needs the decision §2.35 left open: each step keeps the
   480 × 640 view finder as nested lists, so a 400-step run stopped at step 66 on
   the worker's heap ceiling. Two ways out are open: frames as binaries, a
   quarter of the cost, or poses without frames. Either turns 66 steps into
   Monty's 387.
2. **The cows family's speed.** The fourteen configurations run. One step of
   `base_infer_cows_small_compositional` in MuJoCo, whose view is 256×256, costs
   about 5 s where Monty's costs milliseconds: `SlicMerge` 2.1 s and `Vocus2`
   2.6 s (§2.36). SLIC in a NIF, and the salience map's pyramids, would make a
   whole run of that family practical. The NIF is the way to that speed: the loop
   that agrees with `skimage` label for label is not the fastest one in Elixir.
3. **Monty's own pytest fixtures.** Three `test/*` configs name test doubles from
   Monty's `tests/` tree, which no port can have. They cannot run here and should
   stay so unless the fixtures themselves are ported.
4. **The refreshed code.** Monty pulls change a transform, a counter or a name.
   The configs, the map and this survey follow the pull; the Python modules are
   the reviewer's to translate.

One prerequisite is still worth knowing about. The config's two sensors keep
every observation of an episode, which is Monty's behaviour and, in this port's
representation, four gigabytes of heap by step 1200. The run now says so instead
of stopping silently (§2.35). The three ways out — a raised ceiling, poses
without frames, frames as flat binaries — are written down there.

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read `Monty.Studio.Readiness`,
  and the wording is `Setup`'s own finding. "Cannot run here" on a row is the same
  fact that stops a run; "waiting for prerequisites" is the same finding with a
  download offered.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`). A supervised experiment runs against MuJoCo and cannot
  run against the stand-in scene.
