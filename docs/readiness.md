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
| run here                |                   99 |             84 |
| refused                 |                   24 |             39 |
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

## Why the 24 are refused

| reason                           | refused | postponed | what it is                                                                |
| -------------------------------- | ------: | --------: | ------------------------------------------------------------------------- |
| `world_not_carried`              |       0 |        87 | Habitat-Sim — **postponed**, not a blocker                                |
| `modules_not_ported`             |      20 |        12 | a class nothing here stands in for                                        |
| `no_pretrained_memory`           |      18 |         1 | the config's model is not exported on this machine                        |
| `epochs_not_a_count`             |       1 |         6 | `${constants.rotations_all_count}` is not resolved before it is validated |
| `sm_to_lm_matrix_missing`        |       1 |         5 | Monty's own pytest fixtures: a bare model, not an experiment              |
| `learning_module_not_buildable`  |       1 |         0 | the class is written but refuses this config                              |
| `sensor_agent_mapping_mismatch`  |       0 |         3 | the same fixtures                                                         |
| `connection_index_out_of_range`  |       0 |         1 | the same                                                                  |
| `learning_module_count_mismatch` |       0 |         1 | the same                                                                  |

An experiment can carry more than one reason, so neither column adds to its
total. With Habitat postponed, almost all of Monty's pytest fixtures go with it:
`sm_to_lm_matrix_missing`, `sensor_agent_mapping_mismatch` and the two index
checks are now 1, 0, 0 and 0 among the refused — so hand-over §10.7's "should the
fixtures be in the catalogue?" is a question about a much smaller set.

## The classes, ranked by what each one alone unblocks

_Alone_ is the number of **refused** experiments whose **only** reason is that
class — writing it and nothing else makes exactly those run. _Naming_ also counts
the refused experiments that name it while something else refuses them too. A
class named only by postponed experiments is not ranked at all.

| class                         | alone | naming | the work                                                                 |
| ----------------------------- | ----: | -----: | ------------------------------------------------------------------------ |
| `MontyBase`                   |     3 |      3 | Monty's own model shell — the three are its pytest fixtures              |
| `GraphLM` (a matching scheme) |     1 |      1 | `tutorial/surf_agent_2obj_train` — `GraphLM` refuses itself upstream too |
| `TwoDSensorModule`            |     1 |     17 | a sensor module reading 2-D datasets — the cows family, below            |
| `DefaultAttentionSystem`      |     0 |      9 | arrives with that family                                                 |

The Saccade-on-image and Omniglot environment/interface pairs are gone from this
table: every config naming them is a Habitat config, so they are postponed.

## The order to work in

Done, in this order: **`DisplacementGraphLM` on PPF** (§19) and
**`FeatureGraphLM`** (§20). Ten feature experiments and the three MuJoCo PPF
configs run, and neither class is ranked any more — the counts went 87 → 99
runnable. What is left, in the order worth doing:

1. **The cows family** — 17 configs (`base_infer_cows_*`,
   `randrot_noise_infer_cows_*`, `supervised_pre_training_cows_*`) need
   `TwoDSensorModule`, 9 of them `DefaultAttentionSystem`, and 16 a pretrained
   cows model. Three things, one family; the sensor is the part to write, and the
   libraries are what `/prerequisites` exports. Its first dependency landed
   (§21): the edge detector that turns a patch into an angle, with Monty's
   nineteen cases translated.
2. **`MontyBase`** — three configs, and all three are Monty's pytest fixtures. Do
   this only if the fixtures are to be treated as experiments.

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read `Monty.Studio.Readiness`;
  the refusal text is `Setup`'s own finding, so "does not run" on a row is the
  same fact the page refuses a run with.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`), because a supervised experiment runs against MuJoCo and
  is refused against the stand-in scene.
