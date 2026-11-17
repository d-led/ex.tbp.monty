# A CAD part in a run

Three stages, one question: **can Monty learn what a part is from a perfect
sensor, and then recognise it from an ordinary one?**

The perfect sensor is a STEP part, ray-cast exactly, with the part's features
named by the recognition rather than guessed. The ordinary one is the same part
as a textured mesh in MuJoCo, which is what every other Monty run senses. Between
them they measure the thing worth measuring — what Monty's own learning and
evidence do, once the labels and the geometry stop being the hard part.

## The three stages

| Stage | World | Memory | What it answers |
| --- | --- | --- | --- |
| **1. Learn features** | one part, `--world cad`, labels from the recognition | written, one label per feature | does a graph trained on exact geometry hold a hole, a boss, a fillet as an object? |
| **2. Learn the composition** | the same parts, several features each | written, per-feature children plus the part above them | can the part be recognised as an arrangement of features rather than as one lump? |
| **3. Recognise on meshes** | MuJoCo, the same parts as textured meshes | **read** — the file stage 1 and 2 wrote | does the memory survive the change of world, with no CAD on the node at all? |

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

## Where a part comes from

`$MONTY_DATA/parts/` — `bracket.step` or `bracket.stp`, plain or gzipped — is the
same place MuJoCo's object sets come from, and `MONTY_CAD_PART` names one by name
rather than by path (`MontyCad.Inputs.part_path/1`). A path to a file that exists
still works, for a part that should not have to be moved first.

A *set* of parts is what a pretraining run needs, and a run currently opens the one
part the variable names. That is the first thing stage 1 has to grow.

## How to run one

`mix monty.run` needs the CAD package on the node's code path; the studio does not
depend on it, because it brings a Rust build. A script does it:

```elixir
cad = Path.expand("~/src/ex.monty.cad")

for app <- ["ex_monty_cad", "ex_quiddity"] do
  true = Code.append_path(Path.join([cad, "_build/dev/lib", app, "ebin"]))
end

System.put_env("MONTY_CAD_PART", "bracket")

Mix.Tasks.Monty.Run.run(["base_10simobj_surf_agent", "--world", "cad", "--episodes", "1", "--no-record"])
```

`-pa` does not survive `mix`'s own code-path setup, which is why this is a script
and not a flag. On a node that carries the CAD application the world needs nothing
at all.

## What is deliberately not here

- **No policy from the geometry.** A motor policy that knows where the features
  are decides what the experiment is meant to measure, and starves the percept: the
  sensor is driven straight at the answer and the patch stops changing. Stage 1
  and 2 step with the config's own policy, so the patches Monty learns from are
  patches a run would have collected.
- **No cluster.** Training and evaluation are one node each. What a policy host
  across nodes is for is in [plugins](plugins.html), and it is not this.
- **No numbers.** Which part, which features, how many nodes a memory holds — those
  are printed by the command that makes them, not written down here.

## What is missing, in the order it is worth doing

1. **Per-feature semantic ids.** `MontyCad.Scene` carries one id for the whole
   part. `Quiddity.Frame.face_ids/1` and `Quiddity.Recognition.owner/2` already
   answer which feature a pixel is on, so the ids are a change in one module, and
   `semantic_id_to_label` — which a run already threads through — names them.
2. **A set of parts.** Stage 1 wants several features across several parts, and a
   run names one.
3. **The pretraining configs.** `cad_feature_pretrain_*` (children) and the
   `_compositional` / `_monolithic` pair, which differ only in whether the labels
   name features or the part. The pair is the measurement: composition against one
   lump, everything else held.
4. **The mesh export.** Stage 3 needs those parts tessellated with a texture and
   per-feature geometry ids, and `Quiddity.mesh/2` returns `face_of_triangle`,
   which is what carries a label from a face onto triangles.
