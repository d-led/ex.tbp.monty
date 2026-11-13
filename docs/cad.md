# A CAD part in a run

A part can be the world an episode steps: `--world cad`, with `MONTY_CAD_PART`
naming the STEP file. This page says what that is, how to see it, and what is
next.

## What it is

`MontyCad.Scene` (`ex.monty.cad`) is a **scene**, not a world. The port's world
(`Monty.Simulators.Synthetic.Environment`) steps the kinematics, applies the
actions and answers the proprioceptive state; a scene answers only what a sensor
sees. So a part runs through the same world the stand-in sphere does, and only
the picture comes from CAD — one ray-cast pass over the exact B-rep
(`Quiddity.frame/2`) per sensor per step.

Three things this buys, and one it does not:

- **Exactness.** A depth is the point the surface is at, not a renderer's
  approximation of it, and the part's face ids are the recognition's own.
- **Units.** A part is millimetres and the framework is metres; the conversion is
  in the scene and nowhere else, so a policy that moves a centimetre moves a
  centimetre of part.
- **Ground truth.** The scene names the object (`primary_target/1`,
  `semantic_id_to_label/1`), which is what lets a supervised episode score itself
  against a part. The port's world used to answer `nil` unconditionally; it now
  passes a scene's answer through.
- **Not** the experiment. No config was written for a part, so every page says a
  CAD run's numbers are not the experiment's.

## Where a part comes from

The same place MuJoCo's objects come from: a directory under this node's data
root. Monty's object sets are unpacked into `MONTY_DATA` (`ycb/`,
`compositional_objects_1.4_mujoco/`, …), and a part is the same kind of input, so
it lives beside them:

```
$MONTY_DATA/parts/bracket.step
```

`MONTY_CAD_PART` is therefore a **name**, not a path — `MONTY_CAD_PART=bracket`
finds `parts/bracket.step` (or `.stp`). A path to a file that exists still works,
for a one-off part that should not have to be moved first. `Setup.cad_parts/0`
lists what the directory holds, and `Setup.cad_part_path/0` is the one answer a
page, a run and a tool share; a name that is not there says what is.

That is also where an **MCP-assisted plugin** meets the run. The CAD server's
tools already do the parts of the job that need the geometry — brief a part,
sense it, train a memory from it, describe the plugins a cluster offers — so the
flow is: the tools put a part (and, later, the library it trained) in that
directory, and the experiment a plugin encodes names it as its input. Nothing in
the studio has to know where it came from beyond the name it was given.

## Seeing it

`mix monty.run` needs `MontyCad.Scene` on the node's code path, and the studio
does not depend on `ex_monty_cad` (that package brings quiddity and its Rust
build). A script does it:

```elixir
cad = Path.expand("~/src/ex.monty.cad")

for app <- ["ex_monty_cad", "ex_quiddity"] do
  true = Code.append_path(Path.join([cad, "_build/dev/lib", app, "ebin"]))
end

System.put_env("MONTY_CAD_PART", Path.join(cad, "test/fixtures/golden_simple_through_hole.step"))

Mix.Tasks.Monty.Run.run(["base_10simobj_surf_agent", "--world", "cad", "--episodes", "1", "--steps", "400", "--no-record"])
```

`-pa` does not survive `mix`'s own code-path setup, which is why this is a script
and not a flag. On a node that carries the CAD application the world needs
nothing at all.

Measured on the fixture part: a 64×64 frame costs about 5 ms to cast, and a
400-step surf-agent episode spent 6.7 s in the world and 3.6 s in the model,
issued 3 goals, and concluded nothing — the model it loaded
(`surf_agent_1lm_10similarobj`) was trained on MuJoCo's YCB objects and this is a
bracket it has never seen. That "no conclusion" is the measurement that the next
two steps are for.

## What a scene has to answer

`render/3` takes a pose in metres and answers, for a sensor that looks along its
own −z with depth measured along that axis:

