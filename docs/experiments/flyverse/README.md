# A connectome steering a run

[The CAD walk-through](../cad/README.md) is a part becoming something to
recognise. This one is a **decision**: where the sensor looks next, taken by a
spiking network rather than by Monty's own policy.

`examples/flyverse_plugin` is a plugin host — a node in the cluster that is not
this application — and it offers two things: a motor policy that steps
[flyverse](https://github.com/djmango/flyverse)'s leaky integrate-and-fire
engine inside a Rustler NIF, and the experiment that names that policy. The
dataset it is written for is 150 MB and is in no checkout, so the pack on this
machine is a four-neuron demonstrator: what follows shows the seam working, not
a fly solving a benchmark. [The plugin's own study](../../../examples/flyverse_plugin/docs/research.md)
is where that line is drawn properly.

![The experiment a plugin defines](images/01-experiment-page.png)

## 1. The experiment is somebody else's

The page's name says whose run it is, and two badges say who answered and what
will step it: `from flyverse_plugin@127.0.0.1` and
`steps with flyverse_plugin.lif_steering@0.1.0 on flyverse_plugin@127.0.0.1`.

That second badge exists because the Motor system box beside the diagram names
the **config's** policy, `SurfacePolicyCurvatureInformed` — the one this run does
not build. A definition replaces the config's motor system with the policy the
offering node registered, so a page that showed only the config would describe a
run that cannot happen. The badge says the same words the run's record writes
into `motor_policy`, so a page and a record of one run cannot disagree.

Everything else on the page is Monty's: ten similar YCB objects, the patch and
the view finder, one evidence learning module, fourteen evaluation epochs, and
13 of 13 classes ported here.

## 2. Run it

`Run it` steps the config as it stands and the policy answers once per step. The
config asks for 140 episodes — every object in every rotation — and the
`episodes` field above the button takes a slice of them, which is what this run
used: one.

## 3. What the run says

![The finished run](images/02-run.png)

Four lines of the record are the whole story of a plugin-defined run:

| Field          | What it says                                                                                |
| -------------- | ------------------------------------------------------------------------------------------- |
| `defined_by`   | `flyverse_plugin.10simobj_surf_agent@0.1.0 on flyverse_plugin@…` — who wrote the definition |
| `motor_policy` | `flyverse_plugin.lif_steering@0.1.0 on flyverse_plugin@…` — who decided every step          |
| `world`        | `ex_mujoco` — the scene MuJoCo steps, compiled into this node                               |
| `seed`         | `42` — the base config's own, written into the definition rather than inherited             |

130 steps, 13 goals, 1.83 s inside the modules and 4.7 s of wall clock, and
`Judged — recognised 1 of 1`: the learning module concluded `match` on `mug` at
evidence 119.20. The sensor was walked there by spikes.

## 4. What decided, once per step

The policy is a value that crosses the cluster boundary and comes back with
every call — the caller holds it, the host computes it — which is why six
episodes in parallel do not share one heading. Inside, in the plugin's own words:

```
 left half   --1/depth-->  80 + 4x Hz  --> drive 0 --> readout 2 --+
                                                                    +--> difference
 right half  --1/depth-->  80 + 4x Hz  --> drive 1 --> readout 3 --+

 difference --30 ms low-pass--> wish --5 deg x tanh(wish/2)--> yaw
```

While the patch is not on the object the answer is Monty's own `_touch_object`
and the network is not asked, because an empty patch says the same thing
everywhere. [The plugin's README](../../../examples/flyverse_plugin/README.md)
has the rest: the 80 Hz tonic, the four hertz per inverse metre, the 20 ms window
stepped in 0.1 ms ticks, and why each of those is not free.

### What the network is fed, and how wide

The two halves above are the _demonstrator's_ plan, not a limit of the
interface: the pack carries `plan.json`, and the number of drive groups in it is
the number of bands the view is cut into. Two groups is a left and a right; a
pack that names one index per group is driven by a column per group, which is the
shape a retina has and the shape the dataset's sensory inventory is in. The
decision stays two-sided either way — the wish is the difference of the two
readouts, because a walk with turns in it has two.

**Two ways to drive a group.** `{:rate, hz}` is the Poisson sampler above.
`{:ticks, [[tick, ...], ...]}` is a **recording**: one list of tick numbers per
neuron of the group, in absolute ticks of the simulation's clock, which
`reset/1` sets to zero. That is what the dataset's `vnc_sensory` is — which
sensory neuron fired when, recorded rather than generated — and it is presented
by copying it in: a tick the window has not reached yet fires when the window
reaches it, a tick already behind it does not fire again, and a group of three
neurons given two lists is refused rather than guessed at.

**Two channels for it.** The default is depth: `1 / depth` of the nearest thing
in each band, capped at a 10 m horizon. `FLYVERSE_SENSOR=rgba` on the host
switches it to what a photoreceptor could answer — the luminance of the colours
the same sensor recorded, and per band the _change_ since the previous step,
taken as a magnitude because a growing dark shape looms as much as a growing
light one. Depth is still what "is the patch on the object" is asked of: that is
geometry, and a band's brightness cannot answer it. Measured on this Mac, one
episode of this config, seed 42, `ex_mujoco`:

| channel          | steps | verdict   | strongest evidence |
| ---------------- | ----- | --------- | ------------------ |
| depth (default)  | 130   | `correct` | 119.20             |
| colours (`rgba`) | 55    | `correct` | 48.58              |

Both recognised the same mug; the colour run got there in half the steps and
stopped on less evidence. Neither is "the fly's" answer, and the host setting is
which one a run uses.

What is still **not** what a fly gets is a spike train _per band from its own
eyes_: a recording can be presented, and a luminance change per band can be
computed, but nothing here derives one from the other yet — the dataset's
`sensory` replay and a rendered fly retina are the two ends, and this example has
the socket between them.

## 5. What was wrong when this page was first written

The host was up, answering rpc, and invisible: the studio answered _"no experiment
here is named … and no node in this cluster says it hosts plugins"_. The cause was
ours, in both example hosts: libcluster's `Cluster.Strategy.Epmd` dials its hosts
in `init/1` and then sleeps for `config[:timeout]`, whose default is `:infinity`
— one dial for the life of the node. A plugin host boots before the studio (it
has no HTTP to wait for) and never looked again, and a studio restart lost it for
good. Both hosts now re-dial every five seconds, and the page above is the check
that they do.

## A fly's body in MuJoCo: what is stopping us

Nothing about **NeuroMechFly** is macOS-only, and nothing about MuJoCo is
missing on this side. Checked against its own installation page
([2.1.1](https://neuromechfly.org/2.1.1/installation/)): it is `pip install
flygym`, MuJoCo arrives through the Python bindings, `flygym[warp]` is a
GPU backend, and a headless machine switches the renderer to EGL
(`MUJOCO_GL=egl`). The macOS-only note in
[the study](../../../examples/flyverse_plugin/docs/research.md) is about
**flyBrain**, whose engine and world are `#[cfg(target_os = "macos")]` Metal
kernels over MuJoCo 3.9 — not about FlyGym.

What is stopping us is three things, in the order they bite:

1. **The body speaks Python and the policy speaks Elixir.** FlyGym is a Python
   package, so a fly body would live in the Python world this application already
   carries (`world: MuJoCo (in this application)`), not in `ex_mujoco`, which is
   Rust and cannot load it. The connectome stays where it is — a NIF in the BEAM —
   and the action crosses once per window, which is the shape the plugin contract
   already has (a motor policy called once per step). That is a port, not a wall.
2. **Monty's actions are not joint torques.** `OrientHorizontal` and
   `OrientVertical` carry a yaw, a pitch and a forward distance, because the body
   they were written for is a patch agent on a camera. A fly needs its six legs
   driven — FlyGym's own controllers are CPG, rule-based, hybrid and turning
   (its tutorials 4a–4d) or muscles (tutorial 6). Bridging the two means writing a
   controller that takes Monty's action and produces leg targets, which is a small
   fly controller and not a policy option.
3. **The connectome we can simulate has no motor side to drive it.** MaleCNS gives
   neurons and synapses; it does not give the descending-neuron → motor-neuron →
   muscle mapping that a body needs, and flyverse's own README says the embodied
   fly "skitters rather than flies", reaches no meals, and takes its main sensory
   input from a canned `vnc_sensory` replay because the dataset has no ventral
   nerve cord, no muscles and no donor body state. Driving NeuroMechFly's muscles
   from that connectome would need a mapping neither dataset ships.

So the next step that _is_ ours is the second one: a Python-world fly body, and a
controller between Monty's actions and its legs. The input side is already the
socket a real retina or a real replay plugs into (above).

### A body: it is composed, and it steps

The first step towards a fly body is done and is measured, not argued:
`examples/flyverse_plugin/scripts/fly_body.py` composes a **NeuroMechFly** in a
flat MuJoCo world, with its legs drivable, and steps it.

- A bare `NeuroMechFly` is a body with **no joints and no actuators**; the legs
  become drivable when a skeleton's active leg dofs are added and a position
  actuator is named for each — 6 legs, **42 leg dofs, 42 actuators**, `nq 49`,
  `nu 48`, timestep 0.1 ms.
- The action surface a Monty action has to be mapped onto is
  `set_actuator_inputs(fly, ActuatorType.POSITION, targets)` plus
  `set_leg_adhesion_states(fly, six flags)`; the percept a fly policy would get
  back is `get_ommatidia_readouts(fly)` — **2 eyes × 721 ommatidia** — and
  `get_raw_vision(fly)`, two 512×450 RGB views.
- Driven by a crude antiphase stride, the thorax moved 5.4 cm along x in 800
  steps. That is the bridge working, not a gait: it sinks as it goes, and a real
  gait is the next piece.

**It needs its own interpreter.** FlyGym installs MuJoCo **3.16**; the
interpreter `priv/monty_py/world.py` runs in is pinned to **4.0.1** for reasons
`config/pythonx.exs` records, and one interpreter cannot hold both. So a fly body
is a second interpreter beside the one the BEAM carries — the shape the plugin
hosts already have — and the script says how to make one:

```sh
python3 -m venv /tmp/fly && /tmp/fly/bin/pip install flygym
/tmp/fly/bin/python examples/flyverse_plugin/scripts/fly_body.py
```

What that leaves, in order: a gait (FlyGym's `flygym[examples]` extra carries
CPG, rule-based and turning controllers), the mapping from Monty's
yaw/pitch/stride onto that controller's commands, and a world interface so the
studio's Run button can start it.

## Starting it yourself

```sh
cd examples/flyverse_plugin && mix deps.get
mix flyverse_plugin.pack ../../tmp/flyverse-pack   # once: the pack is data
process-compose up                                 # four processes: two studios, two hosts
```

then
[the experiment](http://localhost:4001/experiments/flyverse_plugin.10simobj_surf_agent)
on either studio node. A host whose pack is missing still starts and refuses a
policy with the sentence that names the command above, rather than inventing a
connectome to stand in for one.

## What it does not claim

- **The demonstrator is not a fly.** Four neurons and two edges; its behaviour is
  a statement about the wiring `mix flyverse_plugin.pack` wrote.
- **With the dataset, the policy's answer is a question.** flyverse's own README
  is the honest frame: the embodied fly skitters rather than flies, its haltere
  probe found no steering response to an imposed rotation, and its main sensory
  input is a canned replay. A policy driven by that connectome is an experiment,
  not a result.
- **Nothing here ran against the 150 MB connectome.** The plan a person would
  write for the real pack is untested, and the first thing to check is that the
  group indices it names are the ones the dataset's own annotations give.
