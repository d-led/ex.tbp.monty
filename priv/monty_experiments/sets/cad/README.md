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

## Reproducing it on the page

The studio is what runs these, and it carries five CAD runs: `cad/plate_part_eval`
(the plate as one object), `cad/plate_features_eval` (the same plate as its four
features), `cad/plate_features_2patch_eval` (the same again with a second patch),
and the two blends. `scripts/init-dev.sh` once, then
`MONTY_PYTHON=../monty-orig/.venv/bin/python scripts/run-dev.sh` for
<http://localhost:4000> — the packaged desktop application is the same pages. A
CAD run steps MuJoCo, so an interpreter with `tbp.monty` in it is the one thing
the server needs that no config can name.

1. **Sidebar → Prerequisites.** On a machine that has not made them, the row
   `cad_part_memories` reads `not built` and carries a **Make** button. Press it:
   it writes one memory per CAD experiment and the mesh of every object the
   configs name, saying which part it is on as it goes (`1/1 plate: memory and
meshes`). The row stops saying `not built` when it is done.
2. **Sidebar → Experiments**, then pick the run. `cad/plate_part_eval` recognises
   the plate as one object; `cad/plate_features_eval` asks about its features, and
   `cad/plate_features_2patch_eval` asks the same question with a second patch.
3. **Press `Run it`.** Under the button are the three numbers a run takes —
   `episodes` out of the config's own count, `steps each, at most`, and `settle`,
   beside a `scheduling` choice — and for a reproduction they are left at the
   config's values. The step budget is a ceiling, not a target: each episode ends
   on its own recognition policy first.
4. **Read the page it opens.** The steps stream in with what the module believes,
   the chart draws evidence per object, and the summary closes on
   `learning_module_0: match 3 of 3` with a band per episode in the colour of the
   object it was about. `Stop` is beside `Run it` for as long as it is going.
5. **Sidebar → Runs** holds it afterwards with the same log and the same page —
   the record is what a later reproduction can be compared against, and it is
   where the run's own `eval_stats.csv` lives.

For the feature run the steps are the same with `cad/plate_features_eval` picked
in step 2. Its twelve episodes are the longest run in this set — the module is
fed on a tenth of the steps, because a patch a sixteenth of the part's width
spends most of an episode walking back to the feature.

### The same thing without a browser

The page and a terminal drive the same code, and a terminal run reads the roots
the page reads — Monty's own environment variables, defaulting to the
application's support directory. Nothing has to be exported, and a run pointed at
a copy of a memory is a run of something else:

    MIX_ENV=dev mix run --no-start -e '
      for root <- ~w(MONTY_DATA MONTY_LIBRARIES MONTY_MODELS),
        do: IO.puts("#{root} = #{Monty.Prerequisites.root_path(root)}")'

prints where a run reads and where Make writes. (A shell that exports the three
is answering for itself, and `scripts/run-dev.sh` starts the pages against the
same roots.)

**Make what a run reads** — step 1 above, as a command. What it does is the plan
each CAD config gives:

    MIX_ENV=dev mix run --no-start -e 'Monty.Prerequisites.Build.run("cad_part_memories", fn p ->
      IO.puts("#{p.index}/#{p.total} #{p.what}")
    end)'

The same click under a `MIX_ENV` the page does not use writes where _that_
environment reads — which is why the roots are printed by the command above
rather than assumed here.

It prints what it wrote — one memory per CAD experiment
(`<libraries>/cad_parts_v1/{plate_part,plate_features,blend_part,blend-big_part}.jsonl.gz`)
and one directory per object the configs name under `<data>/cad_objects/`, so
`plate/` and `plate_bosses_0/` beside it.

**Run the part-level experiment** — one object in the memory, three eval episodes,
the tutorial's four-millimetre gait:

    MIX_ENV=desktop mix monty.run cad/plate_part_eval --no-record

    learning_module_0: match 3 of 3

That is the result: the plate recognised in every episode, each one ending on the
recognition policy rather than on a step cap. `--no-record` keeps it out of the
studio's database; drop the flag and the run appears in `/runs` with its log and
its page, exactly as a press of `Run it` would leave it.

**Run the feature-level experiment** — four objects in the memory, one per feature,
four of the config's twelve episodes as a slice:

    MIX_ENV=desktop mix monty.run cad/plate_features_eval --episodes 4 --steps 500 --no-record

