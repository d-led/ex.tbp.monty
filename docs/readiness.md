# Which experiments run here, and what the rest need

`mix monty.readiness` opens every experiment Monty ships and says what stops
each one. This page is its answer for the tree in this document, with the order
the work should go in. Re-run the command rather than quoting these numbers — a
class that lands moves every row, and so does a pull from Monty
(`mix monty.refresh` does the pull, the copy and this).

```
mix monty.readiness            # the counts and the class ranking
mix monty.readiness --all      # ...and every experiment that does not run, with its reasons
mix monty.readiness --world synthetic
mix monty.readiness --json /tmp/readiness.json
```

The experiments page (`/experiments`) shows the same answer as its first facet,
**Runs here?** — `Monty.Studio.Readiness.catalog/1` is the one place it is
computed, and it is cached until the catalogue, the libraries on the machine or
the configured world moves.

## Four answers, and why there are four

| answer                      | meaning                                                                          |
| --------------------------- | -------------------------------------------------------------------------------- |
| `runs here`                 | no finding stops it                                                              |
| `waiting for prerequisites` | every finding is a file a download fills — nothing about this port is in the way |
| `cannot run here`           | something this port is missing: a class, a library, a setting it cannot resolve  |
| `not planned`               | its **world** is one this build does not carry — the two-D image datasets        |

"Waiting" was split out of "refused" on 2026-11-08, at your ask: a run whose
objects are still downloading is not in the same state as one whose class this
port never wrote, and "refused" read as a verdict on the experiment rather than
as a fact about the machine. The finding that says it is an error — the run does
not start — but it carries the download: the message says the run is waiting and
the link goes straight to `/prerequisites?fetch=<archive>`, which starts it.

Monty removed Habitat in #1286 (2026-11-09), and the 88 configurations that named
it went with the change.

## A world is what steps the scene; an environment is the config's own

Three questions were being asked as one, and the third is nobody's to ask:

- **the world** is what steps a scene: MuJoCo through the interpreter this
  application carries, MuJoCo through the compiled binding `ex_mujoco`, or
  Monty's own stand-in. A MuJoCo config steps on this deployment's engine.
- **the environment** is the config's, read out of its own tree — a captured
  scene (`SaccadeOnImageEnvironment`), a drawing (`OmniglotEnvironment`), a MuJoCo
  scene. A captured scene is its own world, because no simulator steps it, so
  offering such a config MuJoCo was offering a choice it does not have and then
  refusing it — which read as "cannot run here" about experiments that run.
- **the input** is the data a config names: the captures under
  `worldimages/bright_scenes`, the Omniglot dataset, a CAD part. Not a choice — a
  different set is a different experiment — so the page shows it instead of
  offering it.

`--world` is therefore an override, and the usual answer is nothing: each config
steps the world it names, and `Setup.world_for/1` is the one place that decides
it. The page states the world for a config that has nothing to choose, and the
panel states the input beside the modules (`Setup.input_name/1`).

## Where it stands (this box, 2026-11-20)

`mix monty.readiness` with no world argument prints the first column — each
config stepping its own world — and `--world synthetic` the second.

Both columns are a **dev** run. `config/test.exs` sets `world_simulator:
:synthetic` for the suite, and that setting is what the first column's "own
world" falls back to, so `MIX_ENV=test mix monty.readiness` prints the _second_
column twice: a table copied from a test run would report the stand-in's
refusals as the port's.

|                           | each config steps its own | `--world synthetic` |
| ------------------------- | ------------------------: | ------------------: |
| experiments Monty ships   |                       157 |                 157 |
| run here                  |                       145 |                 119 |
| waiting for prerequisites |                         0 |                   0 |
| cannot run here           |                         8 |                  34 |
| not planned               |                         4 |                   4 |
| do not compose at all     |                         0 |                   0 |

The counts move with Monty's tree and with what is exported on the machine, and
the second column refuses _more_ rather than fewer: a supervised experiment
cannot state an object a sphere never showed (`no_target_to_supervise`), so it is
refused there and runs against MuJoCo. That is why the stand-in column is not
evidence about the first one.

The cows objects, the numenta lab scene and both compositional releases are on
the machine, so the waiting column is empty. An experiment can carry more than
one reason, so neither column adds to its total.

## The world the config names, as a filter of its own

The page's second facet is **World** — the simulator the _config_ names, which is
not the same question as the world a run steps. It is read through
`Setup.engine/1`, the same rule that decides `not planned`, so the two cannot
disagree.

## Why the 8 cannot run here

| reason                        | cannot run | postponed | what it is                                                          |
| ----------------------------- | ---------: | --------: | ------------------------------------------------------------------- |
| `no_pretrained_memory`        |          8 |         0 | the config's model is not exported on this machine                  |
| `test_fixture_class`          |          0 |         3 | a class the module map cannot place — Monty's own test doubles      |
| `sensor_module_not_buildable` |          0 |         3 | a sensor's own layers — no experiment of Monty's is stopped by one  |
| `modules_not_ported`          |          0 |         1 | image-dataset classes, postponed                                    |
| `world_not_carried`           |          0 |         1 | a world this build does not carry — postponed, not a blocker        |
| `world_holds_no_object`       |          0 |         1 | the data is there and none of the meshes this config names is in it |

