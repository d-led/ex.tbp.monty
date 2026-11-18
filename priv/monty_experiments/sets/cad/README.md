# CAD parts as Monty experiments

A CAD part's exact surface teaches a memory, and a mesh of that same part is what
the recognition run then steps. Every name here says what it holds: `plate` is
the part, `part` is a memory of the whole part, `features` is a memory of the
features it is made of, `eval` is the phase.

## What an object is called

One name, three places, so that a run steps an object its memory has an answer
for:

| where                       | the plate as one part | one of its features |
| --------------------------- | --------------------- | ------------------- |
| the memory's object id      | `plate`               | `plate_bosses_0`    |
| the object set's directory  | `plate`               | `plate_bosses_0`    |
| the config's `object_names` | `plate`               | `plate_bosses_0`    |

The geometry names a feature `bosses/0` — the record id a recognition answers
with, the part implied. A world steps one _directory_ per object, and a directory
name is not a path, so what gets written is
`<part>_<feature with its separators flattened>`: `plate_bosses_0`. The memory
says the same, because a memory answering `plate/bosses/0` while the run stepped
`plate_bosses_0` would be a memory of nothing the run asked about.
`Monty.Studio.Cad.Preparation` is where both halves are written, and
`ExTbpMonty.Cad.Objects.object_name/1` is the one rule they use.

A part's features are fixed by its geometry — the plate's are `bosses/0`,
`holes/0`, `risers/0`, and the body for the faces no feature claims — so a config
lists its objects rather than discovering them while a run is assembled.

## Which library does what

The geometry is not in this application. It arrives as dependencies, and each one
does one job:

| library                                        | job                                                                                                                                                                                               | called from           |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `ex_quiddity` (Hex)                            | opens the STEP, recognises features, samples the surface, ray-casts a frame, tessellates                                                                                                          | inside `ex_monty_cad` |
| `ex_monty_cad` (git dep, pinned in `mix.lock`) | `MontyCad.Training` writes a memory from a STEP file; `MontyCad.Export` turns exact faces into meshes; `MontyCad.Scene` is the B-rep world; `MontyCad.Library` reads and writes the memory format | this application      |
| `ExTbpMonty.Cad.Objects`                       | writes one mesh as one MuJoCo object — `textured.obj`, `texture_map.png`, `metadata.json`, in metres                                                                                              | this application      |

So the ownership of a face comes from `Quiddity.Recognition`, the points and
their features come from `MontyCad.Training`, and the triangles come from
`MontyCad.Export`; nothing here re-implements any of it.

## Where the inputs land

Both are generated, and neither is ever written into the source tree:

| input          | written by                                                                       | lands in                                                    |
| -------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| the memory     | `MontyCad.Training.write_library/3` — `labels: :part` or `:features`             | `<libraries>/cad_parts_v1/plate_part.jsonl.gz`              |
| the object set | `MontyCad.Export.part_mesh/2` or `feature_meshes/1`, then `Objects.write_mesh/2` | `<data>/cad_objects/plate/`, or `plate_bosses_0/` beside it |

The STEP file itself is the only thing in the repository:
`priv/cad_experiments/parts/plate.step`.

## The clickable steps

1. **Open `/prerequisites`** — the row `cad_part_memories` says `not built` until
   this machine has made the memories and the meshes.
2. **Click Make** — one click writes every memory the CAD configs name and the
   object set each run steps; the row says which part it is on as it goes.
3. **Open `/experiments`** — the four CAD runs: `cad/plate_part_eval`,
   `cad/plate_features_eval`, `cad/blend_part_eval`, `cad/blend-big_part_eval`.
4. **Click `cad/plate_features_eval`** — the compositional one: its memory holds
   the plate's four features, and every episode asks about one of them.
5. **Run** — the mesh world steps `plate_bosses_0`, `plate_holes_0`,
   `plate_risers_0` and `plate_body`, three rotations each.
6. **Read the run page** — steps, actions and the outcome the learning module
   reached, per object.
7. **Read its evidence chart** — evidence per step, climbing to the point the run
   concludes.

`cad/plate_part_eval` is the same question about the part as a whole, so the two
runs differ in what the memory holds and not in the geometry.

### What a feature run needs that a part run does not

Two settings, both Monty's own, and both because a feature is a centimetre across
where a plate is six:

- the motor system is `surface_curvature_informed_5_goal0` — 5 mm steps and 5°
  turns, so the patch stays on the object instead of stepping over it;
- `desired_object_distance` is 8 mm rather than 25, so the patch is mostly
  surface rather than mostly background. The observation processor passes a patch
  to a learning module only when enough of it is on the object, and at 25 mm one
  run stepped 2023 times with the learning module fed on two of them and evidence
  frozen at 1.69.

### How a feature memory is sampled

The CAD package spaces a part's visits from the part's own size, and caps the
visits at two thousand. Both are sized for a part, and a feature is a fraction of
one: at the package's defaults the plate's boss kept 56 nodes and its hole 16,
and at a finer spacing with the same cap the two disappeared from the memory
altogether, because the plate's body and risers alone spend the budget. A wall
sampled at 16 nodes is a wall reproduced as a few quadrilaterals, and a patch
that straddles it has nothing to match; the sampling below is about that.

