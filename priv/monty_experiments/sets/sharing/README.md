# sharing — two modules, one object, no parent

A limited experiment for the Thousand Brains "shared distributed learning"
discussion (Jeff Hawkins' alternating parent–child inference cycles, Niels'
hippocampal consolidation). Neither mechanism is implemented upstream and
neither has a config key here, so this set tests the one thing a config *can*
say: **two learning modules learning at the same time from two views of the same
object, wired to each other only by a vote.**

## What is in it

| file | what it is |
| --- | --- |
| `conf/monty/learning_module/displacement_2lm.yaml` | `displacement_1lm` twice — Monty's tutorial settings, `k: 5`, `match_attribute: displacement` |
| `conf/monty/connectivity/2lm_2sm_dist.yaml` | LM0 ← `patch_0`, LM1 ← `patch_1`, no LM-to-LM input, both vote |
| `conf/experiment/sharing/dist_two_columns.yaml` | one training epoch over two objects, both modules written |

Everything else is Monty's, from `tutorial/dist_agent_5lm_2obj_train`, named in
`defaults` and not copied: the five-sensor distant agent, the two YCB objects,
the naive scan, the 307-step episode, the sensor clip. Patches 2–4 and the view
finder mount and feed no module, as the view finder does in every one-module
config.

**Why this world and not the CAD one.** The first version of this set borrowed
the CAD plate world because its meshes were already built here. It was the wrong
ground: a 300-step cap there stored **4 and 5 nodes**, because a surface patch on
a flat part passes almost nothing through its delta filter. Monty's own
multi-module experiment already exists, already works, and is the same flat
arrangement at five modules (`5lm_5sm` has `lm_to_lm_matrix: null` and an
all-to-all vote matrix). Borrowing a delicate world to ask "does the mechanism
work" answers nothing; the question belongs on a world that produces a memory.

## How to run it

Experiments page → `sharing / dist_two_columns` → **Run it**. The config is one
training epoch over `mug` and `banana`, so two episodes of 307 steps — about 25
seconds. There is no `mix` command in this workflow on purpose: a desktop user
runs it from the page.

## What the run answers

**Measured 2026-11-19**, run `25cb9ec6` from this page, 2 episodes, 400-step cap
(the config's termination concludes each at 307):

- `run finished: 614 steps`, `mug 307 steps (concluded)`, `banana 307 steps
  (concluded)`, ~5.6 s in the model and ~17.6 s in the world.
- The log names the memory: "the memory **2 modules** learned is the library
  `sharing_dist_two_columns`".
- The library holds `lm_index` 0 on `patch_0` with **11 nodes** (mug 9, banana 2)
  and `lm_index` 1 on `patch_1` with **13 nodes** (mug 10, banana 3) — the range
  Monty's own 5° naive-scan training gives (~9–80 nodes an object). Both modules
  learned, at every step, with no parent between them.

Read the size honestly: sparse is what naive scanning looks like. Monty's own
tutorial reaches its ~2 400 nodes an object with
`n_train_epochs: rotations_all_count` — fourteen epochs, hours of runs, not a
config tweak. This set is one epoch because it is a look, not a corpus.

## What would falsify the premise

The second module refusing to start, or writing nothing while the first learns.
It does not: both are fed at every step and both appear in the library.

## What this set is not

It is not a test of oscillation, replay or consolidation. A consolidation pass
over a stored library would be an offline job over the same files, needs no step
semantics, and can fail — that is the next experiment, after the parallel
learning modules work. Role swapping would need a mechanism; there is no config
key, and nothing upstream to be module-for-module with.