`--episodes` and `--steps` are the page's two fields under `Run it`. Eight of the
twelve episodes conclude and four time out, and the four are the ones asked about
the bore: what one patch reports cannot separate the plate's body from its
risers, so those two stay possible together and the sections below measure why.

`desktop` is the environment that carries the MuJoCo interpreter a CAD run steps;
under `dev` the same command wants `MONTY_PYTHON`, as `scripts/run-dev.sh` says.

A recorded run (`mix monty.run cad/plate_part_eval`, no `--no-record`) needs a
migrated database: `SQLITE_PATH=… mix ecto.migrate_all` first, or the studio's own
boot fails on a missing table.

## What a feature run needs that a part run does not

Two settings, both Monty's own, and both because a feature is a centimetre across
where a plate is six:

- the motor system is `surface_curvature_informed_goal1`, pointed at the small
  object, and this set names its own action sampler: 1 mm a step and 1° a turn.
  The policy's own sampler steps 4 mm and turns 5°, which is a quarter of a
  centimetre feature — a crossing is two or three steps and the rest of an episode
  is the policy walking back, measured as the module being fed on 56 to 625 of
  5000 steps. One millimetre and one degree keep the same arc per turn, 0.8 mm a
  degree, at a tenth of the distance, and one sampler serves every feature the
  part is made of;
- `desired_object_distance` is 8 mm rather than 25, because the patch is twice the
  stand-off wide. At 25 mm it reads 5 mm of surface — five times the smallest
  feature, and mostly background on anything a centimetre across — and one run
  stepped 2023 times with the module fed on two of them and evidence frozen at
  1.69. At 8 mm the patch reads 1.6 mm and is mostly surface.

The other end of that rule is a bore, and it is where 8 mm is a compromise rather
than a fit. The plate's bore is ten millimetres deep, so a patch read from 8 mm
straddles its near lip and its far opening at once and the surface fit answers a
thin arc. Visits whose curvature fit succeeds, of the 96 the geometry offers:

| stand-off | 4 mm | 8 mm  | 12 mm | 16 mm | 20 mm | 25 mm |
| --------- | ---- | ----- | ----- | ----- | ----- | ----- |
| the bore  | 0/96 | 21/96 | 0/96  | 96/96 | 96/96 | 81/96 |

The body and the bosses need nothing from the stand-off: 3 349 and 205 visits fit
at 8 mm and at 16 mm alike. Twice the distance reads the bore and reads a 3.2 mm
patch, which no longer fits inside a boss — twelve episodes each, through the
page, on this Mac:

| stand-off | one patch | two patches |
| --------- | --------- | ----------- |
| 8 mm      | 8 match   | 11 match    |
| 16 mm     | 7 match   | 3 match     |

So the feature sets read from 8 mm: a bore whose curvature is a thin arc costs
what the bore alone would separate, and a patch too wide to sit on a boss costs
all four objects.

## How a feature memory is sampled

The CAD package spaces a part's visits from the part's own size, and caps the
visits at two thousand. Both are sized for a part, and a feature is a fraction of
one: at the package's defaults the plate's boss kept 56 nodes and its hole 16,
and at a finer spacing with the same cap the two disappeared from the memory
altogether, because the plate's body and risers alone spend the budget. A wall
sampled at 16 nodes is a wall reproduced as a few quadrilaterals, and a patch
that straddles it has nothing to match.

So a memory of features is taught at 1 mm with a cap of 20 000 visits
(`Monty.Studio.Cad.Preparation`), through the lens and from the distance the run
itself uses. That is a comparison, not a style: the environment's patch sensor
reads 11.42° (`zoom: 10` on a 90° base), where a `Camera.patch/3` default is 66°,
and a memory taught through a six-times-wider patch is a memory of a different
surface. Taught the run's way, the plate's four features are 5 760 nodes and cost
a minute.

## What a node is

A node is one percept a learning module was handed, so a visit whose surface fit
the sensor refused is not stored: `MontyCad.Training` asks
`process_features_in_lm` and skips the visit. A patch straddling an opening has no
curvature to compute, and the node it would otherwise leave behind is one no
matcher can score — `principal_curvatures` of length zero where every other node
carries two numbers in the log.

One such node silences a whole memory, and that is a property of the matcher
rather than of the data: this port's missing value is numpy's NaN, `np.max` over a
column holding one is NaN, and `Hypotheses.indices_within/3` therefore answers
nothing for any hypothesis. The possible set empties at every step, no pose is
ever named, symmetry never counts, and the episode cannot conclude however long
the cap. The plate's part memory holds 2 111 nodes, against the 2 113 visits its
geometry offers.

