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
it went with the change: this build carries one world, MuJoCo, and what is
postponed now is the two-D image datasets, whose classes are written here but
whose world is images another program rendered.

This build carries exactly one world, MuJoCo. A config that names any other —
a class like `SaccadeOnImageEnvironment` that is neither — is
postponed, and that is a fact about the config rather than about the deployment,
so the postponed count reads the same under `--world synthetic`.

## Where it stands (2026-11-20, this checkout)

`MIX_ENV=test mix monty.readiness --world mujoco` prints this table's first
column and `--world synthetic` the second.

|                           | MuJoCo (the default) | stand-in scene |
| ------------------------- | -------------------: | -------------: |
| experiments Monty ships   |                  157 |            157 |
| run here                  |                  123 |            102 |
| waiting for prerequisites |                    0 |              0 |
| cannot run here           |                   22 |             43 |
| not planned               |                   12 |             12 |
| do not compose at all     |                    0 |              0 |

The counts move with Monty's tree and with what is exported on the machine, and
the second column refuses _more_ rather than fewer: a supervised experiment
cannot state an object a sphere never showed (`no_target_to_supervise`), so it is
refused there and runs against MuJoCo. That is why the stand-in column is not
evidence about the MuJoCo one.

The cows objects, the numenta lab scene and both compositional releases are on
the machine, so the waiting column is empty. An experiment can carry more than
one reason, so neither column adds to its total.

## The world the config names, as a filter of its own

The page's second facet is **World** — the simulator the _config_ names, which is
not the same question as the world a run steps. It is read through
`Setup.engine/1`, the same rule that decides `not planned`, so the two cannot
disagree.

## Why the 22 cannot run here

| reason                        | cannot run | postponed | what it is                                                                              |
| ----------------------------- | ---------: | --------: | --------------------------------------------------------------------------------------- |
| `sensor_module_not_buildable` |         14 |         3 | a sensor's own layers — the cows family's `Vocus2` config shape and `SlicMerge` (§2.34) |
| `no_pretrained_memory`        |          8 |         1 | the config's model is not exported on this machine                                      |
| `world_not_carried`           |          0 |         9 | images another program rendered — **postponed**, not a blocker                          |
| `test_fixture_class`          |          0 |         3 | a class the module map cannot place — Monty's own test doubles                          |
| `modules_not_ported`          |          0 |         9 | image-dataset classes, all of them postponed                                            |
| `world_holds_no_object`       |          0 |         1 | the data is there and none of the meshes this config names is in it                     |

`modules_not_ported` reads 0 and `sensor_module_not_buildable` does not: no
experiment is stopped for a _module class_ this port has not written, and 14 are
stopped because a **sensor's** own layers are missing. `Setup` used to answer
that case with the stand-in sensor, which is how the cows family ran hundreds of
episodes that proposed no goals and concluded nothing while looking healthy;
`docs/monty-differences.md` §2.34 says what changed and why the stand-in is gone.

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
environment/interface pairs are gone because every config naming them is an
image-dataset config, and so is `DefaultAttentionSystem`, which was ranked at 0
alone and 9 naming until §23. `GraphLM` was the last one — `graph_1lm` names the
base class itself, and a supervised pretraining run trains with it without
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

1. **The cows family's sensor layers** — fourteen configurations are stopped by
   `sensor_module_not_buildable` alone: their view finder names `Vocus2` with
   inline channel objects (a config shape `SalienceSM` does not read yet) and
   `SlicMerge` as its segmentation strategy, which is not written. `SlicMerge` is
   `skimage.segmentation.slic` plus a BFS merge, so it is an algorithm to port
   with Monty's numbers as fixtures, not a wrapper. Nothing else unblocks those
   fourteen (`docs/monty-differences.md` §2.34).
2. **Monty's own pytest fixtures** — three `test/*` configs name test doubles
   from Monty's `tests/` tree, which no port can have; they cannot run here and
   should stay so unless the fixtures themselves are ported.
3. **The refreshed code** — Monty pulls regularly change a transform, a counter
   or a name. The configs, the map and this survey follow the pull; the Python
   modules are the reviewer's to translate.

Items answered and off this list: the cows memory, which `/prerequisites` now
exports from the v11 archive (the pickle reader translates a NaN to `nil`,
`docs/monty-differences.md` §2.33); the attention system, which the step now
steps and resets as Monty does (§2.32); and the view finder's `Snapshot`
transform, which is ported (§2.34), so `surf_agent_unsupervised_10distinctobj`
runs as the experiment it describes.

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read `Monty.Studio.Readiness`;
  the wording is `Setup`'s own finding, so "cannot run here" on a row is the same
  fact that stops a run, and "waiting for prerequisites" is the same finding with
  a download offered.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`), because a supervised experiment runs against MuJoCo and
  cannot run against the stand-in scene.
