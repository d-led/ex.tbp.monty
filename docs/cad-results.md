# First results: a part learned, and a part not

What was run, on this machine (macOS, one node, `MIX_ENV=dev`), and what the
pages said. Every number below is one run's, and each section names the command
that prints it again.

## 1. Training, in the CAD world, on the geometry's own labels

```sh
MONTY_CAD_LABELS=features MONTY_CAD_PART=bracket mix run tmp/cad_run.exs \
  tutorial/surf_agent_2obj_train --world cad --episodes 1 --record
```

`MONTY_CAD_LABELS=features` is what makes the part more than one object: the
world's mask then carries `bosses/0`, `holes/0`, `risers/0` and `<part> body`
(`MontyCad.Scene`), instead of one id for the whole part.

![The training run's page](images/cad-training-summary.png)

- `tutorial/surf_agent_2obj_train`, `supervised training`, **finished**.
- 4327 steps in one episode, 2 min 14 s.
- "the memory now holds **1 object and 442 nodes**".
- "no episodes concluded" — correct: a _supervised pretraining_ episode stores a
  graph, it does not decide.

## 2. Recognition, with a memory of the part

```sh
mix run scripts/cad_experiment.exs plate plate
```

The script samples the part, writes the library a run loads and steps it. Its own
output first:

```
plate: 1557 nodes at 2.0 mm, 226 skipped, families %{nil => 892, "bosses" => 56,
  "holes" => 16, "risers" => 593}
```

— every node's family is the recognition's, read rather than inferred, and the 226
skipped visits are patches that saw too little surface to be a node.

![The recognition run's page](images/cad-recognition-summary.png)

`base_config_10distinctobj_surf_agent` on the `cad` world: **finished**,
`recognition`, **420 steps in ep 1/1 · recognised**, 13 s.

![Its evidence](images/cad-recognition-chart.png)

One object believed — `plate` — and its evidence climbed to **20.41** over 420
steps. That curve is the whole claim: the patch alone, moving over exact
geometry, accumulated enough to name the part it had a memory of.

![The patch at step 419](images/cad-recognition-evidence.png)

What the sensor saw at the last recorded step: the patch (left) and the same
frame as recorded, with the wide `view_finder` beside it. The gradient is the CAD
world's _shading_ — a B-rep has no colour, so `rgba` says how the surface turns.
A run comparing features on a textured mesh must therefore not ask for `hsv`.

## 3. The control: a part the memory does not hold

```sh
CAD_SENSE_ONLY=1 mix run scripts/cad_experiment.exs plate blend
```

Same memory (of `plate`), sensing `blend` instead.

![The control run's page](images/cad-control-summary.png)

**500 steps in ep 1/1 · out of steps** — not recognised, and 14.4 s to say so. The
pair is the result: a memory of this part recognises it, and the same memory does
not conclude on a part it was never shown.

## What these results are, and are not

- **They are stage 1 and 2**, in the CAD world: a memory built from exact geometry,
  and a recognition against it, with a control. Both runs are one episode of one
  part, so they say _that_ it happens, not how often — a rate needs seeds, and the
  script takes `CAD_SEED` for exactly that.
- **They are not stage 3.** No mesh, no texture, no MuJoCo: the world in both
  phases is the B-rep, ray cast. `ExTbpMonty.Cad.Objects` writes the same
  recognition's features as a world's object set, and the evaluation that reads
  those — same memory, no CAD on the node — has not been run yet.
- **The labels are the geometry's own.** Nothing here was annotated by hand, and a
  face the recognition could not explain is the _body_: on this fixture the boss's
  top annulus is one, so a sensor looking straight down carries the body's id
  there. That is the honest failure mode of the whole approach, and the test in
  `ex_monty_cad` asserts it rather than papering over it.