## What the sets answer

The page drives all nine, `Run it` with the config's own episodes, world
`ex_mujoco`, seed 42, on this Mac:

| set                              | memory                | episodes | answer               | steps  |
| -------------------------------- | --------------------- | -------- | -------------------- | ------ |
| `cad/plate_pretrain`             | writes one            | 1        | learned 20 nodes     | 1 070  |
| `cad/plate_learned_eval`         | `trained/` from it    | 3        | 2 match, 1 no_match  | 422    |
| `cad/plate_part_eval`            | `plate_part`          | 3        | 3 match              | 532    |
| `cad/plate_pair_eval`            | `plate_pair_assembly` | 3        | 3 match              | 547    |
| `cad/parts_set_eval`             | `parts_set`           | 6        | 6 match              | 1 142  |
| `cad/blend_part_eval`            | `blend_part`          | 3        | 2 match, 1 no_match  | 444    |
| `cad/blend-big_part_eval`        | `blend-big_part`      | 3        | 3 match              | 310    |
| `cad/plate_features_eval`        | `plate_features`      | 12       | 8 match, 4 time_out  | 22 633 |
| `cad/plate_features_2patch_eval` | `plate_features`      | 12       | 11 match, 1 no_match | 4 134  |

A part is recognised from its mesh in every epoch it is asked, at four
millimetres a step and 25 mm of stand-off: that is the pipeline this set is here
to show, and `plate_pair_eval` shows the same for an assembly whose two parts are
memories of their own. The feature runs are the harder question, and the sizes
above are what buys them.

## What one patch cannot tell apart

The four feature objects differ in one number each, and one of them is shared.
Asked of the memory a run loads — every node, by the features the sensor reports:

| object                   | hue (hsv) | `principal_curvatures_log` | `mean_depth` |
| ------------------------ | --------- | -------------------------- | ------------ |
| `plate_body` (3 349)     | 0.000     | median 0.00, sd 0.67       | 0.008        |
| `plate_risers_0` (2 185) | 0.000     | median 0.00, sd 0.70       | 0.008        |
| `plate_bosses_0` (205)   | 0.000     | median 1.04, sd 2.43       | 0.008        |
| `plate_holes_0` (21)     | 0.000     | median −2.77, sd 2.77      | 0.008        |

The part is one colour, so hue carries nothing. Curvature separates a boss
(convex) and a bore (concave) from flat surface — and leaves the body and the
risers **both flat, both the same depth, both the same colour**. Those two are
the pair every unconcluded episode ends on: the most likely object alternates
between them and the possible set never falls below both.

The bore is the other half of the same story. Eight millimetres keeps 21 of its
96 visits, so what the memory holds of it is a fifth of the surface the geometry
offers — enough to recognise when the patch lands on the lip, and not enough to
beat a pair that never separates.

What is left is what the set asks, not what the matcher does, and
`cad/plate_part_eval` answers it: the same part as one memory object rather than
four recognises all three of its episodes — 5, 20 and 25 steps at this Mac's own
counts — at the tutorial's own four-millimetre gait, on the same sensor, the same
stand-off and the same world. A part-level CAD memory is recognised from a mesh
world, which is the pipeline this set exists to show.

The feature runs leave two questions: an object set whose features differ in more
than one number — two curvatures, two depths, one colour — and the pairs that a
second patch reads differently from one. `plate_features_2patch_eval` is the
second of those already, and it is the one feature run that concludes in every
epoch.

The second patch helps, and by the pair rather than by the evidence:`cad/plate_features_2patch_eval` is the same run with a second camera four
millimetres along the agent's own x — a quarter of a patch's width, so the pair
spans a rail's edge where one patch sees only its face. Both patches reach the
module (`percepts patch,patch_side`) and one learning module reads both, with its
own tolerances and weights for each id. Eleven of its twelve episodes conclude
against eight with one patch, and its twelve take fewer steps than that eight
does: the second reading separates the pair rather than feeding more.

The set names the goal-driven motor policy (`use_goal_driven_actions: true`,
Monty's own surface agent walking towards what the module believes) rather than
the variant that turns it off: twenty per cent more steps fed and twice the
evidence at the same budget. Five learning modules would buy nothing — Monty
pairs them with five sensors and votes between them, and the surface agent is
single-patch by design.

What is left is not the matcher, and the memory says so.
