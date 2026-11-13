# A connectome in a plugin: what is possible, and what this example does

Two repositories were on the table, `/src/flyverse` and `/src/flyBrain`. Both are
MIT, both are native Rust simulations of a fruit-fly connectome driving a body,
and both are usable from the BEAM with Rustler. They are not equally usable, and
neither of them is a _learning module_. This page is the reasoning, the numbers
it rests on, and what is left to do.

## 1. What each repository is

|                   | flyverse                                                                             | flyBrain                                                                          |
| ----------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| what it simulates | MaleCNS v1.0: 166,700 neurons, 24,559,135 signed edges                               | FlyWire v630 / v783 and MaleCNS: 127,400 / 138,639 / 166,700 neurons              |
| engine            | leaky integrate-and-fire in plain Rust (`rayon`, no GPU)                             | the same IF convention in Metal compute kernels (`objc2-metal`)                   |
| what a body is    | a 600 × 440 mm room, blade-element wings, a ray-cast retina with 892 columns per eye | MuJoCo 3.9 with an exported NeuroMechFly, plus a GLFW viewer                      |
| library face      | `lif`, `npy`, `pack` — three modules                                                 | ~26 modules, but the engine, world and renderer are `#[cfg(target_os = "macos")]` |
| data in the repo  | everything except the pack                                                           | everything except the packs (`outputs/packs/` is not in the checkout)             |
| builds where      | anywhere Rust builds                                                                 | macOS on Apple silicon, with MuJoCo 3.9 bootstrapped through FlyGym               |

The decisive difference is not the neuron count. It is that flyverse's engine is
`cargo`-buildable on a Linux runner and flyBrain's is not: a NIF that only links
on macOS is a NIF no CI job in this workspace can compile, and an example whose
tests only run on one machine is not an example.

The dataset is absent from both checkouts. flyverse's pack is about 150 MB
(`destinations.npy` 4 B × 24.5 M edges, `signed_counts.npy` 2 B × 24.5 M,
`row_ptr.npy` 4 B × 166,701, `neuron_ids.npy` 8 B × 166,700) and its README says
so rather than shipping it. Everything else it needs is present and small: the
neuron-group annotations (`assets/male_cns_v1_neural_io.json`, 67 KB), the
mechanosensory inventory, the retinotopy and spectral classes, the 6,370-body-ID
`vnc_sensory` target set, and soma positions.

## 2. The three kinds a plugin can be, against two connectomes

`MontyPlugin` has three kinds. Each is a different question about a synapse.

| Kind               | The question                                                                                              | A connectome's answer                                                                                                             |
| ------------------ | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `:learning_module` | "how much evidence does this hypothesis have?" — thousands of times per step, so a step must own the code | spikes, not evidence. A number mapped from a rate onto Monty's evidence would be invented here and labelled as belonging to a fly |
| `:experiment`      | "what run do you ask for?" — asked once, as data                                                          | a definition, which is fair: it is data about a config                                                                            |
| `:motor_policy`    | "where does the sensor go next?" — called once per step, with a small value that crosses                  | exactly what a 2 ms control window of a 300-neuron–166k-neuron network can answer                                                 |

So the kind that fits is `:motor_policy`, and the example offers one. It also
offers the `:experiment` that names it, because a definition that names a policy
nobody offers is a run that cannot start.

**What does not fit at all** is the thing both repositories are actually about: a
world. A world is not a plugin kind — it is `Monty.Simulators.Environment`, and
`Monty.Studio.Setup` chooses one of `:synthetic`, `:mujoco`, `:cad`. A CAD part
became one by adding a clause there, in the core application. A fly could become
one the same way, and §4 is the shape of that.

## 3. What was built, and the numbers it rests on

`examples/flyverse_plugin` is an application with two plugins and a Rustler
boundary (`native/flyverse_nif`, ~330 lines of Rust) over
`flyverse::{pack, lif}` at a pinned commit. The NIF exposes:

```
open(directory)       -> {:ok, connectome} | {:error, {code, sentence}}
census(connectome)    -> {neurons, edges}
new(connectome, drives, rates, readouts, seed) -> {:ok, simulation}
window(simulation, connectome, ticks, rates)   -> {:ok, {counts, spikes, total}}
reset(simulation)     -> :ok
```

`FlyversePlugin.Policy` turns a depth image into two Poisson drives (`1 / depth`
per half of the image, × 4 Hz per inverse metre, capped at 400 Hz), steps the
network, and turns the difference of the two readout spike counts into an
`OrientHorizontal` turn or a `MoveForward`. The turn is the surf agent's own,
not the distant agent's `TurnLeft`/`TurnRight`: a MuJoCo world gives a surf agent
a yaw and no `actuate_turn_*` at all, and an action it does not implement is an
action it skips.

Measured on the four-neuron demonstrator the pack task writes (seed 7, 200 ticks
= 20 ms per step, 10 steps):

| drive on one group | spikes in that group's readout | spikes in the other |
| -----------------: | -----------------------------: | ------------------: |
|               0 Hz |                              0 |                   0 |
|              40 Hz |                              3 |                   0 |
|              80 Hz |                             10 |                   0 |
|             160 Hz |                             20 |                   0 |
|             300 Hz |                             27 |                   0 |
|             600 Hz |                             39 |                   0 |

