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

   What is left is the wiring, and now it has a name rather than a shape: a run
   picks a policy up from **`MONTY_REMOTE_POLICY`**, which `RemotePolicy.configured/0`
   reads and `RemotePolicy.find/1` resolves over `:pg` (`MontyPlugin.Registry`),
   checking `:quiddity` and `:monty` against what the host proves it carries and
   refusing `:owner_only` on a node that cannot serve it. So one node runs
   `ex.monty.cad.server` with `MONTY_CAD_PART` set — the provider opens the part
   itself, and `:owner_only` is exactly the claim that the B-rep handle is a
   resource of that node's memory — and the node that runs the experiment is
   given `MONTY_REMOTE_POLICY=monty_cad.feature_walk`.

   The shortcut of hosting the provider inside the experiment script does not
   work and it is worth saying why, because it looks like it should: the script
   appends the sibling builds from this checkout, while `ex.monty.cad.server` is
   built against whichever release Hex holds (0.6.1 today) — two builds of one
   module set in one node. The designed path is two nodes in one cluster —
   `docs/cluster.md` has both on one machine.

   One thing the provider node has to say out loud, because placement decides
   from tags and not from what a node can actually step: a run recorded with
   `world: "cad"` needs `world:cad` (`Placement.needs/1` builds that tag from the
   record's own world, exempting only the stand-in scene), and a node's tags are
   `monty` plus whatever `MONTY_CAPABILITIES` adds. So the node that opens parts
   declares `MONTY_CAPABILITIES=world:cad`. Without it nothing is misplaced —
   placement's third answer performs the run where it was asked for, because a
   tag nobody declared must not hold a run hostage — and a node with neither the
   package nor a named part then fails it.

   The comparison is already set up and it needs nothing built: every run above
   was steered by `/monty/motor_system_config: surface_curvature_informed_goal1`,
   which is the ported `SurfacePolicyCurvatureInformed` reading only the patch.
   That is the control. What `FeatureWalk` adds is the geometry, so a difference
   between the two is the geometry's and not the policy's. A provider shell
   around the curvature policy would re-prove what `remote_policy_test.exs`
   already steps through two episodes with a stand-in — that the seam carries a
   policy, and carries two at once without one advancing the other — and would
   walk the part no differently from the config it wraps.

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

   What the six failing seeds fail at, asked of the runs themselves. The plate
   against its own memory, probed with `CAD_SEED` on three of them:

   | seed | steps | terminal | objects possible | distinct rotations left |
   | ---- | ----- | -------- | ---------------- | ----------------------- |
   | 0    | 500   | nil      | `["plate"]`      | 1099                    |
   | 2    | 500   | nil      | `["plate"]`      | 8                       |
   | 4    | 500   | nil      | `["plate"]`      | 58                      |
   | 1    | 418   | `:match` | `["plate"]`      | 339                     |

   So the part is identified in every one of them — the right object is the only
   one left after five hundred steps — and what does not happen is the pose
   settling. Recognition is a conjunction: one object _and_ a nameable pose, and
   on these seeds only the first half arrives inside the config's own budget.

   The rule that decides it is worth saying in its own terms, because "pose not
   settled" sounds like a knob: `unique_pose?/4` answers true only when **every**
   remaining possible hypothesis is within `path_similarity_threshold` of the
   centre of their locations **and** within `pose_similarity_threshold` of the
   most likely rotation. Both are the module's defaults — 0.1 m and 0.35 rad
   (20°) — and no config here overrides them. A plate 60 mm across cannot fail
   the first: the whole part is inside 100 mm of its own centre. So what decides
   these six seeds is the 20°: at the last step some possible hypothesis still
   disagrees with the most likely rotation by more than that, and one hypothesis
   is enough to keep the episode open.

   Where the disagreement is, measured. The probe turns the rule into two
   numbers — how many possible hypotheses there are, and the largest turn any of
   them needs to become the most likely one:

   | seed | outcome  | possible hypotheses | distinct rotations | largest turn |
   | ---- | -------- | ------------------- | ------------------ | ------------ |
   | 0    | nil      | 51                  | 4                  | **180.0°**   |
   | 1    | `:match` | 3                   | 1                  | 0.0°         |

   A failing seed keeps a hypothesis a **half turn** away from the best one, and
   a flat patch cannot rule that out: in its own plane a plane has no direction,
   so the two look identical until something curved is seen. The passing seed
   ends with a single rotation and nothing to disagree with.

   Why the memory is so short of orientation, and it is ours to state plainly:
   `pose_fully_defined` is true on **233 of the plate's 1557 nodes (15 %)**,
   while Monty's own pretrained graphs carry it on **13 416 of 15 679 (85 %)**.
   Both numbers come from the same rule: the two principal curvatures must
   differ by more than `pc1_is_pc2_threshold`, which is 10 m⁻¹ — a curvature
   radius of ten centimetres. An exactly flat CAD face has nought for both, so
   their difference is nought and the rule says, correctly, that the face has no
   orientation. A depth camera never reports nought: its noise makes almost every
   node anisotropic, and that is how a real memory comes to be 85 % pose-defined.
   Our memory is the honest one, and the honest one has less to match on. (The
   earlier paragraph about `pose_fully_defined` is about its _shape_ in the file,
   which is right; this is about how often it is true.)

   Counted per part, over the memories the runs above wrote, the share is the
   part's and not CAD's:

   | part       | nodes | pose-defined |
   | ---------- | ----- | ------------ |
   | plate      | 1557  | 233 (15 %)   |
   | blend      | 947   | 136 (14 %)   |
   | plate-big  | 1581  | 186 (12 %)   |
   | plate-huge | 1602  | 107 (7 %)    |

   Those counts are the rule and nothing else: for each part the number of nodes
   whose two principal curvatures differ by at least the threshold is _exactly_
   the number the flag is true on — 233, 136, 186, 107 — so the flag can be
   recomputed from the file rather than taken on trust.

   The scaled twins are where the rule stops being about shape. Sampling each
   part at its own spacing gives them the plate's node count but not its share
   of orientable surface, and the reason is arithmetic uniform scaling makes
   unavoidable: the typical curvature difference among the curved nodes is
   131 m⁻¹ on the plate, 85 at 1.5× and 25 at 5× — divided by the scale, as
   `1 / radius` must be, to within a few per cent — so a part five times the
   size sits five times closer to a threshold that did not move. `plate-huge`
   holds seventeen nodes between nought and the threshold, several at
   9.7–9.9 m⁻¹; the plate holds eight, and none above 8.3.
   `pc1_is_pc2_threshold` is an absolute curvature, so _which_ parts can be
   oriented at all depends on their size — equal node counts are not equal
   memories.

   So a part made mostly of flat faces can only be oriented by the geometry that
   is not flat — the boss and the through hole here — and whether a run finds
   them is what these six seeds are deciding. That is exactly what
   `MontyCad.Policy.FeatureWalk` exists to guarantee (`docs/cad.md`'s item 2):
   walk to the features the part's recognition names, rather than wherever the
   generic surface policy happens to drift. The next experiment is that one,
   and it is a wiring job rather than a measurement.

   The last column is the probe's honest negative result: the size of the
   rotation set does **not** separate the two outcomes — 8 and 1099 both fail,
   339 passes — so it is not a proxy for `unique_pose?/4` and should not be read
   as one. It is printed because it is what the module can be asked for from
   outside, not because it explains anything.

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
   object and twenty-seven distinct rotations at step 500, and the count is not
   itself the signal — a plate seed fails with four, and one settles with one
   (below). What matters is whether the surviving hypotheses _agree_. The blend
   is not unrecognised: it is recognised as a shape whose orientation this
   percept cannot name. Not for want of curved surface — its memory is 136 of
   947 nodes pose-defined, 14 %, the plate's rate to within a point — but
   because the orientation is genuinely not unique, which the memory can be
   asked. Turn it by a half turn about each of the block's three principal axes
   and ask every node whether the turned point has a partner agreeing with it on
   position (within two spacings), on normal (within 15°) and on log curvature
   (within the matcher's 1.0):

   | part       | keeps a partner, per half turn | keeps none under any |
   | ---------- | ------------------------------ | -------------------- |
   | blend      | 99.7 %, 99.5 %, 99.6 %         | 1 of 947 (0.1 %)     |
   | plate      | 74.2 %, 72.1 %, 76.0 %         | 246 of 1557 (16 %)   |
   | plate-huge | 84.8 %, 81.1 %, 82.6 %         | 153 of 1602 (10 %)   |

   The two columns ask different questions and the second is the one that
   decides. A node keeping a partner under one half turn says nothing about the
   next; a node keeping none under _any_ of the three is evidence that separates
   all four placements, which is what a conclusion needs. The block has one such
   node in 947.

   The block maps onto itself, node for node. Its four orientations are one
   picture to the matcher, and a half turn is 180° where `unique_pose?/4` asks
   for 20°, so the pose rule cannot settle it. The plate is the opposite case by
   246 nodes of its 1557: its hole and its boss keep no twin under any half turn,
   and those are what tells its four orientations apart. What the seed table is
   then spending is how often an exploration sees enough of that
   246 inside the step budget.

   The probe's twenty-seven rotations and these four placements are two
   different statements and both are true: twenty-seven is how many hypotheses
   the search still holds at step 500, and four is how many positions of this
   solid no evidence can tell apart. What the symmetry test adds is which of the
   two the twenty-seven are arguing about — one node in 947 is not enough to
   separate the four, and no further sampling of the same surface will produce
   what the surface does not have.

   **The symmetry rule is the way out, and in this world it never fires.**
   `unique_pose?/4` failing is not the last word: `check_for_symmetry/4` accepts
   a pose after `required_symmetry_evidence` (5) consecutive steps in which more
   than 90 % of the possible hypotheses were possible the step before. The probe
   now prints that counter, and what it is gated on, per step:

   | part  | steps above 0.9 overlap | steps counted as a new observation | counter reached |
   | ----- | ----------------------- | ---------------------------------- | --------------- |
   | blend | 64 of 76                | **2 of 77**                        | 0 of 5          |
   | plate | 63 of 76                | **7 of 77**                        | 0 of 5          |

   The overlap rule is satisfied on four steps in five. The second column is why
   that makes no difference: `check_for_symmetry/4` only counts a step where the
   buffer says the observation reached the module, and in a CAD run it almost
   never did. The chain is four links, each one ours to read:

   1. `FeatureChangeFilter` sets `process_features_in_lm: false` when a patch has
      not changed enough to be worth learning
      (`feature_change_filter.ex`, `significant?`), which makes the percept a
      location-only message.
   2. `Monty.Runtime.location_only_step?/1` is true when every sensor percept is
      like that.
   3. `record_processing/2` then writes `lm_processed_steps` false, and
      `get_last_obs_processed/1` reports false with it.
   4. `get_unique_pose_if_available/2` hands that flag to `check_for_symmetry/4`
      as `increment_evidence?`, so the counter is not even asked to move — the
      docstring there says why: a step that saw nothing new cannot be evidence
      of symmetry.

   So the blend's nought of ten is neither the pose rule working nor the
   exploration failing: the hatch that exists for a symmetric part is starved,
   because a patch on a symmetric part is exactly the patch that looks like the
   last one.

   Two numbers make that a configuration rather than a coincidence, and both are
   Monty's own. The filter's `delta_thresholds` say a patch passes when the
   sensor moved `0.01` m or the surface turned `π/4`, and the config's policy
   steps about four millimetres across a face that turns nought — neither. What
   is left is `n_steps: 20`, which sends the patch anyway after twenty quiet
   steps, so processed steps arrive roughly twenty apart. The counter needs
   `required_symmetry_evidence` of them **consecutively** — 5 here, which is
   Monty's default, though its own YCB configs ask for 20 — and no cadence that
   waits for twenty can supply five in a row. The two settings cannot both be
   satisfied on a surface that does not change, which is why the plate shows the
   same 7 of 77 as the blend's 2 of 77.

   That is not yet a defect — the rule is doing what its comment says, and the
   filter is doing what its config says — but it is the mechanism, and it makes
   the next experiment a question of the world rather than of the part: a filter
   whose thresholds suit a noiseless surface, or a walk that turns the patch by
   enough to be counted, is what the symmetry path needs to be given a chance.

   Borrowing a config for that comparison does not work, and it is worth saying
   because it looks like it should. `test/policy/base_surf` is the config whose
   sensor is `camera_surf` — no delta filtering — and it also swaps the learning
   module (`displacement_1lm` for `evidence_1lm_nn5_dod0025`) and the termination
   (30/30/60 steps for 1000/500/5000). Pointed at the blend it ended at step 16
   with nothing detected and no hypotheses, so nothing about its counter is
   comparable. The comparison needs a config of this study's own; that is item 3
   of the plan, and it is now the item with a reason.

   `plate-huge` is in the table because it keeps a partner more often than the
   plate — 85 % against 74 % — which is the scale effect seen from the other
   side: at five times the size, fewer of its nodes carry the features that
   break the symmetry, the same shortage the pose-defined column measured. The
   two measurements are independent — one is a threshold on curvature, the
   other a tolerance on position that follows the spacing — and they agree about
   which part is the harder one to orient.

   Neither column predicts the rate, and `plate-huge` is the case that says so:
   it has _fewer_ discriminating nodes than the plate — 153 of 1602 against 246
   of 1557 — and concluded three times in four in the two-part test, where the
   plate concluded four times in ten on its own. The share is a gate on whether
   a pose can ever be named; how often an exploration reaches the part of the
   memory that names it is a separate question, and the two comparisons are not
   like for like — different library, different seed set. Reading the share as a
   success rate would be the same mistake the rotation count invited.

   `scripts/probe_part_symmetry.py` is the test, over a memory the runs wrote:

       scripts/probe_part_symmetry.py /tmp/cad-experiment/blend
       scripts/probe_part_symmetry.py /tmp/cad-experiment/plate+plate-huge

   `scripts/probe_cad_poses.exs` asks the same question of a run rather than of
   a memory, on demand:

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

   **Two shapes, not two sizes.** The pair that matters most is distinct
   parts, and that one works: with the blend and the plate in memory and the
   plate sensed, the plate is the only object possible in both seeds tried, and
   it concludes on one (evidence 6.3) while the other holds at 4.0 with its pose
   unresolved. Sensing the blend against the same library leaves both possible —
   the same blend problem seen from the other side, and the reason a run's
   direction of travel matters as much as its library.

   Two questions are left, and they are now different questions. A right answer
   is still seed-dependent — the plate is recognised in 4 of 10 seeds on its own
   — and that is about evidence and exploration, not about which part was named.
   A symmetric part still never concludes, but no longer because "there is no
   answer": its orientations are one picture to the matcher, so the pose rule
   cannot pick one, and the symmetry rule that exists for exactly this case is
   starved by the sensor's own filter — two steps in seventy-seven counted as a
   new observation. The next thing to change there is the world, not the part.
   The lesson that belongs in
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
   pose worth naming". That question now has a measurement of its own: the share
   of a memory's nodes with no partner under any half turn — 16 % of the plate's,
   one node of the blend's. The plate does and the blends do not,
   and the library a recognition run is aimed at therefore has to hold parts
   with a boss, a hole, an off-centre feature — the things that break the
   symmetry. The feature also
   has to be curved enough to count, and the threshold says how much: for a
   cylinder the two principal curvatures are `1 / R` and nought, so a radius of
   a hundred millimetres is exactly 10 m⁻¹, and a rounder feature than that
   reports no orientation at all — a CAD part is worth a pose only while its
   curved features have a radius under ten centimetres, which is a second
   reason a library of scaled parts is not a library of one shape at several
   sizes. That is a statement about the parts, and it is the one
   `docs/cad.md`'s item 4 has to be built on. The plate's six failing seeds are
   the other half: same part, same start, half the explorations find it inside
   the config's budget, so either the exploration is too slow for these parts or
   the evidence needs more steps than the borrowed config allows.

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
