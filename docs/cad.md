# A CAD part in a run

Three stages, one question: **can Monty learn what a part is from a perfect
sensor, and then recognise it from an ordinary one?**

The perfect sensor is a STEP part, ray-cast exactly, with the part's features
named by the recognition rather than guessed. The ordinary one is the same part
as a textured mesh in MuJoCo, which is what every other Monty run senses. Between
them they measure the thing worth measuring — what Monty's own learning and
evidence do, once the labels and the geometry stop being the hard part.

## The three stages

| Stage                        | World                                                | Memory                                                 | What it answers                                                                    |
| ---------------------------- | ---------------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| **1. Learn features**        | one part, `--world cad`, labels from the recognition | written, one label per feature                         | does a graph trained on exact geometry hold a hole, a boss, a fillet as an object? |
| **2. Learn the composition** | the same parts, several features each                | written, per-feature children plus the part above them | can the part be recognised as an arrangement of features rather than as one lump?  |
| **3. Recognise on meshes**   | MuJoCo, the same parts as textured meshes            | **read** — the file stage 1 and 2 wrote                | does the memory survive the change of world, with no CAD on the node at all?       |

Stage 3 is the measurement. Stage 1 and 2 are the teaching, and they are allowed
to be exact in a way no evaluation is.

### Stage 1 and 2: what a training episode is

Monty's own supervised pretraining, in a CAD world. The world is
`MontyCad.Scene`, which answers only what a sensor sees:

```elixir
%{
  depth: [[float()]],      # metres; 0.0 where the ray met nothing
  rgba: [[[float()]]],     # 0..1 per channel; shading, since a B-rep has no colour
  semantic: [[float()]],   # the label each pixel carries
  centre: %{on_object: boolean(), depth: float() | nil, rgba: [float()] | nil}
}
```

That is the whole of the world. The kinematics, the actions, the proprioceptive
state, the sensor module, the learning module and the votes are the port's — only
the picture comes from CAD, and it comes from one ray-cast pass over the exact
B-rep per sensor per step.

**The labels are the point.** quiddity's recognition accounts for every face: part
of a feature, part of the body with the reason, refused, or unexplained. A pixel
on a bore can therefore carry the bore's own id rather than the part's, which is
what makes a feature an object a learning module can be given, and what makes
stage 2's composition something Monty can learn rather than something we assert.

### Stage 3: what the evaluation is, and is not

The same parts, tessellated, textured, in MuJoCo — the world every other run in
this studio uses. The memory is a file; nothing on the node opens a STEP file, and
`ex_quiddity` need not be on the node at all. That absence is the measurement: a
recognition in stage 3 is Monty's, from the patches, and the only thing CAD
contributed was the teaching.

Three things have to match for that comparison to mean anything, and each is a
decision rather than a detail:

- **Units.** A part is millimetres and the framework is metres. A memory a MuJoCo
  run loads has to be trained in metres; `MontyCad.Percept.observation/2` takes
  `:units` for exactly this.
- **Colour.** A B-rep has no appearance, so a CAD frame's `rgba` is shading. An
  `hsv` feature trained on shading and evaluated on a texture measures the
  texture, so the training config asks for the features that survive the change —
  pose vectors, pose definedness, the curvatures.
- **Geometry.** The mesh must be the same part, not a lookalike: tessellated from
  the same STEP file, so the only difference between the two worlds is texture and
  a renderer.

## Which library does what

The geometry is a dependency, not code in this application:

