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

## Three answers, and why there are three

| answer        | meaning                                                                         |
| ------------- | ------------------------------------------------------------------------------- |
| `runs here`   | no finding refuses it                                                           |
| `refused`     | something this port is missing: a class, a library, a setting it cannot resolve |
| `not planned` | its **world** is one this build does not carry — Monty's Habitat-Sim configs    |

Habitat is on its way out upstream (your call, 2026-11-08), so an experiment that
needs it is **postponed rather than refused**: nothing here is missing that
anybody means to write, and counting those as refusals made the backlog look
twice its size.

This build carries exactly one world, MuJoCo. A config that names any other —
Habitat, or a class like `SaccadeOnImageEnvironment` that is neither — is
postponed, and that is a fact about the config rather than about the deployment,
so the postponed count reads the same under `--world synthetic`.

## Where it stands (2026-11-08, this checkout)

|                         | MuJoCo (the default) | stand-in scene |
| ----------------------- | -------------------: | -------------: |
| experiments Monty ships |                  210 |            210 |
| run here                |                   97 |             94 |
| refused                 |                   26 |             29 |
| not planned             |                   87 |             87 |
| do not compose at all   |                    0 |              0 |

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

## Why the 26 are refused

| reason                           | refused | postponed | what it is                                                                        |
| -------------------------------- | ------: | --------: | --------------------------------------------------------------------------------- |
| `world_not_carried`              |       0 |        87 | Habitat-Sim — **postponed**, not a blocker                                        |
| `world_data_missing`             |      19 |         0 | the objects are not downloaded — one archive, and `/prerequisites` offers it      |
| `no_pretrained_memory`           |       2 |         1 | the config's model is not exported on this machine                                |
| `epochs_not_a_count`             |       1 |         6 | `${constants.rotations_all_count}` is not resolved before it is validated         |
| `sm_to_lm_matrix_missing`        |       1 |         5 | Monty's own pytest fixtures: a bare model, not an experiment                      |
| `learning_module_not_buildable`  |       1 |         0 | the class is written but refuses this config                                      |
| `unknown_module_class`           |       3 |         3 | a class the module map cannot place — Monty's own test fakes, in the six fixtures |
| `world_holds_no_object`          |       1 |         0 | the data is there and none of the meshes this config names is in it               |
| `sensor_agent_mapping_mismatch`  |       0 |         3 | the same fixtures                                                                 |
| `connection_index_out_of_range`  |       0 |         1 | the same                                                                          |
| `learning_module_count_mismatch` |       0 |         1 | the same                                                                          |

`modules_not_ported` is not in the table: **no config is refused for a class this
port has not written**. What is left of it is 9 postponed experiments, all of them
Habitat.

The table is about **this machine**. `world_data_missing` is 19 because the cows
family's objects are not downloaded here; those 19 become runnable once
`/prerequisites` has fetched `compositional_objects_1.4_mujoco` (1.6 GB), which
is a download rather than work on the port. §25 is why they are worth asking
about at all: the memory they load is exported and read, and the run that was
missing is now one archive away.

An experiment can carry more than one reason, so neither column adds to its
total. With Habitat postponed, almost all of Monty's pytest fixtures go with it:
`sm_to_lm_matrix_missing`, `sensor_agent_mapping_mismatch` and the two index
checks are now 1, 0, 0 and 0 among the refused — so hand-over §10.7's "should the
fixtures be in the catalogue?" is a question about a much smaller set.

A fixture that names one of Monty's own test doubles — `FakeSensorModule`,
`FakeLearningModule` — is refused rather than warned about since §24: the module
map cannot place the name at all, so there is nothing to look up and nothing to
stand in for, and a run under a name nobody can resolve would be a run of
something else.

## The classes, ranked by what each one alone unblocks

_Alone_ is the number of **refused** experiments whose **only** reason is that
class — writing it and nothing else makes exactly those run. _Naming_ also counts
the refused experiments that name it while something else refuses them too. A
class named only by postponed experiments is not ranked at all.

| class                         | alone | naming | the work                                                                 |
| ----------------------------- | ----: | -----: | ------------------------------------------------------------------------ |
| `GraphLM` (a matching scheme) |     1 |      1 | `tutorial/surf_agent_2obj_train` — `GraphLM` refuses itself upstream too |

Only one row is left. `MontyBase` and the attention package used to be here, and
both are written (§23, §24); the Saccade-on-image and Omniglot
environment/interface pairs are gone because every config naming them is a
Habitat config, and so is `DefaultAttentionSystem`, which was ranked at 0 alone
and 9 naming until §23 left the cows compositional configurations refused for
their pretrained model alone.

## The order to work in

Done, in this order: **`DisplacementGraphLM` on PPF** (§19),
**`FeatureGraphLM`** (§20), the cows family's sensor — the edge detector (§21) and
and **`TwoDSensorModule`** (§22) — **the attention package** (§23), and
**`MontyBase`**, which turned out to be the runtime's job rather than a class to
write (§24). Ten feature experiments, the three MuJoCo PPF configs and eight cows
configurations run: the counts went 87 → 100 runnable.

What is left is not a class, in the order worth doing:

1. **The cows pretrained model** — the nine compositional and monolithic
   configurations are refused for `no_pretrained_memory` alone. That is an
   export through `/prerequisites`, not code.
2. **`GraphLM`'s own gap** — `tutorial/surf_agent_2obj_train` names the base
   `GraphLM`, which refuses matching for a config that leaves the scheme to a
   subclass. That is a capability to build, not a class to write.
3. **Monty's own pytest fixtures** — the six `test/*` configs name test doubles
   from Monty's `tests/` tree, which no port can have; they are refused and
   should stay so unless the fixtures themselves are ported.
4. **What the animals need to be stepped** — 19 configurations are refused only
   for `world_data_missing`, which is the cows objects archive and a download.
   Running one of them is the parity check the whole port has been waiting for
   (hand-over §25).

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read `Monty.Studio.Readiness`;
  the refusal text is `Setup`'s own finding, so "does not run" on a row is the
  same fact the page refuses a run with.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`), because a supervised experiment runs against MuJoCo and
  is refused against the stand-in scene.
