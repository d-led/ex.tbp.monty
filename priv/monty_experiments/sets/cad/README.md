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

The studio is what runs these, and it carries four CAD runs: `cad/plate_part_eval`
(the plate as one object), `cad/plate_features_eval` (the same plate as its four
features), and the two blends. `scripts/init-dev.sh` once, then
`MONTY_PYTHON=../monty-orig/.venv/bin/python scripts/run-dev.sh` for
<http://localhost:4000> — the packaged desktop application is the same pages. A
CAD run steps MuJoCo, so an interpreter with `tbp.monty` in it is the one thing
the server needs that no config can name.

1. **Sidebar → Prerequisites.** On a machine that has not made them, the row
   `cad_part_memories` reads `not built` and carries a **Make** button. Press it:
   it writes one memory per CAD experiment and the mesh of every object the
   configs name, saying which part it is on as it goes (`1/1 plate: memory and
   meshes`). The row stops saying `not built` when it is done.
2. **Sidebar → Experiments**, then pick the run. `cad/plate_part_eval` is the one
   that recognises; `cad/plate_features_eval` is the one that does not, for the
   reason the sections below measure.
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
in step 2. It ends **without** a conclusion: four objects still possible. Slice it
to `episodes` 4 — one per feature — and `steps each` 500 to watch the same wall at
the config's own budget rather than at a long cap.

### The same thing without a browser

The page and a terminal drive the same code. Four environment variables are the
whole setup, and the first is what the studio itself runs in:

    export MIX_ENV=desktop
    export MONTY_DATA=~/cad-run/data             # worlds, under <data>/cad_objects/
    export MONTY_LIBRARIES=~/cad-run/libraries   # memories, under <libraries>/cad_parts_v1/
    export MONTY_MODELS=~/cad-run/models         # pretrained releases, unused by
                                                 # these sets but read at boot

**Make what a run reads** — step 1 above, as a command. What it does is the plan
each CAD config gives:

    mix run --no-start -e 'Monty.Prerequisites.Build.run("cad_part_memories", fn p ->
      IO.puts("#{p.index}/#{p.total} #{p.what}")
    end)'

It prints what it wrote — one memory per CAD experiment
(`<libraries>/cad_parts_v1/{plate_part,plate_features,blend_part,blend-big_part}.jsonl.gz`)
and one directory per object the configs name under `<data>/cad_objects/`, so
`plate/` and `plate_bosses_0/` beside it.

**Run the part-level experiment** — one object in the memory, three eval episodes,
the tutorial's four-millimetre gait:

    mix monty.run cad/plate_part_eval --no-record

    learning_module_0: match 3 of 3

That is the result: the plate recognised in every episode, each one ending on the
recognition policy rather than on a step cap. `--no-record` keeps it out of the
studio's database; drop the flag and the run appears in `/runs` with its log and
its page, exactly as a press of `Run it` would leave it.

**Run the feature-level experiment** — four objects in the memory, one per feature,
four of the config's twelve episodes as a slice:

    mix monty.run cad/plate_features_eval --episodes 4 --steps 500 --no-record

`--episodes` and `--steps` are the page's two fields under `Run it`. This one does
not match, and the sections below say why: it ends with four objects still
possible, and the read of its `eval_stats.csv` is what named the pair the sensor
cannot tell apart.

A recorded run (`mix monty.run cad/plate_part_eval`, no `--no-record`) needs a
migrated database: `SQLITE_PATH=… mix ecto.migrate_all` first, or the studio's own
boot fails on a missing table.

## What a feature run needs that a part run does not

Two settings, both Monty's own, and both because a feature is a centimetre across
where a plate is six:

- the motor system is `surface_curvature_informed_5_goal0` — 5 mm steps and 5°
  turns, so the patch stays on the object instead of stepping over it;
- `desired_object_distance` is 8 mm rather than 25, so the patch is mostly
  surface rather than mostly background. The observation processor passes a patch
  to a learning module only when enough of it is on the object, and at 25 mm one
  run stepped 2023 times with the learning module fed on two of them and evidence
  frozen at 1.69.

## How a feature memory is sampled

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

## What a feature run hits first, in the order it hits it

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

## Where it stands now

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