So a memory of features is taught at 1 mm with a cap of 20 000 visits
(`Monty.Studio.Cad.Preparation`), which keeps every feature the geometry names
and converges below the cap: a part's feature memory costs a minute, and
`mix monty.data.check` still says what the tree is.

### What a feature run hits first, in the order it hits it

Three things stop `cad/plate_features_eval` before the recognition itself can be
judged, and each was found by measuring rather than reading.

**The agent starts out of sight.** The tutorial's surface agent stands ten
centimetres above the ground; a part's boss is thirteen millimetres tall, so the
patch begins eighty-seven millimetres from any surface — beyond the fifty
millimetres a surface agent's depth is clipped at — and reads a flat grey image
for as long as it takes to search. Measured on a failed run: `percepts patch`,
`inputs learning_module_0=0` on every step, and a patch picture of one colour.
The set's environment now places the agent three centimetres up, where the patch
sees the object on its first step.

**The memory and the run use different optics.** The environment's patch sensor
is declared with `zoom: 10`, a nine-degree field of view; the teacher builds its
patches with the camera's default ninety (`MontyCad.Training` passes a stand-off
and nothing else). Measured on the boss's wall at the same stand-off, the
teacher's patch reads `0.137, -0.063` with 80 % coverage and the run's reads
`0.125, 0.000` with all of it: the same sign and nearly the same size, but the
node the memory stores was measured through a patch eight times wider than the
one the run makes. The teacher needs the run's field of view.

**The memory stores a boolean where the format stores a number.** In the file,
`plate_features.jsonl.gz` holds `"pose_fully_defined": [[false], [false], …]`;
Monty's own `pretrained_ycb_v14` holds `[[1.0], [1.0], …]`. The matcher keeps its
columns as floats, so the first percept that reaches the learning module dies:

    ** (ArithmeticError) bad argument in arithmetic expression
        (ex_tbp_monty_core 0.1.4) …/evidence_matching/hypotheses.ex:406: Hypotheses.values_bytes/1

That is the writer's to fix — `MontyCad.Percept.node_features/1` should write
`1.0`/`0.0` as Monty's format does — and it is the blocker: until it is fixed no
feature episode gets past its first percept, whatever the memory holds.

### Where it stands now

The matcher runs: a feature episode builds its hypotheses, scores them, culls
them and climbs. Measured over four episodes of one run — 5000 steps each, the
ceiling the termination config gives — the module's most likely hypothesis went
`0.38 → 51.6` in the first and `0.48 → 239.65` in the fourth, both on a memory of
four feature objects, and no step raised. What the run does not do is conclude,
and the reason is upstream of the matcher:

    episode 0: 5000 steps, the module was fed 190 of them
    episode 1: 5000 steps, fed 56
    episode 2: 5000 steps, fed 177
    episode 3: 5000 steps, fed 625

A step feeds the learning module only when enough of the patch is on the object,
so a duty cycle of four per cent is the patch spending the rest of the episode
looking at background. With whole faces unread the module cannot separate the
part's body from its risers — it named `plate_risers_0` through the first two
episodes and `plate_body` through the next two, and the possible set stayed at
four — so the episode ends at the step ceiling rather than at a recognition.
That is a motor and geometry question (where the agent starts, how far it steps,
how far it stands off), not another matcher defect: with the patch on a feature a
percept is scored, and the evidence moves.

Two defects behind that were in the memory's own two readers, and both are fixed
where the fault was rather than at the caller. A feature whose values are all
empty is not mapped into the graph at all — the bore had no curvature to store
and the mapping claimed a column nothing filled, which left every row of that
graph narrower than the order it was read with, so all 96 of its nodes scored
nothing; and a grid model now answers `has_feature?` from the graph it fills
instead of `false` for every name, which had made every grid memory lose every
feature. The scoring had two of the same shape: a hypothesis with no evidence is
this port's NaN, and Elixir's `>` orders atoms after numbers, so a NaN
displaced a real evidence and the most likely object had no number to read —
`80 %` of it then raised in `evidence_update_threshold/3`, nine steps in. The
comparison asks `is_number` now, and a threshold that is not a number clears no
hypothesis, which is what `evidence >= NaN` answers for every element.

The first thing to try about the duty cycle is the gait, and it is a scale
argument of the same shape as the stand-off's: the set steps a feature a
centimetre across with `surface_curvature_informed_5_goal0`, whose action
sampler is `constant_surf_5` — `rotation_degrees: 5.0` and the sampler's own
`translation_distance: 0.004`, i.e. four millimetres a step. A crossing of a
centimetre feature is therefore two and a half steps, and the rest of the
episode is the policy walking back to it. `ConstantSampler` takes both numbers,
so a sampler of the set's own with one millimetre steps and one-degree turns is
the same kind of choice the stand-off and the zoom already are: sized for the
object rather than for the tutorial's plate, and one sampler for every feature
the part is made of. Nothing here is measured yet — the box ran out of memory
before a fifth episode — so the next session's first number is that duty cycle
under a finer gait, and the run that shows it is the same run that shows a
recognition.
