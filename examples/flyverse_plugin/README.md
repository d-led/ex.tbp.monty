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

The constants are chosen to be readable, not to be right: four millimetres a
step, five degrees of base turn, two spikes for a full bend, `1/depth` at four
hertz per inverse metre. A pack of four neurons is not a nervous system, and a
score it produces is a score of this wiring, not of a fly, a brain, or Monty.
What would support a claim is the dataset's connectome, a body with muscles, and
a measured comparison against Monty's own surf policy; none of those are here,
and no number on any page of a run should be read as if they were.

## What the decision is

```
   left half of the depth image   --1/depth--> Hz --> neurons (0) --+200--> readout (2)
   right half of the depth image  --1/depth--> Hz --> neurons (1) --+200--> readout (3)
```

Each step: nearness (`1 / depth`) per half of the image becomes a Poisson drive
on one neuron group; the network steps 20 ms of 0.1 ms ticks in Rust; and the
difference of the two readout spike counts, low-passed with flyverse's own 30 ms
motor time constant, decides where the sensor goes next. More spikes on the
left means the left half of the view is nearer, so the sensor yaws that way;
spikes on the right yaw the other; no preference at all walks straight ahead,
because a balanced view is seeing the thing it is meant to reach and moving
forward is what closes the gap.

The action is one or the other, never both. A turn is `OrientHorizontal` with no
slide — five degrees per step — because `TurnLeft`/`TurnRight` are the distant
agent's actions and the surf agent a MuJoCo world hands us has no
`actuate_turn_*` at all. A walk is `MoveForward` at four millimetres, Monty's own
surf-agent step.

The beginning of an episode is not the network's, and this is the part worth
being honest about: a patch that is not on the object has no left-versus-right
difference to steer by, so a network asked to walk to the object can only turn on
the spot. The first steps are therefore Monty's `SurfacePolicy._touch_object`,
copied with its own numbers — below a tenth of the patch covered
(`object_coverage`), one `MoveForward` across the whole gap the view finder can
see, and, when the view finder sees nothing within a metre, a step round a search
circle ten centimetres ahead, thirty degrees at a time, until something comes
into view. Twenty centimetres is one step that way, where a four-millimetre crawl
is fifty steps of the same view. Network steering starts when the patch is on
something, and stops when it is not.

The rates, the gain and the action mapping are this plugin's and
`FlyversePlugin.Policy` says so line by line. The dynamics are flyverse's. With
the dataset's pack the same code asks a real connectome, and what it does there
is a question this example does not answer.

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
