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
one: at the package's defaults the plate's boss kept 56 nodes and its hole 16 —
few enough that the recognition answered the hole while stepping the boss — and
at a finer spacing with the same cap the two disappeared from the memory
altogether, because the plate's body and risers alone spend the budget.

So a memory of features is taught at 1 mm with a cap of 20 000 visits
(`Monty.Studio.Cad.Preparation`), which keeps every feature the geometry names
and converges below the cap: a part's feature memory costs a minute, and
`mix monty.data.check` still says what the tree is.

### What a feature recognition needs from the sensor

A feature memory and a feature run have to speak about the same things. The
memory carries Monty's whole patch feature set, curvature included, and it
separates a convex feature from a concave one clearly: the plate's boss is mostly
positive principal curvature, its bore mostly negative.

The run's sensor module does not compute curvature at all. Its patch reports the
pose vectors, the depth statistics, the coverage and the colour, so the learning
module is left matching on surface orientation alone — and a ring standing out of
a plate and a ring cut into one have the same orientation pattern, one scale
apart. That is a gap in the port rather than a property of these shapes, and it
is generic: no object, of any shape, can be separated by a feature the sensor
never measures.

So the next change for this set is not a config value but the missing feature: a
patch's principal curvatures, computed the way Monty's own sensor module computes
them, and offered to the learning module beside the others.