The eight are one family and one file: the `dogs/inference*` configs load
`trained/dogs_surf_unsupervised`, which `dogs/surf_unsupervised` writes. The
objects are a prerequisite the app exports (`objaverse_dogs`), so the run that
writes the memory is what closes them, and readiness says so in the same words
the page does.

Both counts that used to stand for missing classes read 0 now: no experiment is
stopped for a _module class_ this port has not written, and none is stopped for a
**sensor's** own layers either — the cows family's `Vocus2` and `SlicMerge` are
written (`docs/monty-differences.md` §2.34, §2.36), and those configurations run.
`Setup` still refuses a sensor whose layers are missing rather than stepping a
stand-in; there is simply no experiment left that needs one.

The table is about **this machine**, which is why it moves: `world_data_missing`
was 19, then 2, and is 0, because the memory those runs load is exported and read.
The four rows that used to be here (`epochs_not_a_count`, `sm_to_lm_matrix_missing`,
`sensor_agent_mapping_mismatch`, `learning_module_count_mismatch`) were all about
Monty's group members and went with them.

A fixture that names one of Monty's own test doubles — `FakeSensorModule`,
`FakeLearningModule` — cannot run here: the module map cannot place the name at
all, so there is nothing to look up and nothing to stand in for, and a run under a
name nobody can resolve would be a run of something else.

## The classes, ranked by what each one alone unblocks

_Alone_ is the number of experiments that **cannot run here** whose **only** reason
is that class — writing it and nothing else makes exactly those run. _Naming_ also
counts the ones that name it while something else stops them too. A class named
only by postponed experiments is not ranked at all.

| class | alone | naming | the work                            |
| ----- | ----: | -----: | ----------------------------------- |
| —     |     0 |      0 | nothing is blocked by a class alone |

No row is left. `MontyBase` and the attention package used to be here, and
both are written (§23, §24); the Saccade-on-image and Omniglot
environment/interface pairs are written too, so every config naming them runs
against the world it names (§2.37–§2.39), and `DefaultAttentionSystem` was ranked
at 0 alone and 9 naming until §23. `GraphLM` was the last one — `graph_1lm` names
the base class itself, and a supervised pretraining run trains with it without
ever matching, so it is buildable now (§31).

## The order to work in

Done, in this order: **`DisplacementGraphLM` on PPF** (§19),
**`FeatureGraphLM`** (§20), the cows family's sensor — the edge detector (§21) and
**`TwoDSensorModule`** (§22) — **the attention package** (§23), and
**`MontyBase`**, which turned out to be the runtime's job rather than a class to
write (§24). The feature experiments, the three MuJoCo PPF configs and the cows
configurations that need only their sensor ran from there; re-run the command for
what runs now.

What is left is not a class, in the order worth doing:

1. **The image world's memory, now that it runs.** The `*_world_image_on_scanned_model`
   family is written: the class, its interface, the PNG decoder its colour needs
   and a world kind that opens a config's captures (`docs/monty-differences.md`
   §2.37, §2.38). `mix monty.run world_image_on_scanned_model` steps a real
   capture at 80–150 ms a step. What a whole episode needs is the
   decision §2.35 left open: each step keeps the 480 × 640 view finder as nested
   lists, so a 400-step run was stopped at step 66 by the worker's heap ceiling.
   Frames as binaries (a quarter of the cost) or poses without frames is what
   turns 66 steps into Monty's 387.
2. **The cows family's speed, not its correctness** — the fourteen configurations
   run, and one step of `base_infer_cows_small_compositional` in MuJoCo, whose
   view is 256×256, costs about 5 s where Monty's costs milliseconds: `SlicMerge`
   2.1 s and `Vocus2` 2.6 s (`docs/monty-differences.md` §2.36). SLIC in a NIF,
   and the salience map's pyramids, are what would make a whole run of that
   family practical rather than an evening — and the NIF is the way to that
   speed, because the loop that agrees with `skimage` label for label is not the
   one that is fastest in Elixir.
3. **Monty's own pytest fixtures** — three `test/*` configs name test doubles
   from Monty's `tests/` tree, which no port can have; they cannot run here and
   should stay so unless the fixtures themselves are ported.
4. **The refreshed code** — Monty pulls regularly change a transform, a counter
   or a name. The configs, the map and this survey follow the pull; the Python
   modules are the reviewer's to translate.

Items answered and off this list: the cows memory, which `/prerequisites` now
exports from the v11 archive (the pickle reader translates a NaN to `nil`,
`docs/monty-differences.md` §2.33); the attention system, which the step now
steps and resets as Monty does (§2.32); and the view finder's `Snapshot`
transform, which is ported (§2.34), so `surf_agent_unsupervised_10distinctobj`
runs as the experiment it describes.

One caveat on that last one, and it is a prerequisite rather than a blocker: the
config's two sensors keep every observation of an episode, which is Monty's
behaviour and, in this port's representation, four gigabytes of heap by its 1200th
step. The run now says so instead of stopping silently (§2.35), and the three ways
out — a raised ceiling, poses without frames, frames as flat binaries — are
written down there.

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read `Monty.Studio.Readiness`;
  the wording is `Setup`'s own finding, so "cannot run here" on a row is the same
  fact that stops a run, and "waiting for prerequisites" is the same finding with
  a download offered.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`), because a supervised experiment runs against MuJoCo and
  cannot run against the stand-in scene.
