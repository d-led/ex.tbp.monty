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

### What a feature recognition is limited by: scale

`mix run scripts/cad_feature_percept.exs` prints both halves of the question, for
a part and the library taught from it: what patches on a face of each label the
recognition found read, and how many nodes of each memory object are flat.

    mix run scripts/cad_feature_percept.exs priv/cad_experiments/parts/plate.step \
      <libraries>/cad_parts_v1/plate_features.jsonl.gz

Three things come out of it, and none of them is a defect in the sensor.

**The memory and the world hold the same faces, by construction.** A feature's
object is written from the triangles whose face belongs to that feature
(`MontyCad.Export`), and its memory is taught from the samples on those same
faces — so `plate_bosses_0` is a 128-vertex, 128-face _tube_ with no cap, and its
memory is 205 nodes of that wall, not one of them flat. A boss is not closed in
this world and does not need to be: what a run is shown and what it matches
against are one surface, which is the property that matters.

**The sensor and the memory agree.** A patch on the boss's wall reads principal
curvatures of the sign and size its radius implies, and one on the bore's wall
the same for the bore — the numbers the memory stores, measured through the same
processor that taught it.

**A patch is as wide as the feature.** The patch covers about sixteen millimetres
of surface at the teacher's five-millimetre stand-off, so the boss's wall is
under two patches and the bore's wall is one; the plate's own faces are eleven or
twelve. That is what the runs show. In the episode-by-episode log of a feature
evaluation, `plate_body` concludes in a couple of hundred steps and so do the
risers, while the boss and the bore each spend the whole step budget: from about
step ten the patch reads _nothing_ — a uniform depth image, byte-identical for
the remaining four thousand steps — because the agent has stepped off a wall
eight millimetres wide and the search does not find it again.

So the limit is scale rather than shape, and no tolerance or policy will move it:
an object one patch wide gives a recognition nothing to explore and no way back
onto it once the patch is off. The two levers that follow are both honest and
both generic:

- **a patch smaller than the feature.** The footprint is the stand-off, twice
  over, so a closer stand shrinks it: the teacher's `:distance` and the run's
  `desired_object_distance` are the same dial seen from two sides, and both have
  to be set for a part of this size rather than inherited from a default sized
  for furniture.
- **parts whose features are the size Monty's sensor resolves** — a larger plate
  is not a special treatment, it is a workload whose features are several patches
  across, which is what every one of Monty's own experiments uses.
