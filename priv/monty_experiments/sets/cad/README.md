# CAD parts as Monty experiments

A CAD part's exact surface teaches a memory, and a mesh of that same part is what
the recognition run then steps. Every name here says what it holds: `plate` is
the part, `part` is what a face is labelled with, `eval` is the phase.

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

| input               | written by                                                               | lands in                                                  |
| ------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------- |
| the memory          | `MontyCad.Training.write_library/3`                                      | `<data>/monty_libraries/cad_parts_v1/plate_part.jsonl.gz` |
| the mesh object set | `MontyCad.Export.part_mesh/2` then `ExTbpMonty.Cad.Objects.write_mesh/2` | `<data>/cad_objects/plate/`                               |

The STEP file itself is the only thing in the repository:
`priv/cad_experiments/parts/plate.step`.

## The clickable steps

1. **Open `/experiments`** — every experiment this node can run, ours included.
2. **Click `cad/plate_part_eval`** — the run, named for the part, the labels and the phase, and not for anything of Monty's.
3. **Run** — the mesh world steps `plate` and the memory recognises it.
4. **Read the run page** — steps, actions and the outcome the learning module reached.
5. **Read its evidence chart** — evidence per step, climbing to the point the run concludes.

Step 3 is where the gap is: the run opens today with an **empty memory**, because
nothing writes `cad_parts_v1/plate_part.jsonl.gz` from a page yet. Until it does,
the memory is written by `scripts/cad_experiment.exs` and lands under Monty's old
names, which is the thing this set exists to stop.