The answer to the duty cycle is the gait, and it is a scale argument of the same
shape as the stand-off's. The set stepped a feature a centimetre across with
`surface_curvature_informed_5_goal0`, whose action sampler is `constant_surf_5` —
`rotation_degrees: 5.0` and `ConstantSampler`'s own `translation_distance:
0.004`, i.e. four millimetres a step. A crossing of a centimetre feature is
therefore two and a half steps, and the rest of the episode is the policy walking
back to it.

So the experiment now names its own sampler: one millimetre a step and one degree
a turn, the same arc per degree (0.8 mm) at a tenth of the distance, one sampler
for every feature the part is made of — the same kind of choice as the stand-off
and the zoom, not a treatment of any one shape.
`Monty.Studio.Cad.ExperimentConfigTest` pins both numbers, because the body that
carries them is written at a package path and a body at the wrong package
composes to a value nobody reads.

Measured, and it buys what the arithmetic said it would. Twelve episodes at a
cap of eight hundred steps each (this box's, not the config's five thousand), the
same four features, the same memory:

    four millimetres a step:  the module was fed on 56 to 625 of 5000 steps, 4 %
    one millimetre a step:    47, 28, 200, 207, 104, 161, 158, 1, 168, 188,
                              199, 208 of 800 — 17 % of the run

and the module gained evidence in all but one of the twelve, `plate_risers_0` and
`plate_body` trading the lead between episodes as they did before. So the policy
was the whole of the duty cycle — the same memory, sensor and stand-off with a
smaller step is four times as much feeding.

The sensor's own reporting resolution is the next thing that looks like the same
kind of size, and it is not. `delta_thresholds.distance` is a centimetre, so the
module is fed on 19.3 % of steps; asking for a millimetre — the gait — feeds it
on 19.3 % of steps. Four episodes, first three hundred steps each, both ways:

    distance 0.01:   47, 28, 79, 77 fed, evidence 20.8, 5.2, 33.2, 36.4
    distance 0.001:  231 of 1200 fed — the same 19.3 % — 23.1, 5.2, 38.9, 44.0

The hypothesis counts are the same numbers at the same step either way (4108,
16432, 24136), which is the tell that the threshold was never the constraint: the
noise the sensor overlay adds to hue and pose already carries the patch past it
every few steps. The millimetre was measured and reverted, not kept for its tenth
of evidence.

The motor policy is the one size that did move the evidence, and it does not move
the answer. Monty's own surface agent walks towards what the module believes
(`use_goal_driven_actions: true`); this set had been built on the variant that
turns it off. Four episodes at the config's own five-hundred-step eval budget,
one per feature:

    goal-driven off: 333 of 2000 steps fed, evidence 20.4, four objects possible
    goal-driven on:  402 of 2000 steps fed, evidence 44.9, four objects possible

The set now names the goal-driven policy: twenty per cent more feeding, twice the
evidence, and the same four objects still possible at the end of every episode.
Two independent moves past the same wall is the strongest evidence this memory
has that the wall is the memory, not the policy.

What is left is not the matcher, and the memory says so. Asked of the file the
run loads — every node of every object, by the features the sensor reports:

| object                    | hue (hsv) | `principal_curvatures_log` | `mean_depth` |
| ------------------------- | --------- | -------------------------- | ------------ |
| `plate_body` (3017 nodes) | 0.000     | median 0.00, sd 1.56       | 0.009        |
| `plate_risers_0` (2054)   | 0.000     | median 0.00, sd 1.77       | 0.009        |
| `plate_bosses_0` (205)    | 0.000     | median 4.56, sd 4.49       | 0.010        |
| `plate_holes_0` (96)      | 0.000     | median −2.89, sd 3.14      | 0.000        |

The part is one colour, so hue carries nothing. Depth separates the bore (an
opening, nought) and barely separates the rest. Curvature separates a boss
(convex) and a bore (concave) from flat surface — and leaves the body and the
risers **both flat, both nine millimetres deep, both the same colour**: two of the
four objects are indistinguishable in the features this sensor reports, at the
scale it reports them. That is what the run showed, episode after episode: the
most likely object alternated between exactly those two and the possible set
never fell below the pair.

So the next question is what the set asks, not what the matcher does. And the
sibling experiment answers it: `cad/plate_part_eval`, the same part as one memory
object rather than four, recognises all three of its episodes —

    episode 0: 101 steps, `plate`, evidence 24.9, possible ["plate"], match
    episode 1: 184 steps, `plate`, evidence 11.0, possible ["plate"], match
    episode 2: 351 steps, `plate`, evidence 19.7, possible ["plate"], match

— at the tutorial's own four-millimetre gait, on the same sensor, the same
stand-off and the same world. A part-level CAD memory is recognised from a mesh
world, which is the pipeline this set exists to show. The page is not what makes
it work: `mix monty.run cad/plate_part_eval --no-record` — the same set, the same
seed, the same three episodes — reports `match 3 of 3` in 483 steps. The two
front-ends do not agree on how long the episodes take (101, 184 and 351 steps from
the page against 99, 204 and 151 headless), and that difference is untraced.

What the feature-level run leaves is in its own `eval_stats.csv`, and it is more
precise than "no verdict": eleven of the twelve episodes end with no verdict at
all, because the possible set never falls to one object, and the twelfth is a
`patch_off_object` of nought steps. Of the six asked about the body or a riser,
four do end on the object they were asked about — `plate_body` at evidence 61.2
and 162.6, `plate_risers_0` at 112.4 and 246.0 — and still earn no verdict,
because the pair is still possible, which is what an inseparable pair looks like
from inside the module; one ends on `plate_body` when it was asked about a riser,
at 144.0. Of the six asked about the boss or the bore, every one ends on
`plate_risers_0`, so those two are never recognised at all. Symmetry evidence is
nought in every episode, so the pair is not being reported as a symmetry either.

So what this set needs next is an object set whose features differ in the taught
features — two curvatures, two depths, one colour, the way the tutorial's objects
differ by shape _and_ colour — or the unavoidably ambiguous pairs settled before
object identity is asked about at all.
