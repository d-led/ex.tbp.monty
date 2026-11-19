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

   The click is idempotent: each memory keeps a note of the part file's bytes,
   the optics and the sampling it was written from, so a second click teaches
   only what changed — a new part file, a new stand-off, a deleted memory — and
   the row says "already taught from the same inputs" for the rest. Measured on
   this Mac (2026-11-19): the five memories cost 691.6 s the first time and 0.1 s
   the second, with the same node counts (1 435, 14 713, 34 018, 5 835, 2 113),
   so what a skip saves is the geometry and not the answer.

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

   That pair is not optional, and a run says so. Dropping the channel from the
   _reader_ alone — a module whose tolerances name only
   `principal_curvatures_log`, against the memory as it is — dies on its first
   hypothesis, in the evidence calculator: `key "hsv" not found`. The list of
   features a module uses is derived from its tolerances
   (`features_to_use`, taken from `matched_features(tolerances)`), so a module
   without an `hsv` tolerance still reads a memory whose rows carry an `hsv`
   column, and the column it does not name is a key it cannot find. A
   curvature-only arm therefore needs a memory taught without the channel, which
   is `MontyCad.Training`'s feature list and not a config: the pair changes
   together, or neither changes.

   The episode follows from that: on this Mac, one `cad/plate_features_eval` episode
   at 500 steps is fed on 97 of them, and its evidence plateaus at 43.9 with four
   objects still possible. What is missing is not steps but a percept that covers an
   _edge_ for long enough to be named — which is what a parent module is for. That
   is the compositional question the set exists to ask, and it is blocked on a
   memory: `MontyCad.Training` writes one record per object and input channel, so a
   parent that holds an arrangement of its children has nothing to be taught from
   yet. The monolithic arm of the pair does exist — `cad/plate_part_eval`, one lump,
   one memory, three episodes concluded.

   What a parent needs is smaller than it sounds, and Monty says so: its own
   compositional experiment (`base_infer_cows_large_compositional_random_locs` in
   the upstream snapshots) runs `MontyForEvidenceGraphMatching` — the class every
   run here already uses. The composition is in the data and the memory: scenes
   whose objects are made of parts, and a pretrained memory of those compositions.
   So nothing needs porting for this arm, and two of its three arms are already on
   the page: one lump (`plate_part_eval`) and one object per feature
   (`plate_features_eval`, with `parts_set_eval` as the set). What is missing is a
   memory taught on an _assembly_ — the plate with its boss and risers placed as
   the STEP file places them — sampled in the assembly's frame rather than one
   part at a time. That is `MontyCad.Training`'s sampling and the CAD world's
   placement, not a config.

   One detail decides how that sampler is written, and it is worth stating before
   somebody starts: a graph node is not a point. It is a location _and_ a feature
   map whose `pose_vectors` hold the surface's normal and tangents in the frame
   the sensor reported them in. Composing parts therefore transforms a node's
   location **and** rotates the vectors inside its features — and both halves must
   agree, or the parent's graph says a face looks one way while sitting another.
   The parts also have to be taught through the same optics the parent is taught
   through, since the parent's nodes are those parts' nodes, moved. A placement
   that is only a translation is the cheap first case: the normals survive it,
   which is why an assembly of parts laid side by side is a smaller change than
   an assembly of parts turned.

