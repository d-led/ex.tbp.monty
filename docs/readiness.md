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

## Where it stands (2026-11-10, this checkout)

|                           | MuJoCo (the default) | stand-in scene |
| ------------------------- | -------------------: | -------------: |
| experiments Monty ships   |                  132 |            132 |
| run here                  |                  120 |             94 |
| waiting for prerequisites |                    0 |              0 |
| cannot run here           |                    3 |             29 |
| not planned               |                    9 |              9 |
| do not compose at all     |                    0 |              0 |

203 became 132 when Monty dropped Habitat: that pull removed 88 configuration
files and merged the `*_mujoco` half of its pytest fixtures into the plain names
(`test/base_config/base_mujoco` is `test/base_config/base`), and added five. The
cows objects, the numenta lab scene and both compositional releases are on the
machine, which is why the waiting column is empty and the three that remain are
**not** waiting for anything: they name Monty's own test doubles (3) and one
names a world holding none of the meshes its config has.
132, not the number of files under `conf/experiment`: five of those name no
experiment class at all — they are the group members Monty's own tests compose an
environment, a sensor module or a learning module from. A configuration with no
class to run is a piece of one, so it is neither counted nor refused (§27).

The stand-in scene refuses _more_, not fewer: a supervised experiment cannot
state an object a sphere never showed (`no_target_to_supervise`), so it is
refused there and runs against MuJoCo. That is why it is not evidence about the
MuJoCo column.

## The world the config names, as a filter of its own

The page's second facet is **World** — the simulator the _config_ names, which is
not the same question as the world a run steps: `mujoco` 123, `other` 9 (a config
naming no simulator this application knows). It is read
through `Setup.engine/1`, the same rule that decides `not planned`, so the two
cannot disagree.

## Why the 3 cannot run here

| reason                  | cannot run | postponed | what it is                                                                          |
| ----------------------- | ---------: | --------: | ----------------------------------------------------------------------------------- |
| `world_not_carried`     |          0 |         9 | images another program rendered — **postponed**, not a blocker                      |
| `unknown_module_class`  |          3 |         0 | a class the module map cannot place — Monty's own test fakes, in the three fixtures |
| `no_pretrained_memory`  |          0 |         1 | the config's model is not exported on this machine                                  |
| `world_holds_no_object` |          1 |         0 | the data is there and none of the meshes this config names is in it                 |

`world_data_missing` is not in the table because no experiment is stopped for it
any more: the cows objects and the numenta lab scene are unpacked here, and what
is left of that row is nothing. `modules_not_ported` is missing for the same
reason as before — **no config is stopped for a class this port has not written**
— and what is left of it is 9 postponed experiments, all of them image datasets.

The table is about **this machine**, which is why it moves: `world_data_missing`
was 19, then 2, and is 0. §25 is why those were worth asking about at all: the
memory they load is exported and read, so the run was one archive away rather than
one feature away. The four rows that used to be here (`epochs_not_a_count`,
`sm_to_lm_matrix_missing`, `sensor_agent_mapping_mismatch`,
`learning_module_count_mismatch`) were all about the seven group members, and went
with them.

An experiment can carry more than one reason, so neither column adds to its
total. With the image datasets postponed, Monty's pytest fixtures go with them:
`sm_to_lm_matrix_missing`, `sensor_agent_mapping_mismatch` and the two index
checks are 0, 0, 0 and 0, and the three fixtures that remain are the ones naming
Monty's own test doubles — so hand-over §10.7's "should the fixtures be in the
catalogue?" is a question about three configurations, and the answer is the one
below.

A fixture that names one of Monty's own test doubles — `FakeSensorModule`,
`FakeLearningModule` — cannot run here rather than only warning since §24: the
module map cannot place the name at all, so there is nothing to look up and
nothing to stand in for, and a run under a name nobody can resolve would be a run
of something else.

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
and **`TwoDSensorModule`** (§22) — **the attention package** (§23), and
**`MontyBase`**, which turned out to be the runtime's job rather than a class to
write (§24). Ten feature experiments, the three MuJoCo PPF configs and eight cows
configurations run: the counts went 87 → 100 runnable, and 114 once the cows
objects were downloaded.

What is left is not a class, in the order worth doing:

1. **The cows memory, exported** — every cows config names
   `pretrained_compositional_objects_v10` since #1280 and this machine has the
   archive, but nothing has turned it into the export a run reads, so a cows run
   steps the v8 graphs and says so (`memory_from_another_release`). That is an
   export through `/prerequisites`, not code.
2. **`GraphLM`'s own gap** — `tutorial/surf_agent_2obj_train` names the base
   `GraphLM`, which refuses matching for a config that leaves the scheme to a
   subclass. That is a capability to build, not a class to write.
3. **Monty's own pytest fixtures** — three `test/*` configs name test doubles
   from Monty's `tests/` tree, which no port can have; they cannot run here and
   should stay so unless the fixtures themselves are ported.
4. **The refreshed code** — Monty pulled on 2026-11-10 changed the transform in
   `GraphMemory.update_memory` (#1280), removed Habitat (#1286) and the two step
   counters (#1293, #1294), and renamed the recognition policy to a strategy
   (#1291). The configs, the map and this survey follow the pull; the Python
   modules are the reviewer's to translate.

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read `Monty.Studio.Readiness`;
  the wording is `Setup`'s own finding, so "cannot run here" on a row is the same
  fact that stops a run, and "waiting for prerequisites" is the same finding with
  a download offered.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`), because a supervised experiment runs against MuJoCo and
  cannot run against the stand-in scene.
