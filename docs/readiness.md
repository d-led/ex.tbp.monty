# Which experiments run here, and what the rest need

`mix monty.readiness` opens every experiment Monty ships and says what stops
each one. This page is its answer for the tree in this document, with the order
the work should go in. Re-run the command rather than quoting these numbers — a
class that lands moves every row.

```
mix monty.readiness            # the counts and the class ranking
mix monty.readiness --all      # ...and every refused experiment with its reasons
mix monty.readiness --world synthetic
mix monty.readiness --json /tmp/readiness.json
```

The experiments page (`/experiments`) shows the same answer as its first facet,
**Runs here?** — `Monty.Studio.Readiness.catalog/1` is the one place it is
computed, and it is cached until the catalogue, the libraries on the machine or
the configured world moves.

## Where it stands (2026-11-08, this checkout)

|                         | MuJoCo (the default) | stand-in scene |
| ----------------------- | -------------------: | -------------: |
| experiments Monty ships |                  210 |            210 |
| run here                |                   87 |            122 |
| refused                 |                  123 |             88 |
| do not compose at all   |                    0 |              0 |

The stand-in column is higher because a sphere needs no pretrained memory and
cannot be refused for showing no target — which is also why it is not evidence
about the MuJoCo column.

## Why the refusals name what they name (MuJoCo)

| reason                           | how many | what it is                                                                     |
| -------------------------------- | -------: | ------------------------------------------------------------------------------ |
| `world_not_carried`              |       87 | Habitat-Sim, which this build does not carry (hand-over §10.7, still with you) |
| `modules_not_ported`             |       53 | a class nothing here stands in for                                             |
| `no_pretrained_memory`           |       19 | the config's model is not exported on this machine                             |
| `epochs_not_a_count`             |        7 | `${constants.rotations_all_count}` is not resolved before it is validated      |
| `sm_to_lm_matrix_missing`        |        6 | Monty's own pytest fixtures: a bare model, not an experiment                   |
| `learning_module_not_buildable`  |        5 | the class is written but refuses this config                                   |
| `sensor_agent_mapping_mismatch`  |        3 | the same fixtures                                                              |
| `connection_index_out_of_range`  |        1 | the same                                                                       |
| `learning_module_count_mismatch` |        1 | the same                                                                       |

An experiment can appear under more than one reason, so the column does not add
to 123.

Two of these are this port's own work and need no Monty class at all:

- **`no_pretrained_memory` (19)** — the cows and compositional models
  (`base_infer_cows_*`, `supervised_pre_training_cows_*`,
  `randrot_noise_infer_cows_*`) plus `tutorial/dist_agent_5lm_2obj_eval`,
  `tutorial/surf_agent_2obj_eval` and `tutorial/omniglot_inference`. They run the
  moment their library is exported — `/prerequisites` does that, and
  `Monty.Studio.Pretrained.pending?/0` says whether anything is waiting.
- **`epochs_not_a_count` (7)** — all seven are the `test/hierarchy/**` fixtures.
  `n_eval_epochs: ${constants.rotations_all_count}` reaches validation
  unresolved; hand-over §11 open point 4 says this was recorded as open and asks
  for it to be re-checked. It is still true.

The `test/hierarchy/**`, `test/base_config/**`, `test/profile/**` and `test/run*`
configs are Monty's pytest fixtures, not experiments (hand-over §10.7, a decision
still with the user). Six of the seven owners of `sm_to_lm_matrix_missing` are
those fixtures.

## The classes, ranked by what each one alone unblocks

_Alone_ is the number of experiments whose **only** reason to be refused is that
class — writing it and nothing else makes exactly those run. _Naming_ also counts
the experiments that name it while something else refuses them too.

| class                             | alone | naming | the work                                                                 |
| --------------------------------- | ----: | -----: | ------------------------------------------------------------------------ |
| `FeatureGraphLM`                  |    10 |     21 | a whole learning module (`feature_matching/graph_matching.py`)           |
| `MontyBase`                       |     3 |      6 | Monty's own model shell — the three are its pytest fixtures              |
| `DisplacementGraphLM` (PPF)       |     2 |      4 | **a capability, not a class**: `match_attribute: PPF` is refused here    |
| `GraphLM` (a matching scheme)     |     1 |      1 | `tutorial/surf_agent_2obj_train` — `GraphLM` refuses itself upstream too |
| `TwoDSensorModule`                |     1 |     17 | a sensor module reading 2-D datasets                                     |
| `DefaultAttentionSystem`          |     0 |      9 | arrives with the Saccade-on-image and Omniglot families                  |
| `SaccadeOnImage*Environment`      |     0 |      6 | a Habitat-based environment, not carriable without Habitat-Sim           |
| `SaccadeOnImage*Interface`        |     0 |      6 | the same                                                                 |
| `OmniglotEnvironment`/`Interface` |     0 |      2 | an image-file world                                                      |

## The order to work in

1. **`DisplacementGraphLM` on PPF** — two experiments (`test/graph_learning/
ppf_pred_mujoco`, `test/graph_building/load_mujoco_for_ppf`) and two more
   behind Habitat. The class exists and answers every `LearningModule`
   callback; what is missing is one `match_attribute`. Monty's own
   `DisplacementGraphLM` reads `PPF` features where ours reads displacement, so
   this is a translation of a branch, not a module.
2. **`FeatureGraphLM`** — ten MuJoCo experiments in one family
   (`test/graph_learning/feature_pred_mujoco`, `..._off_object_mujoco`,
   `..._off_object_train_mujoco`, `..._time_out_mujoco`,
   `feature_uniform_initial_poses_mujoco`, `five_lm_feature_mujoco`,
   `fixed_actions_feat_mujoco`, and three `test/graph_building/*`). It is the
   largest single win, and the widest naming count in the tree.
3. **`TwoDSensorModule` + `DefaultAttentionSystem`** — seventeen experiments name
   the sensor, nine the attention system, and the Saccade-on-image and Omniglot
   families need both; only `supervised_pre_training_cows_3d_children` is blocked
   by the sensor alone. Do them together, and only for a world this build has.
4. **`MontyBase`** — three configs, and all three are Monty's pytest fixtures. Do
   this only if the fixtures are to be treated as experiments.

Anything in the right-hand column of the reason table is not on this list:
Habitat-Sim is a decision, the fixtures are a decision, and the two rows above
them are fixes to this port rather than ports of Monty's.

## Two rules this survey is held to

- **The page and the count cannot disagree.** Both read
  `Monty.Studio.Readiness`; the refusal text is `Setup`'s own finding, so "does
  not run" on a row is the same fact the page refuses a run with.
- **An experiment that runs in one world and not another says so.** The answer is
  per world (`--world`), because a supervised experiment runs against MuJoCo and
  is refused against the stand-in scene.