2. **A set of parts, taught and loaded but not yet told apart.** One memory can
   now hold several parts: a memory whose name ends in `_set` is taught from the
   objects its experiment names (`Monty.Studio.Cad.Preparation` reads
   `object_names`), and `cad/parts_set_eval` is the first one — the plate and the
   blend in one file, each stepped as its own episode, which is the CAD
   counterpart of the distinct-object configs the YCB benchmarks use.

   What it measures so far, on this Mac on 2026-11-19, world `ex_mujoco`, two
   episodes of 500 steps at the blend's own 8 mm stand-off: the memory is written
   (34 018 nodes over the two parts, 467 s of teaching, which is most of the
   twelve minutes one Make click now takes), and both episodes narrow to _one_
   possible object and never conclude — the one they name is `plate`, including
   the episode whose target is the blend. Two parts in one file therefore do not
   yet separate: the memory is fine-grained enough for either to match, and what
   decides between them is not in it.

   The teaching itself is not what fails, and that is worth knowing before
   touching it: the blend's record inside `parts_set` holds exactly the same
   `positions` and `features` as the `blend_part` memory that recognises the
   blend on its own (compared record by record, 2026-11-19). The only difference
   between the memory that works and the memory that does not is the plate's
   record beside it. So the question is competition, and it is a percept question
   of the same kind as the feature wall above: one part per memory still
   concludes, three times over.

   Run the same way from the experiment page — two episodes, 500 steps each, one
   node, `ex_mujoco` — and the run's own `eval_stats.csv` adds one fact: of the
   500 steps each episode took, the sensor fed a percept on 110 of the plate's and
   72 of the blend's (`num_steps`, the column the page labels "sensor steps"), and
   the row carries `patch_off_object`. That is not by itself what fails: the
   single-part run that works, `cad/blend_part_eval` started from the same page,
   feeds 25 of its 178 steps and still concludes `blend`, correct. Sparse feeding
   is how this optics behaves; what the set lacks is the conclusion, and the
   belief standing when the patch last saw the part is reported 500 steps later —
   `plate` in both episodes.

   The stand-off is the set's cost driver: memory sampling follows the patch, so
   a two-part memory at 8 mm is four times the nodes of the same parts at 16 mm
   — 34 018 against 8 535, 467 s against 74 s of teaching, both measured on this
   Mac on 2026-11-19. It is not the lever for separation. A one-off config at
   16 mm with a 2 mm/2° gait, stepped over the same two episodes, answers the
   same way: `plate`, one possible object, no conclusion. So the cost cannot be
   bought back that way, and what decides between the two parts is not the
   patch's size but which patch the policy collects: a flat face is a flat face,
   and the plate has 2.3 times the blend's nodes of it. That is the same percept
   question as the feature wall above — an edge has to be held long enough to be
   named — and it is why a set is not a config change away.

