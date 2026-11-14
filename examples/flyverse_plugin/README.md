# A FlyVerse plugin

A spiking connectome as an Elixir Monty Studio plugin: two plugins, and the
second one steps [flyverse](https://github.com/djmango/flyverse)'s leaky
integrate-and-fire engine inside a Rustler NIF to decide where the sensor
looks next.

| Plugin                      | Kind            | What decides                                         |
| --------------------------- | --------------- | ---------------------------------------------------- |
| `FlyversePlugin.Experiment` | `:experiment`   | the run it asks for, as data (`run/0`)               |
| `FlyversePlugin.Policy`     | `:motor_policy` | where the sensor goes next, by stepping a connectome |

This is the second worked example beside `examples/example_plugin`, and it
exists to answer three questions the first one left open: what a _plugin whose
decision is not a pure function_ looks like, what `placement: :owner_only` is
for, and whether a real spiking simulation can be reached from the BEAM at all.
`docs/research.md` is the study behind that answer — what flyverse and
[flyBrain](https://github.com/mehrantsi/flyBrain) each make possible, what does
not fit the plugin contract, and what is left to do.

## What this is not

**This is not an optimum, and nothing here is optimised.** It is not a claim
about how a fly steers, not a claim about Monty, and not an attempt to beat or
reproduce Monty's own results. Monty's experiments are a reference
implementation of a theory, tuned against measurements over years; this is an
exercise in joining unlike parts — a Rust spiking engine, a Rustler boundary, a
plugin contract, an Elixir framework, a MuJoCo world in a Python interpreter,
and a studio that queues the run — and asking whether the joint holds.

The constants are chosen to be readable, not to be right: ten millimetres a
stride with four as the floor, five degrees of base turn, `1/depth` at four
hertz per inverse metre. A pack of four neurons is not a nervous system, and a
score it produces is a score of this wiring, not of a fly, a brain, or Monty.
What would support a claim is the dataset's connectome, a body with muscles, and
a measured comparison against Monty's own surf policy; none of those are here,
and no number on any page of a run should be read as if they were.

## What the decision is

Two halves, in Monty's order. While the patch is not on the object — below a
tenth covered — the answer is Monty's `_touch_object` with the one thing a fly
must add to it, and the network is not asked at all: its input is how near the
left half of the patch is compared with the right, and an empty patch says the
same thing everywhere.

Once the patch is on the object, the network decides:

```
 left half   --1/depth-->  80 + 4x Hz  --> drive 0 --> readout 2 --+
                                                                    +--> difference
 right half  --1/depth-->  80 + 4x Hz  --> drive 1 --> readout 3 --+

 a sine, +-20 Hz on an 80-step period, goes + on the left rate and
 - on the right, so two halves that are equal are never quite equal

 difference --30 ms low-pass--> wish --5 deg x tanh(wish/2)--> yaw
```

Each step: nearness (`1 / depth`) per half of the patch becomes a Poisson rate —
80 Hz, widening four hertz per inverse metre, capped at 220 — the network steps
20 ms of 0.1 ms ticks in Rust, and the difference of the two readout spike counts
is low-passed with flyverse's own 30 ms motor time constant. That difference is
the _wish_. More spikes on the left means the left half of the view is nearer,
so the sensor yaws that way; spikes on the right yaw the other way; a balanced
view walks straight ahead, because a balanced view is looking at the thing it is
meant to reach and moving forward is what closes the gap.

Three of those numbers are not free. The **80 Hz tonic** is the network's resting
drive: a fly reading nothing still ticks over, so the wish has something to be a
difference _of_. The **30 ms** is flyverse's own motor constant, so a silent
network keeps the wish it had instead of snapping to zero, and the walk has
momentum. The **sine** is the only invented signal: a perfectly symmetric view
gives a perfectly balanced wish, and a fly that walks a straight line for ever
never sees anything else, so the drives are pushed apart a little and pulled
back, eighty steps a cycle.

### The action

Every step walks _and_ turns: one `OrientHorizontal` carrying a yaw, a forward
distance and a sideways one. It is not `TurnLeft`/`TurnRight` — those are the
distant agent's actions, and the surf agent a MuJoCo world hands us has no
`actuate_turn_*` at all. And an animal that yaws where it stands is an animal
standing still: an early run of this policy spent a thousand steps like that — the
network said "left", the action turned left with no distance, and the patch saw
the same three square centimetres of table until the episode died.

| field              | value                                                                      |
| ------------------ | -------------------------------------------------------------------------- |
| `rotation_degrees` | 5°·tanh(wish/2) + 10°·centring + 10°·rim, capped at 30°                    |
| `forward_distance` | the standoff kept: `clamp(depth - 25 mm, 4 mm, 10 mm)`, negative if nearer |
| `left_distance`    | 10 mm towards the side the wish prefers, but only at the surface           |

The **centring** term is Monty's, not the network's: ten degrees towards the
side the patch is off-centre by, so a fly learning a surface keeps it in the
middle of the picture while the wish decides which way to explore it.

The **rim** term is the one the wide view cannot supply. The clip makes the
patch's two halves a switch — a half reading one over the clip's ceiling has
surface under it — so one half at the ceiling and the other not is an _edge_, and
the half with surface says which way it runs. Ten degrees towards it, which is a
bias and not a decision: the network still chooses which way along the boundary,
and this only decides to stay on it.

It is worth a term because the outline is the only part of a top-down percept
that differs between two objects. The middle of a mug's top and the middle of a
can's top are the same flat square; the curvature where the top turns down is
not. The temptation is to lean harder — twenty-five degrees, on the theory that
a bias the network can outvote decides nothing — and that was measured and
reverted: it took the very first episode of the sweep from 130 steps to 285. A
fly that commits to the boundary stops covering the top, and the top is most of
what a mug's model is made of.

The forward distance keeps a **25 mm standoff** rather than being a constant,
because both ends of that are measured mistakes. At the surface a step of nought
is a step the slide then pushes _into_ the object — a run slid until the patch
was inside the mug, where every frame is the same flat colour and the evidence
stopped moving for two thousand steps. And in open space four millimetres is
_under the patch's own one-centimetre delta threshold_: the patch reads the same
place again and again, and a frozen picture is exactly what the stall counter is
watching for. So the stride is ten millimetres with four as the floor, and it
shrinks to whatever room is left as the surface arrives.

A **loom** — something in view suddenly filling half again as much of it —
outranks all of that and turns the forward step into a retreat, bounded by one
step's stride so it costs a step's retreat rather than a flight.

### The six behaviours

Which of these the step is, is decided before the network is asked. The stall
counter reads the **patch's** mean depth and not the wide view's, because the
wide view changes whenever the fly turns while the patch — the thing the learning
module sees — can be identical for two hundred steps.

| behaviour     | when                                                                       | what it does                                                                                                                                          |
| ------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:cruise`     | nothing under the patch, and the patch is changing                         | walk at whatever the view finder sees: aim at its most varied column and step the gap; a leg of the search circle when it sees nothing within a metre |
| `:explore`    | something under the patch that is not clipped, bout under 60               | the network steers (above)                                                                                                                            |
| `:depart`     | 60 steps into a bout, or a second stall in the same one                    | about-face (180°, alternating side) and a 50 mm hop, until the patch is off it or four steps are                                                      |
| `:look`       | the patch has shown the same depth for 20 steps                            | an aimed look when there is something under it; a quarter turn and a 50 mm leg when there is not                                                      |
| `:struggling` | the body has moved under a millimetre for 12 steps                         | a 90° swing, on a 40-step period                                                                                                                      |
| `:dive`       | two swept legs found no surface at all, and the patch is still at its clip | six steps of one centimetre down, then six back up — the only vertical motion this fly has                                                            |

A **dive** is the answer to the one thing a top-down patch cannot see. The fly
rides a decimetre up and the patch reaches five, so anything lying flatter than
the difference is never in a percept: the spoon, at one and a half centimetres,
is 8.5 below the sensor in every pose, and in a baseline run six of the seven
abandoned episodes were spoons — 45% of all the steps the run spent.

Two swept legs without ever finding surface is the fly's own evidence that the
_direction_ is not the problem, and the answer is vertical. It is a dive and not
a descent: the altitude the tall objects are visible from is the one thing the
fly cannot get back any other way, so it lets go of it for twelve steps and takes
it back. Both halves of the dive are shown to the learning module exactly while
there is something under the patch, which is the point — at four centimetres the
table is in reach and the spoon with it. The count is the sweep's own legs and
not the steps of a look, because a look is the answer to a stall and resets the
stall counter deliberately.

`_touch_object`'s own numbers are kept where they were right: below a tenth of
the patch covered, one step across the gap the view finder can see, aimed at the
**most varied column** of the depth image rather than its mean, because the mean
of a table edge and a mug is a place with neither. The search circle is the one
place this policy departs from Monty's numbers, and it is a measurement that
made it: the most structured column of an empty room is a wall, and a fly that
walks at a wall stays at it — one episode took four percepts in five thousand
steps, its hypothesis set growing from 1776 to 7104. So a fly with nothing under
the patch sweeps instead: a quarter turn and a stride, alternated so the legs fan
out over the ground rather than spiral back across it.

A **bout** is what makes the fly stop reading one square centimetre for ever.
Sixty steps on a surface, then a departure that turns it round and puts it five
centimetres away; the stall counter fires the same departure sooner if the patch
stops changing. The departure alternates its half-turn sign, so two bouts in a
row do not retrace each other.

An **idle** fly is nudged rather than trusted. The measure is the body's own
position from the motor state, not what the policy believes it is doing: less
than a millimetre of movement for twelve steps means pressing against a surface,
wedged in a corner, or asking for a step the world will not take, and the answer
is a ninety-degree swing on a forty-step period, until it moves. Periodic and
not one-shot, because the first swing can leave it facing the same wall.

### What the learning module is shown

Monty's own surface policy hides three of its four steps from the learning
module — every `OrientHorizontal` and every `MoveTangentially`, feeding it only
the vertical orient — because a step that is not reading the object teaches it
nothing, and its _displacement_ is what the module would then have to explain.
Monty matches a location across `max_match_distance: 0.01`.

So this policy's rule is the patch's answer and not the behaviour's name: a step
is a sensor step exactly when there is something under the patch to read. On the
object that is every step. Lost, it is none of them — the sweep's quarter turn
and fifty-millimetre hop are five times the distance Monty will match across, and
the departure is the same. `silence_if_motor_only` in the framework is where this
happens: the percept keeps its shape and stops passing on.

### What the module can tell apart

This is the arithmetic behind every steering choice above, and it is Monty's, not
this policy's — `evidence_1lm_nn5_dod0025` names the channels and
their tolerances, and no gait can add discrimination a tolerance discards.

| channel                    | weight      | tolerance         | what it says                                                 |
| -------------------------- | ----------- | ----------------- | ------------------------------------------------------------ |
| `hsv`                      | 2, 0.5, 0.5 | 0.1, 0.2, 0.2     | colour; hue wraps the short way round                        |
| `pose_vectors`             | 1, 1, 1     | 20° (the default) | where the surface turns, matched as an angle                 |
| `principal_curvatures_log` | 1, 1        | 1.0, 1.0          | how tightly it turns — in log space, so 1.0 is a factor of e |

A channel's evidence is one at no difference, nought at the tolerance, and linear
in between. So a curvature logged half a unit apart — two radii differing by a
factor of 1.65 — still earns **half** the credit of an exact match. The ten
objects are similar by construction: cups of several sizes, boxes of several
colours. Two cups of one colour differ in curvature alone, and curvature is the
only channel in which size exists at all.

Which is why the heading carries the patch's edge. On a flat top every object's
curvature is nought, so that channel says nothing and only colour speaks; on the
rim and the side wall the curvature is real and size-dependent. The fly cannot
make the tolerance narrower — but it chooses which square centimetre to show, and
the squares that carry size are the ones near a boundary.

## What worked, and what it was worth

Measured on `flyverse_plugin.10simobj_surf_agent`, whole runs, comparing total
Monty steps first (a run's cost is its steps, not its episode count), then
completions, then mean steps per completed episode.

| kept                                           | why it is there                                                                     |
| ---------------------------------------------- | ----------------------------------------------------------------------------------- |
| walk and turn in one action                    | a yawing fly reads one patch for ever                                               |
| a 10 mm stride, 4 mm floor                     | 4 mm is under the patch's own 10 mm delta threshold                                 |
| the standoff instead of a constant             | stops the patch ending up inside the mug                                            |
| the patch's nearness as the stall signal       | the wide view changes when the fly turns; the patch does not                        |
| aim at the most varied column                  | the mean of a table edge and a mug is neither                                       |
| sweep instead of aim when lost                 | a lost fly that aims is a lost fly                                                  |
| depart every 60 steps                          | the only thing that ends a two-thousand-step bout                                   |
| a periodic sine wander                         | breaks the symmetric-view deadlock                                                  |
| idle detection, measured on the body           | the four original stalls, all of them                                               |
| the clip read as "nothing there"               | a clipped pixel is not a distant one                                                |
| the standoff held from the nearest patch pixel | a clipped half inflates a mean, and a mean asks to press in                         |
| the patch's own edge in the heading, at 10°    | the outline is the only part of a top-down percept that differs between two objects |
| motor-only steps while lost                    | the module is not asked to explain a hop                                            |

| not kept                                                         | what it did                                                                                                                    |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| four aim refinements (spread, weight, contrast, ratio)           | flat, within noise                                                                                                             |
| a 20 mm search leg                                               | overshot the object                                                                                                            |
| distance filters on the depth image                              | no change                                                                                                                      |
| widening the search circle                                       | worse, reverted                                                                                                                |
| walking home to where the object was last seen                   | worse, reverted                                                                                                                |
| a sideways departure                                             | see below                                                                                                                      |
| turning the sensor to face the surface (Monty's vertical orient) | knife `match/403` → `time_out/5000`, fork unfinished; every second step spent on attitude is a step not spent covering surface |
| the rim at 25° instead of 10°                                    | mug 130 → 285 on the first episode, same seed                                                                                  |
| a full descent under `OrientVertical` to read the spoon          | not attempted: it replaces the touch opening that makes the knife work, and leaves the fly unable to tell ground from wall     |

The **sideways departure** is the one worth keeping as a lesson. At thirty
episodes it looked like a twenty-seven per cent win. At a hundred and
thirty-seven it was nothing: 122 of 137 with it against 124 of 137 without,
mean 100 against 99. Thirty episodes cannot resolve a mean. Read the
full-budget count first, then the completions, then the mean.

One rule above is in the list on the strength of a different measurement from the
rest: the edge in the heading is worth **1 129 steps and one completion** on the
same 59 episodes — 55 of 59 matched and 29 082 steps against the build without
it at 54 of 59 and 32 211. It came from the frames rather than from a theory: the
patch straddles the rim at one step and lies flat on the top at the next, and the
four hundred steps an episode spends choosing between two candidate objects happen
in the flat ones.

That number deserves the same suspicion the sideways departure got, and the
sweep is answering it. The difference between the two builds is almost entirely
_which episodes lose the object and spend the whole five-thousand-step budget_:

| slice             | with the rim                  | without                        |
| ----------------- | ----------------------------- | ------------------------------ |
| first 23 episodes | 6 143 steps, 23/23, none lost | 6 039, 23/23, none             |
| first 31 episodes | 8 014 steps, 31/31, none lost | 14 063, 29 of 31, **one lost** |

On the stretch where neither build lost anything the two are level, and single
episodes differ by up to 625 either way: mug 68, 249 and 95 steps without the rim
against 130, 485 and 583 with it, and the knife the other way at 674 and 944
against 337 and 105. So the rim is **not** a saving on an episode that finishes.
It is one fewer loss — and because a loss costs five thousand steps while a
finish costs a few hundred, the trade pays even where the mean gets worse.
Subtract the one ceiling episode inside the 59-episode gap and the rest of that
slice favours the baseline by about 1 900, which is the same statement read from
the other side.

What the measurements also settled, and what bounds this policy: **a slow episode
is the module narrowing, not the fly failing.** `e_cups` ran 440 steps with two
candidates still possible while its evidence climbed a steady nine tenths of a
point per step, and the view that finally decided it was a flat one. The frames
agree: a mug episode that ran 583 steps showed **541 distinct patch images**, the
only repeat being the blank one, which came back 31 times. The fly was not
walking the same ground — it was walking ground the module could not use — which
is also why a coverage map, the next thing that looked worth building, is not.
And the 500-step eval ceiling counts only _informative_ steps — the engine refunds
a step that reached no module — so hiding more steps from the module cannot
stretch it, and the episodes that died at exactly 500 were genuinely still
converging.

## What a run costs

A whole-run measurement of the baseline, 140 episodes: 127 completed, mean 100
steps, 7 episodes reaching the 5000-step ceiling, 71,111 Monty steps, 29 minutes
39 seconds of wall clock. What those steps split into:

| episode outcome          | steps                  | share of the work |
| ------------------------ | ---------------------- | ----------------- |
| finished, 133 of them    | 36,111 total, mean 271 | 51%               |
| abandoned at the ceiling | 5,000 each, 7 of them  | 49%               |

Seven episodes out of a hundred and forty are half of the work. The 41-minute
run that prompted all of this differed from the 29-minute one in exactly one
thing: two more episodes that reached the ceiling. So the number to watch is the
**full-budget count** — and the point of every steering change above is to make
an episode that cannot finish either finish or leave, never to make a finished
one finish faster. For scale, the build before the last one spent 11,468 steps on
its first 41 episodes, mean 279 an episode, with no ceiling episode at all.

## Two things no steering can change

- **The patch reaches five centimetres, and the agent rides ten above the table.**
  `clip_value: 0.05` is a _reach_, not a near limit: every depth past it becomes
  the clip's own value, so the patch cannot see the table it floats over, and
  anything standing less than about five centimetres tall is out of reach from
  where the agent starts. The mug, at seven centimetres, is readable; the spoon,
  at one and a half, is eight and a half centimetres below the sensor and is not.
  `OrientHorizontal` cannot change altitude — it moves along local X and Z, and
  Monty's `yaw` turns about Y, so Y is up — which leaves `OrientVertical`'s
  `down_distance` as the only vertical motion in the action set. That is what the
  dive spends twelve steps on, and it is why a full descent is not the answer: the
  fly would have to give up the height the tall objects are visible from.
- **The eval ceiling is 500 steps, the train ceiling 1000, the total 5000.** The
  baseline's own 7 abandoned episodes sit under those numbers, and they were six
  spoons and a cracker box — one unreadable object is 45% of a run's cost. The two
  levers a policy has — get there sooner, or stop where you are — are what the rest
  of this file is about. Note that the ceiling counts **informative** steps only:
  the engine refunds a step that reached no module, so a step the motor system
  marks motor-only costs the episode nothing.

With the dataset's pack the same code asks a real connectome, and what it does
there is a question this example does not answer.

## Running it

```
cd examples/flyverse_plugin
mix deps.get
mix flyverse_plugin.pack /tmp/flyverse-demo
FLYVERSE_PACK=/tmp/flyverse-demo mix run --no-halt
```

`mix compile` builds the Rust engine first (`mix flyverse_plugin.engine`), so a
Rust toolchain is the one prerequisite `mix deps.get` does not fetch. It is built
when the library is absent or older than the crate, not on every compile — and it
has to be that way round: `priv/native` is ignored by git, so a `git clean`
removes the engine while `_build` still looks current, and a node whose NIF is
missing raises `function FlyversePlugin.Native.open/1 is undefined` and offers
nothing to the cluster. The task says so in full.

That starts a node that offers both plugins to itself. To offer them to a studio,
name the node and give it the cluster's secret and a seed — the same three
variables `examples/example_plugin` uses:

```
mix run --no-halt --name flyverse_plugin@127.0.0.1
MONTY_CLUSTER_SECRET=… MONTY_SEEDS=node1@127.0.0.1 mix run --no-halt --name …
```

`process-compose.yaml` at the application's root already does that: `node1`,
`node2`, `example_plugin` and `flyverse_plugin`, one process each, with
`FLYVERSE_PACK=../../tmp/flyverse-pack` — the same command
`examples/example_plugin` is started with, because a pack is data and not
something to wait for. Write it once (the `mix flyverse_plugin.pack` line above,
with `../../tmp/flyverse-pack` from this directory) and it survives a restart;
a node whose pack is missing still starts and refuses a policy with the sentence
that names that command.

Once the cluster is up, the experiment is opened by name, not from
`/experiments` (that page lists Monty's own configs):

```
http://localhost:4001/experiments/flyverse_plugin.10simobj_surf_agent
```

| Variable                | What it does                                                       |
| ----------------------- | ------------------------------------------------------------------ |
| `FLYVERSE_PACK`         | the connectome pack to step; `mix flyverse_plugin.pack` writes one |
| `--name …`              | what this VM is called; a VM cannot be renamed after it starts     |
| `MONTY_CLUSTER_SECRET`  | the cookie, the same string on every node that should join         |
| `MONTY_SEEDS`           | the nodes to reach, comma-separated                                |
| `PLUGIN_DISCOVERY=none` | takes part in no cluster at all                                    |

## The pack, and the plan beside it

A pack is flyverse's own four NPY arrays plus two files this example reads:
`manifest.json` (which flyverse's compiler writes too) and `plan.json`, which
says which model indices a policy drives and reads.

```json
{
  "drives": [[0], [1]],
  "readouts": [[2], [3]],
  "ticks": 200,
  "seed": 7
}
```

That is a fact about the pack: with the dataset, a group is a name in
`male_cns_v1_neural_io.json` and a list of body IDs, and the plan is how a person
turns that into indices. With `mix flyverse_plugin.pack` it is the four-neuron
demonstrator, which is not a fly: nothing in it came from a connectome, and a
behaviour that follows from it is a statement about the wiring that task wrote.

## Tests

```
mix test
cd native/flyverse_nif && cargo test
```

`mix test` writes its own packs into a temporary directory, so it needs no
dataset. `cargo test` holds the Poisson sampler to flyverse's `StimGen`: the
plugin samples against a tick counter it owns (a rate that changed must not
restart the stream), so the copy is a copy, and a test says so tick for tick.

## What it does not do

- **No learning module.** A step asks a learning module thousands of times over
  hypotheses, so the contract advertises rather than routes one — and beyond
  that, a connectome answers with spikes, not with evidence per hypothesis.
  Offering one would be a number invented to fill a shape.
- **No world.** A world is a core noun (`Monty.Studio.Setup` picks `:synthetic`,
  `:mujoco` or `:cad`), not a plugin kind. flyverse _has_ a world — a room, a
  body, wing aerodynamics, a ray-cast retina — but its library face exports only
  `lif`, `npy` and `pack`, so a NIF cannot reach the rest yet.
  `docs/research.md` §4 has the shape of that change.