```elixir
%{
  depth: [[float()]],      # metres; 0.0 where the ray met nothing
  rgba: [[[float()]]],     # 0..1 per channel; shading, since a B-rep has no colour
  semantic: [[float()]],   # 1.0 on the part, 0.0 elsewhere
  centre: %{on_object: boolean(), depth: float() | nil, rgba: [float()] | nil}
}
```

Options are the experiment's (`:resolution`, `:zoom`, `:hfov`) and are passed
through by the world. A scene that can also answer `primary_target/1`,
`semantic_id_to_label/1` and `start_pose/2` should: the first two make a
supervised episode possible, and the third is where a sensor starts when the
scene, not a config, knows where the object is.

## What is next, in order

1. **The word `cad` is in every place a run is asked for.** Done:
   `--world cad` (the task), the experiment page's selector, the queued run's
   `Jobs.Run.world_of/1`, the MCP tool and `mix monty.readiness`. The list of
   worlds a node can step is now one answer — `Monty.Studio.Setup.worlds/0`,
   `[:mujoco, :synthetic]` plus `:cad` only when this node carries
   `ex_monty_cad` **and** `MONTY_CAD_PART` names a part — so a page cannot offer
   a world the node would refuse, and a record that names `cad` is asked for
   rather than quietly replaced by the worker's own default.

2. **The feature walk — built and tested, not yet reachable from a run.**
   `MontyCad.Policy.FeatureWalk` (`ade1dd3`, `ex.monty.cad`) walks a part to the
   features its recognition names. Each step it ray-casts from the sensor onto
   the exact surface, corrects the patch's standoff with a `MoveForward`, and
   only then takes one `MoveTangentially` towards the next target — a hole's
   centre, a boss's top; a riser is surface, not a destination. Arrival is the
   ray landing on that feature's own faces, and an empty ray is a through hole's
   aperture rather than a stop. It never reads `observations` or `percept`, which
   is the comparison against a surface policy that has only the patch.

   Held to the part by tests: the fixture is walked to both features, and no
   sideways step is taken from a wrong standoff.

   What is left is the wiring: a CAD host has to register the policy
   (`ex.monty.cad.server`'s `Cluster.register/3`, one provider process, one
   `describe/0`), and a definition has to name it as its `"motor_system"`. The
   studio needs no change for that: `RemotePolicy.among/3` asks every host,
   checks `:quiddity` and `:monty` against the host's carried tags, and refuses
   `:owner_only` on a node that cannot serve it. The control variant — a shell
   around the ported `SurfacePolicyCurvatureInformed`, `:anywhere`,
   `needs: [:monty]` — is still worth having, because it is what the finished
   140-episode run already steered by.