3. **The pretraining configs, and the wall in front of them.** `cad_feature_pretrain_*`
   (children) and the `_compositional` / `_monolithic` pair, which differ only in
   whether the labels name features or the part. The pair is the measurement:
   composition against one lump, everything else held. Today a feature-labelled run
   uses an evaluation config written for whole objects.

   Every CAD experiment here recognises a memory the _B-rep teacher_ wrote; none
   learns a part from its own percepts, which is the other half of the question and
   what Monty's pretraining experiments are for. A config for it composes cleanly —
   `MontySupervisedObjectPretrainingExperiment`, the CAD world, a supervised episode
   per rotation of `plate`, no findings from `Monty.Studio.Setup` — and the run
   dies at its third step:

   ```
   LM_0 is a bare GraphLM, which has no matching scheme to narrow possible
   matches with; a subclass supplies one
   ```

   That is the same sentence for both module pairings tried (the evaluation configs'
   `evidence_tutorial_surf_agent_2obj` + `camera_tutorial_surf_agent_2obj`, and the
   dog corpus's `graph_1lm` + `camera_surf_rgba` which trains there). The answer is
   the first of the two candidates, and it is Monty's own order rather than a defect
   of the port: **a training episode begins by matching.** Monty's model starts in
   its matching step whatever the phase, and a training episode's termination check
   answers `no_match` at once — which is what names the thing being learned
   (`GraphLM.set_detected_object` turns `no_match` into `new_object<n>`), after which
   the episode turns to exploring, buffers what the sensor saw, and writes it at the
   end (`update_ltm_from_stm`, gated on the buffer and on that name). A module
   without a matching scheme therefore cannot be a training target _at all_, which is
   why the port raises instead of pretending to narrow: the module the CAD training
   config names must be one with a matching scheme. `test/monty/studio/run_test.exs`
   ("a training episode writes what it saw") is that whole sequence, held at the
   level a config cannot fake. The referee is a one-episode run of a part that ends
   with a library at `<libraries>/cad_parts_v1/plate_learned`. Neither config is
   shipped while it crashes: a page offering a run that dies is worse than a page
   with no run.

   This was checked the other way round too, and the check is worth keeping: making a
   training run start in its exploring step reads like the obvious repair, and it
   does silence the raise — but three behaviours go with it. A training episode then
   never concludes, so it never names the object it walked, so `update_ltm` writes
   nothing: `Run.update_ltm` on the ten-object config leaves an empty memory where it
   used to write `new_object0`. Exploratory steps do not narrow, so nothing replaces
   the name. The rule that a training run starts matching is load-bearing, not an
   accident of the step machine.

   What that leaves is narrower than it was, and one thing in it is unexplained. The
   evaluation pairing the CAD configs already use (`plate_part_eval.yaml` names
   `/monty/learning_module: evidence_tutorial_surf_agent_2obj`, an evidence-matching
   module, and its runs conclude) ought to train for the same reason — so a pretrain
   config built from it should not raise. It did, in the run recorded above. The
   first thing to print for any candidate is therefore the module the config
   _resolved to_, not the one it names: `Monty.Studio.open/1`'s setup carries each
   learning module's class, and a `defaults:` merge that keeps `/monty`'s graph
   module would explain the same sentence with a config that reads correct.
   That was it. A config built on `/monty: evidencegraph_exp1000_emin_t3` and
   `/monty/learning_module: evidence_tutorial_surf_agent_2obj` resolves to
   `EvidenceGraphLM` and steps: the earlier trial had taken `/monty:
graph_exp500_e3_t3`, whose `learning_module_configs` are the bare graph pairing,
   so the group it named was never the module it built. Two walls stood behind the
   first, and both are now measured rather than guessed. The episode-end write
   crashed, because the runtime clears a training module's hypotheses before it
   writes and an evidence module held no clause for it
   (`EvidenceGraphLM.clear_hypotheses/1` — a port-only guard, so it is not one of
   Monty's cases; the case lives beside the evidence module's own tests). With that
   clause the episode runs all four hundred steps and ends cleanly, and reports the
   next wall in numbers a reader can see in one line: `the memory now holds 0
objects and 0 nodes`, with every step logging `goals 0`. The motor policy the
   evaluation config names asks the module for a goal, and a module with nothing
   to match against has none to give, so the sensor stood still and the buffer
   stayed empty. Monty's naive scan is the policy of the other kind —
   `use_goal_driven_actions: false`, a sweep of the view sphere that asks for
   nothing — and with it every step logs `inputs learning_module_0=1`.

   The last piece is the one a reader is most likely to copy wrong, because an
   evaluation config has it empty and looks complete: `supervised_lm_ids`. Monty's
   `_pass_target_info_to_model` gives a named module the target's object name,
   pose and place on the model, and **wipes the hypotheses of every module it does
   not name**; a training run whose list is empty therefore teaches nothing,
   silently, and reports a clean episode. Naming the module is also what makes the
   write a supervised one: the memory is filed under `plate`, the name the
   experiment knows, rather than under the `new_object0` a module with an empty
   memory would have guessed. With those three things right —
   `EvidenceGraphLM`, `naive_scan_5`, `supervised_lm_ids: [learning_module_0]` —
   `cad/plate_pretrain` runs one episode over MuJoCo and ends with `the memory now
holds 1 object and 14 nodes` and a library written under
   `cad_plate_pretrain`. The arm is a config, and every part of it was measured.
   The loop is closed by one more config and no further code:
   `cad/plate_learned_eval` is the evaluation config with its
   `model_name_or_path` naming `trained/cad_plate_pretrain` — the memory the
   training run wrote — instead of the teacher's under `cad_parts_v1/`. One
   episode over MuJoCo matched in eighty steps with ten goals: a part recognised
   from percepts it taught itself. Two runs, one memory, and the only difference
   between "taught" and "learned" is which file the config names.

4. **A memory taught from other inputs is named, but only from now on.** A CAD
   memory records the part file's bytes, the optics, the sampling and the CAD
   packages' versions, and `Monty.Studio.Setup.memory_findings/1` warns when the
   note and the config disagree — with the day, the input that moved when the note
   kept the numbers ("a patch this config reads from 8.0 mm through 11.4°, where
   the memory was taught from 25.0 mm through 11.4°"), and a **Teach it again**
   button on that page: the prerequisites row cannot help here, because it says
   "present" — the memory is there, what is wrong is what it was taught from. That
   is the shape of the defect that cost an afternoon earlier
   (`cad/blend_part_eval` taught through one stand-off and stepped through
   another): the warning catches it, the numbers turn it into an instruction, and
   the click is where the instruction is. A note written before the inputs were
   kept still says only _that_ one moved — one Make click upgrades it, because the
   same click re-teaches anything whose fingerprint cannot be reproduced.