Monotone, and one-sided: a drive on the left group never makes the right readout
fire. `reset/1` makes the next window identical to the first, so an episode is
reproducible from its seed.

**A spike is not a rate.** At 0.1 ms a tick, one spike in a 20 ms window is
50 Hz, and one in 2 ms (flyverse's own `WINDOW_STEPS = 20`) is 500 Hz. So the
policy low-passes the difference with flyverse's own `MOTOR_TAU_S = 0.030`
instead of using a count as a rate — which also gives a silent network the wish
it had, and therefore a walk some momentum.

## 4. What a world would take

Ordered, and none of it started:

1. **Export the world from flyverse.** `src/lib.rs` declares three modules;
   `main.rs` declares twelve more. Adding `pub mod room; pub mod body; pub mod
wing; pub mod vision; pub mod groups; pub mod sim;` is additive, and all of
   them are pure Rust — no GPU, no system library. `sim::World::new(pack, seed,
somas)` is already the entry point the CLI uses, `somas` being
   `data/soma_positions.f32`.
2. **A NIF resource that owns a `World`.** One `advance()` per Monty step is one
   2 ms control window; `motors()`, `sensors()`, `frame_json()` and `group_hz/1`
   are already answers.
3. **Decide what a fly's retina is as a sensor module's percept.** This is the
   design question, not plumbing. flyverse casts one ray per retinotopic column
   (892 per eye) and drives photoreceptors; Monty's sensor modules expect
   `depth`, `rgba`, `semantic_3d` and `sensor_frame_data` for a patch. A camera
   rendering of the room would give the second and not be the first, and calling
   it the fly's view would be a lie about what the connectome saw.
4. **A clause in `Monty.Studio.Setup.world/4`** and `MONTY_WORLD=fly` — the seam
   the CAD part used, in the core application. That tree was held by another
   agent while this example was written, and it is where this work would collide.
5. **An agent whose actions are the world's.** A fly has no leg kinematics in
   this model and no `MoveForward`; either the sensor rides on the fly (Monty
   steers, the connectome is observed) or an action is imposed on the body (the
   connectome stops deciding). Both are experiments worth doing; neither is
   plumbing.

A `:world` _plugin kind_ would be a contract change in `ex_monty_plugin` —
another kind, and deciding whether a world is looked up like a policy or handed
over at run start. Not attempted here.

## 5. What Rustler cost, and what it taught

Each of these cost a compile-and-run cycle; they are the useful part of the
example for the next NIF over somebody else's simulation.

- **`Connectome` cannot be built in memory.** Its arrays are public but
  `_keep: Vec<Npy>` is private, so a network has to arrive through
  `Connectome::load` — four files on disk. Hence `FlyversePlugin.Pack`, an NPY
  writer: a pack must have its payload start on an 8-byte boundary, carry the
  descr flyverse expects (`<u8`, `<u4`, `<u4`, `<i2`), and state its shape as
  `(n,)`. A writer whose output the engine refuses is a bug, so `mix
flyverse_plugin.pack` opens what it wrote before it reports success.
- **`Connectome::load` leaks on purpose** (`Box::leak`, so a 24-million-edge
  graph is not copied per step). A pack is therefore opened once per VM and
  memoised (`FlyversePlugin.Networks`); opening one per policy would leak 150 MB
  an episode.
- **A resource is not a term another node understands.** The simulation cannot
  travel, so the policy value carries its name and the plugin says `placement:
:owner_only`. This is the worked example of that placement, which until now was
  a documented claim (`docs/plugins.md`).
- **`Result<(), E>` is `{:ok, {}}`.** A reset must answer `:ok`, so that NIF
  returns a `Term` and encodes `("error", refusal)` itself rather than letting a
  unit type through the boundary.
- **A rate that changes must not restart the Poisson stream.** flyverse's
  `StimGen` restarts on construction, and a policy changes its drive every step,
  so the sampler is re-derived against one tick counter the resource owns — with
  `cargo test` holding it equal to `StimGen` tick for tick, so the copy cannot
  drift quietly.
- **Rayon inside a NIF is fine** at this size (`Lif::step` uses
  `par_chunks_mut`), as long as a call is one window and not one tick: 20 ticks
  per call at 166k neurons is the ~2 ms a window flyverse itself measures.

## 6. What this example does not claim

- **The demonstrator is not a fly.** Four neurons, two edges, and a behaviour
  that follows from them is a statement about the wiring `mix
flyverse_plugin.pack` wrote.
- **With the dataset, the policy's answer is a question.** flyverse's own README
  is the honest frame: the embodied fly skitters rather than flies, its haltere
  probe found no steering response to an imposed rotation (`+0.00044`, `t =
0.05`, bounded at ±0.02), it reaches no meals, and its main sensory input is
  the _canned_ `vnc_sensory` replay because the dataset has no ventral nerve
  cord, no muscles and no donor body state. A policy driven by that connectome is
  an experiment, not a result.
- **FlyBrain's world integration is its authors' word**, not a recovered fly:
  "engineered embodiment, not a recovered biological fly" — and the same sentence
  governs anything built on it.
- **Nothing here ran against the dataset.** It is in no checkout, so the
  `plan.json` a person would write for the real pack is untested, and the first
  thing to check is that the group indices a plan names are the ones
  `male_cns_v1_neural_io.json` gives.