| library                                        | job                                                                                                                                                                                                                                                                        |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ex_quiddity` (Hex)                            | `Quiddity.open/1` reads the STEP; `Quiddity.features/1` says which face belongs to which feature; `Quiddity.samples/2` is the surface; `Quiddity.frame/2` is one camera's view of the B-rep; `Quiddity.mesh/2` is the tessellation, with the face every triangle came from |
| `ex_monty_cad` (git dep, pinned in `mix.lock`) | `MontyCad.Training.write_library/3` turns a part into the memory a run reads; `MontyCad.Export.part_mesh/2` and `feature_meshes/2` turn exact faces into meshes; `MontyCad.Scene` is the world a B-rep run steps; `MontyCad.Library` is the memory format                  |
| `ExTbpMonty.Cad.Objects` (this application)    | writes one mesh as one MuJoCo object — `textured.obj`, `texture_map.png`, `metadata.json`, in metres                                                                                                                                                                       |

Nothing here recomputes a feature, a sample or a triangle: ownership comes from
`Quiddity.Recognition`, the points and their features from `MontyCad.Training`,
the triangles from `MontyCad.Export`.

## Where a part comes from

`$MONTY_DATA/parts/` — `bracket.step` or `bracket.stp`, plain or gzipped — is the
same place MuJoCo's object sets come from, and `MONTY_CAD_PART` names one by name
rather than by path (`MontyCad.Inputs.part_path/1`). A path to a file that exists
still works, for a part that should not have to be moved first.

A _set_ of parts is what a pretraining run needs, and a run currently opens the one
part the variable names. That is the first thing stage 1 has to grow.

## How to run one

Two clicks, in this order, and no shell:

1. **`/prerequisites` → "CAD part memories and meshes" → Make.** One memory and
   one object set per part this application's configurations name, taught from
   the STEP file each part ships and meshed into `cad_objects` under the data
   folder. A part whose memory was never written is a part a run has nothing to
   match against, and the page says so on the experiment's own checks.
2. **`/experiments/cad/plate_part_eval` → Run it.** One episode per object the
   config names, in the world that config names, with the patch's own pictures
   beside the evidence per object, step by step.

The geometry is a git dependency pinned in `mix.lock`, so `mix deps.get` is the
whole setup — no checkout has to sit beside this one, and no build path has to be
appended. The experiment lives in `priv/monty_experiments/sets/cad/conf`, and
that set's own README is the same walk-through written down.

Measured on this Mac (2026-11-19), those two clicks and nothing else: the plate's
three evaluation episodes concluded in 97, 184 and 351 steps, and each answered
`plate` where the target was `plate` — `correct` in all three, at the highest
evidence of 26.49, 11.02 and 19.72; `cad/blend_part_eval` concluded in 178 steps,
`blend` correct at 22.93; `cad/blend-big_part_eval` concluded in 90 steps,
`blend-big` correct at 8.59. `cad/plate_features_eval` is the one that answers a
sibling: asked about `plate_bosses_0` it names `plate_risers_0`, which is the wall
recorded below — the two features report the same surface. The run keeps its log,
its sensor pictures and `eval_stats.csv` in its own directory under the
application's data folder.

Both halves read the same experiment, which is what makes the memory and the run
comparable: the memory is taught through **the run's own patch** — the field of
view its camera makes, the distance its policy stands off by, and three nodes
across the patch's width, all read from the config — so the two see one surface
rather than two.

The same experiment from a shell, for a machine without a page in front of it:

```sh
mix run scripts/cad_experiment.exs plate plate          # remember plate, sense plate
CAD_SENSE_ONLY=1 mix run scripts/cad_experiment.exs plate blend   # the control
```

A training episode in the CAD world is the same world with a training config, and
`MONTY_CAD_LABELS=features` is what makes the part its features rather than one
object:

```sh
MONTY_CAD_LABELS=features MONTY_CAD_PART=bracket mix run scripts/cad_experiment.exs bracket
```

[The first results](cad-results.html) are the two runs above, with their pages.

## What is deliberately not here

- **No policy from the geometry.** A motor policy that knows where the features
  are decides what the experiment is meant to measure, and starves the percept: the
  sensor is driven straight at the answer and the patch stops changing. Stage 1
  and 2 step with the config's own policy, so the patches Monty learns from are
  patches a run would have collected.
- **No cluster.** Training and evaluation are one node each. What a policy host
  across nodes is for is in [plugins](plugins.html), and it is not this.
- **No numbers.** Which part, which features, how many nodes a memory holds — those
  are printed by the command that makes them rather than written down here. The one
  exception is the dated measurement in _How to run one_, which names the machine,
  the experiment and the episodes it is about.

## What is missing, in the order it is worth doing

1. **The feature wall, which is now the question rather than the plumbing.** The
   evaluation on meshes exists and runs (`cad/plate_features_eval` steps the object
   set the Make wrote, from the memory the Make wrote), and it answers a sibling:
   asked about `plate_bosses_0` it names `plate_risers_0`.

   Read off the memory itself, the four objects are not equally separable. The body
   and the risers are the same surface: `principal_curvatures_log` has mean 0.04 and
   spread 0.68 over the body's nodes against 0.00 and 0.70 over the risers', with
   the same range of about ±7. The boss (mean +2.4) and the hole (mean −2.8) differ
   by curvature _sign_, so those two are separable; the boss's own top face is flat,
   which is why a patch on it reads like the body. Colour separates nothing: every
   node's saturation is zero, and the CAD configs still report `hsv` — a channel that
   cannot change. Dropping it is a decision rather than a tidy-up: the memory holds
   it, so the teaching and the sensor change together.

   The episode follows from that: on this Mac, one `cad/plate_features_eval` episode
   at 500 steps is fed on 97 of them, and its evidence plateaus at 43.9 with four
   objects still possible. What is missing is not steps but a percept that covers an
   _edge_ for long enough to be named — which is what a parent module is for. That
   is the compositional question the set exists to ask, and it is blocked on a
   memory: `MontyCad.Training` writes one record per object and input channel, so a
   parent that holds an arrangement of its children has nothing to be taught from
   yet. The monolithic arm of the pair does exist — `cad/plate_part_eval`, one lump,
   one memory, three episodes concluded.

2. **A set of parts.** Three parts are taught and recognised (plate, blend,
   blend-big), one per experiment. A _pretraining_ set — several parts learned in
   one run, which is what Monty's pretraining configs are — is still missing.
3. **The pretraining configs.** `cad_feature_pretrain_*` (children) and the
   `_compositional` / `_monolithic` pair, which differ only in whether the labels
   name features or the part. The pair is the measurement: composition against one
   lump, everything else held. Today a feature-labelled run uses an evaluation
   config written for whole objects.
