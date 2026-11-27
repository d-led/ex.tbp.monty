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

What the network is fed is a **rate**, not a spike train, and the rate is a
summary of a depth image rather than a photoreceptor's: `1 / depth` of the nearest
thing in each band, capped at a 10 m horizon. That is the honest boundary of this
example, and it is why the page above is a check that the seam works rather than a
claim about a fly — [the study](../../../examples/flyverse_plugin/docs/research.md)
says what a faithful input would need (the VNC sensory replay the dataset carries,
which is a spike train and would need the plan's groups to be fed one spike
train per group rather than one rate).

## 5. What was wrong when this page was first written

The host was up, answering rpc, and invisible: the studio answered _"no experiment
here is named … and no node in this cluster says it hosts plugins"_. The cause was
ours, in both example hosts: libcluster's `Cluster.Strategy.Epmd` dials its hosts
in `init/1` and then sleeps for `config[:timeout]`, whose default is `:infinity`
— one dial for the life of the node. A plugin host boots before the studio (it
has no HTTP to wait for) and never looked again, and a studio restart lost it for
good. Both hosts now re-dial every five seconds, and the page above is the check
that they do.

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