3. **A library the CAD world can be recognised against — a part with a pose
   recognises, a symmetric one does not conclude.** The experiment is now a
   script:
   `mix run scripts/cad_experiment.exs [parts…]`, where the last name is the part
   the world steps and every name is remembered. It writes a memory to a
   directory of its own and points `:monty_libraries_dir` at it, at the address
   the config's `model_name_or_path` already names
   (`pretrained_ycb_v14/surf_agent_1lm_10distinctobj.jsonl.gz`), so no config is
   edited to try it.

   What it has established, at the config's own 500-step cap:

   | memory                    | sensed | result                                                              |
   | ------------------------- | ------ | ------------------------------------------------------------------- |
   | plate                     | plate  | **match, 1 of 1, 483 steps**, evidence ~13, one possible pose       |
   | plate + blend             | blend  | top object right (`blend_r5` ev 6.5), **2 possible**, no conclusion |
   | plate + blend + blend-big | blend  | top object right, **3 possible**, no conclusion                     |
   | blend                     | blend  | **1 possible, no conclusion** — evidence stalls at 6.5              |
   | plate                     | blend  | **1 possible, no conclusion** — evidence stalls at 6.5 (control)    |

   One episode is an anecdote, so the question the table asks is a rate.
   `CAD_SEED=<n>` runs a chosen seed, and the seed is the only thing a sweep
   varies — the world starts in the pose the _part_ decides
   (`Setup.world/4` reads it from `MontyCad.Scene.start_pose/1`, not from the
   config's start pose), so every seed sees the same first picture and what
   differs is the exploration the policy draws:

   | part  | shape                        | seeds that recognised, of ten |
   | ----- | ---------------------------- | ----------------------------- |
   | plate | boss and an off-centre hole  | **4** — seeds 1, 3, 5, 7      |
   | blend | a 40 × 30 × 20 rounded block | **0**                         |

   The control row is what makes the rest of the table readable.
   `CAD_SENSE_ONLY=1` leaves the sensed part out of the memory, and the answer
   is _no conclusion_ rather than a confident wrong name: the run did not
   recognise a part it was never shown, which is the thing a library of one's
   own parts must be able to say.

   Why the blend never concludes, read from the module's own rule. Recognition
   needs one object left **and** a pose it can name —
   `EvidenceGraphLM.check_terminal_condition/1` asks
   `get_unique_pose_if_available/2`, which answers a pose only when
   `unique_pose?/4` holds or a symmetry has been counted. The blend keeps one
   object and twenty-seven distinct rotations at step 500; the plate keeps
   forty-two and still concludes, because its hypotheses agree on the pose in
   the way that rule asks about. A rounded block's faces say the same thing to
   this sensor — flat, one colour, log curvature near zero — so the rotations
   that carry one face onto another never separate. The blend is not
   unrecognised; it is recognised as a shape whose orientation this percept
   cannot name.

   `scripts/probe_cad_poses.exs` is that answer, on demand:

       CAD_LIBRARY=/tmp/cad-experiment/blend \
       MONTY_CAD_PART=…/blend_r5.step mix run scripts/probe_cad_poses.exs

   It steps under the config's own recognition policy and prints the terminal
   state, the objects still possible, and the distinct rotations left per
   object — which is the difference between "not recognised" and "recognised,
   and this many ways round".

   **A library of two named the wrong one — until the memory was sampled for a
   library.** `plate-big` and `plate-huge` are the plate at 1.5× and at 5×,
   derived in the script rather than checked in — every point _and_ every
   radius scaled, which is why they open as the same solid: nine faces,
   eighteen edges, one valid shell, 90 × 75 × 27 mm and 300 × 250 × 90 against
   the plate's 60 × 50 × 18. Two parts differing in one thing only, size, is
   the pair a matching test should tell apart, and both have a pose worth
   naming.

   With the memory written the way a single part is written — an absolute 2 mm
   sampling spacing — sensing the large part concluded the **small** one:

   | memory            | sensed     | result over seeds 1, 3, 5, 7                               |
   | ----------------- | ---------- | ---------------------------------------------------------- |
   | plate, plate-big  | plate-big  | 2 concluded, **both naming "plate"** (evidence 12.0)       |
   | plate, plate-huge | plate-huge | 3 concluded, **two naming "plate"** (15.5, 5.2); one right |

   That the 5× pair is _worse_ than the 1.5× pair is what rules out the obvious
   explanation. `principal_curvatures_log` is compared with a tolerance of 1.0
   and a scale `s` moves a curvature by `log s`, so 1.5× (0.41) should be the
   hard case and 5× (1.6) the easy one; if feature tolerance were the cause, the
   bigger pair would have been separated, not confused more confidently.

   **The cause was the memory's node count, which is ours.** A fixed spacing
   gives the 5× part the same number of nodes over twenty-five times the area,
   so a library of two sizes was also a library of two densities, and the
   candidate search is a radius: the denser graph has more nodes within
   `max_match_distance` of every percept, so it has more chances of a
   well-matched hypothesis. Nothing about the LM prefers the small part; the
   library asked a question about density and answered it.

   Sampling each part at its own scale's spacing gives two memories of about
   the same size: 1557 and 1581 nodes at 1.5×, 1557 and 1602 at 5×. Then both
   questions come out right, and with more evidence than either wrong answer
   had:

   | memory            | sensed     | result over seeds 1, 3, 5, 7                                               |
   | ----------------- | ---------- | -------------------------------------------------------------------------- |
   | plate, plate-big  | plate-big  | **"plate-big" on top in all four**; 1 concluded (12.5), 3 held at 6.2–26.6 |
   | plate, plate-huge | plate-huge | **"plate-huge" on top in all four**; 3 concluded (16.3, 39.8, 33.9)        |

   The rule is one sentence rather than a table of scales: never finer than two
   millimetres, never coarser than the part's largest extent over thirty. A
   60 mm plate is 2.0 mm either way, so every single-part measurement above
   stands unchanged; a part five times the size is sampled at 10 mm and gets a
   memory of the same size. The script does that by default now, and
   `CAD_ABSOLUTE_SPACING=1` writes the fixed 2 mm that produced the wrong
   answers, because a rate over seeds that changed two things would say
   nothing.

   Two things this leaves standing. A right answer is still seed-dependent —
   the plate is recognised in 4 of 10 seeds on its own — and a symmetric part
   still never concludes. Both are questions about evidence and exploration,
   and neither is about which part was named. The lesson that belongs in
   `ex.monty.cad` is narrower and is written down here because it was learned
   the hard way: `Training`'s `:spacing` is an absolute number of millimetres,
   which is right for one part and wrong for a library, and a library builder
   has to choose it so that every part in it is sampled at the same resolution
   relative to itself. Every number in this document before this section was
   written with the absolute dial, which is why they are single-part numbers.

   Two readings from an earlier pass of this document were wrong, and the
   measurement is what corrected them. The curvature in a CAD-written memory is
   not anomalous: `principal_curvatures_log` spans −6.85 … 7.22 here, and
   Monty's own pretrained graphs span −8.31 … 8.12 with 73 % of their values
   implying |κ| > 5 (`priv/monty/libraries/pretrained_ycb_v13/…`, all ten
   objects). The earlier "about −5 … 2" came from reading one node of one
   object. And `pose_fully_defined` is written as a one-element list —
   `[false]`, `[true]` — which is the arity Monty's export uses, and it is
   loaded into the graph as a plain boolean (visible in the module's own graph
   rows), so nothing reads `[false]` as true.

   So the next question is not "which part is this" but "which parts have a
   pose worth naming". The plate does and the blends do not, and the library a
   recognition run is aimed at therefore has to hold parts with a boss, a hole,
   an off-centre feature — the things that break the symmetry. That is a
   statement about the parts, and it is the one that `docs/cad.md`'s item 4
   has to be built on. The plate's six failing seeds are the other half: same
   part, same start, half the explorations find it inside the config's budget,
   so either the exploration is too slow for these parts or the evidence needs
   more steps than the borrowed config allows.

   One measurement kept because the similar-pair question will need it: the two
   blends are not near-duplicates. `blend_r5` is 40 × 30 × 20 mm and
   `blend_r5_enlarged` is 270 × 100 × 100 mm, and a memory written from each
   carries its own scale — the earlier reading that found them identical had
   measured a folder that held neither of them.

   Two defects had to be found for the single-object result, and both were ours
   rather than the port's. `pose_vectors` were written as three rows of three,
   while a graph column holds numbers and
   `GraphMemory.get_rotation_features_at_nodes/4` chunks a value by three — so
   every value was one level deeper than the reader assumed and the episode died
   in burst sampling aligning a matrix against `[[matrix]]` (`a8628fe` in
   `ex.monty.cad`, with the shape now stated in the percept and in the library
   format cases). And the run needs the 500-step cap: at 400 it is still
   converging, which is information about the experiment rather than a bug.

4. **A part per episode.** A CAD world steps one part; the object-per-episode
   interfaces walk a list. That is where "ten similar parts" becomes an
   experiment rather than a demonstration.
