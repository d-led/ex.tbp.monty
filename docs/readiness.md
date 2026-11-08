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
| `not planned`               | its **world** is one this build does not carry — Monty's Habitat-Sim configs     |

"Waiting" was split out of "refused" on 2026-11-08, at your ask: a run whose
objects are still downloading is not in the same state as one whose class this
port never wrote, and "refused" read as a verdict on the experiment rather than
as a fact about the machine. The finding that says it is an error — the run does
not start — but it carries the download: the message says the run is waiting and
the link goes straight to `/prerequisites?fetch=<archive>`, which starts it.

Habitat is on its way out upstream (your call, 2026-11-08), so an experiment that
needs it is **postponed rather than refused**: nothing here is missing that
anybody means to write, and counting those as refusals made the backlog look
twice its size.

This build carries exactly one world, MuJoCo. A config that names any other —
Habitat, or a class like `SaccadeOnImageEnvironment` that is neither — is
postponed, and that is a fact about the config rather than about the deployment,
so the postponed count reads the same under `--world synthetic`.

## Where it stands (2026-11-08, this checkout)

|                           | MuJoCo (the default) | stand-in scene |
| ------------------------- | -------------------: | -------------: |
| experiments Monty ships   |                  203 |            203 |
| run here                  |                  114 |             94 |
| waiting for prerequisites |                    4 |              0 |
| cannot run here           |                    4 |             28 |
| not planned               |                   81 |             81 |
| do not compose at all     |                    0 |              0 |

The MuJoCo column moved by seventeen when the cows objects were downloaded:
those configs were waiting for one archive, and `compositional_objects_1.4_mujoco`
is now unpacked under `$MONTY_DATA`. The four left waiting are the second
archives — the random-locations cows set and two releases whose memory is not
exported here.
203, not the number of files under `conf/experiment`: seven of those name no
experiment class at all — they are the group members Monty's own tests compose an
environment, a sensor module or a learning module from. A configuration with no
class to run is a piece of one, so it is neither counted nor refused (§27).

The stand-in scene refuses _more_, not fewer: a supervised experiment cannot
state an object a sphere never showed (`no_target_to_supervise`), so it is
refused there and runs against MuJoCo. That is why it is not evidence about the
MuJoCo column.

## The world the config names, as a filter of its own

The page's second facet is **World** — the simulator the _config_ names, which is
not the same question as the world a run steps: `mujoco` 123, `habitat` 73,
`other` 14 (a config naming no simulator this application knows). It is read
through `Setup.engine/1`, the same rule that decides `not planned`, so the two
cannot disagree.

## Why the 4 cannot run here

| reason                          | cannot run | postponed | what it is                                                                        |
| ------------------------------- | ---------: | --------: | --------------------------------------------------------------------------------- |
| `world_not_carried`             |          0 |        81 | Habitat-Sim — **postponed**, not a blocker                                        |
| `world_data_missing`            |          2 |         0 | the objects are not downloaded — one archive, and the finding links to it         |
| `unknown_module_class`          |          3 |         3 | a class the module map cannot place — Monty's own test fakes, in the six fixtures |
| `no_pretrained_memory`          |          2 |         1 | the config's model is not exported on this machine                                |
| `learning_module_not_buildable` |          1 |         0 | the class is written but refuses this config                                      |
| `world_holds_no_object`         |          1 |         0 | the data is there and none of the meshes this config names is in it               |

`modules_not_ported` is not in the table: **no config is stopped for a class this
port has not written**. What is left of it is 9 postponed experiments, all of them
Habitat.

The table is about **this machine**, which is why it moved: `world_data_missing`
was 19 until the cows family's objects were downloaded, and it is 2 now — the
second archive, `compositional_objects_1.4_random_locs_mujoco` (1.3 GB). §25 is
why those were worth asking about at all: the memory they load is exported and
read, so the run was one archive away rather than one feature away. The four rows
that used to be here (`epochs_not_a_count`, `sm_to_lm_matrix_missing`,
`sensor_agent_mapping_mismatch`, `learning_module_count_mismatch`) were all about
the seven group members, and went with them.

An experiment can carry more than one reason, so neither column adds to its
total. With Habitat postponed, almost all of Monty's pytest fixtures go with it:
`sm_to_lm_matrix_missing`, `sensor_agent_mapping_mismatch` and the two index
checks are now 1, 0, 0 and 0 among the four that cannot run — so hand-over §10.7's
"should the fixtures be in the catalogue?" is a question about a much smaller
set.

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

| class                         | alone | naming | the work                                                                 |
| ----------------------------- | ----: | -----: | ------------------------------------------------------------------------ |
| `GraphLM` (a matching scheme) |     1 |      1 | `tutorial/surf_agent_2obj_train` — `GraphLM` refuses itself upstream too |

Only one row is left. `MontyBase` and the attention package used to be here, and
both are written (§23, §24); the Saccade-on-image and Omniglot
environment/interface pairs are gone because every config naming them is a
Habitat config, and so is `DefaultAttentionSystem`, which was ranked at 0 alone
and 9 naming until §23 left the cows compositional configurations waiting for
their pretrained model alone.

## The order to work in

Done, in this order: **`DisplacementGraphLM` on PPF** (§19),
**`FeatureGraphLM`** (§20), the cows family's sensor — the edge detector (§21) and
and **`TwoDSensorModule`** (§22) — **the attention package** (§23), and
**`MontyBase`**, which turned out to be the runtime's job rather than a class to
write (§24). Ten feature experiments, the three MuJoCo PPF configs and eight cows
configurations run: the counts went 87 → 100 runnable, and 114 once the cows
objects were downloaded.

What is left is not a class, in the order worth doing:

1. **The cows pretrained model** — the two compositional and monolithic
   configurations still waiting for `no_pretrained_memory` alone. That is an
   export through `/prerequisites`, not code.
2. **`GraphLM`'s own gap** — `tutorial/surf_agent_2obj_train` names the base
   `GraphLM`, which refuses matching for a config that leaves the scheme to a
   subclass. That is a capability to build, not a class to write.
3. **Monty's own pytest fixtures** — the six `test/*` configs name test doubles
   from Monty's `tests/` tree, which no port can have; they cannot run here and
   should stay so unless the fixtures themselves are ported.
4. **The second cows archive** — 2 configurations still have no
   `compositional_objects_1.4_random_locs_mujoco` to step. The first one is
   unpacked, so `base_infer_cows_large_compositional` and its siblings are the
   parity check the whole port has been waiting for (hand-over §25).

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read `Monty.Studio.Readiness`;
  the wording is `Setup`'s own finding, so "cannot run here" on a row is the same
  fact that stops a run, and "waiting for prerequisites" is the same finding with
  a download offered.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`), because a supervised experiment runs against MuJoCo and
  cannot run against the stand-in scene.
