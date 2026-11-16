# Roadmap

Where this port stands, and the order the rest arrives in. The ordering is not
preference: each phase removes the reason the next one cannot be checked.

Three rules hold across every phase, and a change that breaks one is a bug, not
a trade-off:

1. **Module for module.** Python `a/b.py::C` is `Monty.A.B.C`. Never rename a
   mapped module to a prettier one; `mix monty.module_map.verify` enforces it.
2. **Monty's vocabulary.** Metres, degrees in actions, `wxyz` quaternions,
   semantic id `0` for background, `pose_vectors`, `sm_to_lm_matrix`, epochs.
   A Monty developer should recognise the experiment before noticing the Elixir.
3. **Functional core, actor shell.** Ported algorithms are pure modules that
   read like their Python; `Monty.Runtime.*` only routes, holds state and
   measures. Determinism is a feature: one RNG stream per episode.
4. **A module arrives with Monty's own test for it, translated.** One case in
   `tests/unit/**/test_*.py` becomes one ExUnit test that names the case it
   translates; where Monty drove a private method, ours drives the nearest
   public entry point and says so. A hand-written behaviour test states intent,
   never parity, and is not counted as such. Re-measure the count by listing
   Monty's `def test_` names (`monty-orig/tests/unit/**/test_*.py`) and grepping
   ours for them. The number is the command's to print and this file does not
   quote it: a count in prose is stale the week after it is written.

## Where the port stands

The v0.1 studio is built: the app and its gates, config composition, the module
map, the runtime, the studio pages, prerequisites, run history, and the headless
`mix monty.run` / `mix monty.bench`.

For any experiment the studio can show its wiring, its checks, how much of it is
ported, and — where ported — a real run.

The phases below are what remains. `mix monty.readiness` and
`mix monty.module_map.verify` print the live counts. Do not quote counts from
prose.

The classes a step runs through are also checked **function for function**:
`MIX_ENV=test mix run --no-start scripts/loop_map.exs` prints, per loop class,
which of Monty's methods have a counterpart here and which do not, with the
nearest name on the other side. A rename is a defect; a port-only helper is a
sub-step of a Monty method, or a deviation that has to be written down. The
script draws the same line on this side: a `defp` is a step inside a method and
is counted, a public function has to have a reason in the script's own table.

One pair of Monty's methods is absent rather than renamed, and it is a behaviour
question, not a name: Monty brackets every epoch with `pre_epoch` and
`post_epoch` — choose the interface for the mode, tell the interface and the
loggers, then save `model.pt`, `exp_state_dict.pt` and `config.pt` into a
directory named after the epoch, and count it. This port chooses the mode and the
objects once per phase, keeps the memory once per run, and counts epochs in the
run's record. Whether a run should write a memory release per epoch is a decision
about what a run leaves behind, so it is written down in
[`monty-differences.md`](monty-differences.md#225-two-epoch-brackets-have-no-counterpart-here)
rather than settled in passing.

## Phase 1 — the numeric core, done

Every class the loop of this experiment runs through is implemented — the maths,
the buffers, the hypotheses and their updater, the graph memory, the learning
module, the sensors, the goal generator and motor system, the model and the
experiment loop — and `Mix.Tasks.Monty.Readiness` and `Setup.ported/1` print
which as they are asked rather than this file remembering it. Two things from
that work are still open, both about the burst sampler:

- **The threshold refusal** —
  `test_init_fails_when_passed_invalid_evidence_threshold_config` — is
  translated, but not where Monty asserts it: Monty validates in the updater's
  constructor and this port parses the setting once when the module is built, so
  the case lives against `LearningModule.parse_config/2`.
- A burst is where "which hypotheses get proposed" is decided, and that is the
  one measured difference left on `test/evidence_lm/evidence_mujoco`: our best
  hypothesis climbs monotonically where Monty's highest leaves the graph every
  other step. Translate the rest of `evidence_lm_test.py` before hunting that
  difference by hand.

## Phase 2 — the environment bridge

Accuracy cannot be compared before the world is real, so this comes before
benchmarks rather than after. What is built: MuJoCo is what a run steps, either
through the compiled binding (`:ex_mujoco`) or Monty's own simulator in the
interpreter this release carries (`:mujoco`), and it is Monty's own
`MuJoCoSimulator`, agents, cameras and actuations in both cases, with no
checkout and nothing from PyPI. The observation transforms are Elixir
(`DepthTo3DLocations`, `MissingToMaxDepth`, `AddNoiseToRawDepthImage` and the
rest of [`environment_utils/transforms/`](../lib/monty/frameworks/environment_utils/transforms)),
a recorded episode replays through the real runtime
([`recording_episode_test.exs`](../test/monty/recording_episode_test.exs)), and a
sensor answers base64 PNGs so the page that draws a run's frames holds a
camera's.

The MuJoCo classes stay `:planned` in the map on purpose: their code is copied
rather than ported, so there is no Elixir module per class to point at, and
"ported" keeps meaning "there is an Elixir module to read"
([`from-monty.md`](from-monty.md) records the copy).

`Monty.Simulators.Port` is the boundary a world outside this release would come
through, tested in both directions: [`monty_simulator_peer.py`](../scripts/monty_simulator_peer.py)
is Monty's own `HabitatEnvironment` and eval interface in Monty's pinned conda
environment, and `Monty.Simulators.Habitat.Environment.HabitatEnvironment` is the
handle that would own it. Habitat-Sim is not carried — a conda package for
another Python, and on its way out of Monty — so a Habitat config is refused as a
world this build does not have rather than silently given MuJoCo's scene.

**What is left is the middle of an episode.** The random stream is Monty's
(`Monty.Random.Numpy` is NumPy's generator, `Monty.Random.Stream` the one stream
an episode draws from), so an episode's first action is Monty's to the last
digit, and the percept, given his actions, is his to the last bit. After that the
two action logs part: an episode ends on Monty's step in some of the comparison's
episodes and walks a different path in the rest. That is a diff of two logs, not a
design, and `scripts/probe_action_stream.exs` is the instrument that prints it.

Its first reading is that the opening is **already Monty's**. The patch's view on
the step his episode opens with is a flat five centimetres of table for both of us
— his own first percepts are empty too, and the object enters his patch at step 3 —
our world at reset is his to the last bit
([`probe_percept_parity.exs`](../scripts/probe_percept_parity.exs) reproduces his
first percept, `min_depth` and all), and the opening action is his to the last
digit: `move_forward 0.036434553` against his recorded `0.036434555`, which is
Monty's own `depth − desired − sensor z` on our own readings,
`0.0914345532655716 − 0.025 − 0.03`.

That is reproducible under every condition this was tried in: three runs back to
back, three worlds built in one process, eight CPU hogs, and a second MuJoCo world
rendering in another process at the same time — the centre pixel and the action
come out identical each time. But **not** under every length: asked to replay one
step the probe answers his number, and asked to replay three it answers
`0.035568021`, with a centre depth 0.87 mm off the one it printed for the same
state. Nothing in the probe reads the replay length before its first step, so
either the replay itself or something that outlives a step changes an earlier
answer.

So the opening line of that report is evidence and the rest of it is not, until
the replay is understood. What can be read already is the shape of the divergence
once the opening agrees: his second action is `orient_horizontal` with a rotation
of a thousandth of a degree — the systematic search his `_touch_object` runs when
the view finder's centre is more than a metre from anything — and ours is the same
`move_forward` again, which is what that procedure answers when the centre is
within a metre. Our percepts carry `object_coverage 0` and no `min_depth` at every
step after the first, while his patch sees the object from his step 3.

**Done when**: `mix monty.run base_config_10distinctobj_dist_agent` runs an
episode **against Monty's own world through the studio**, with no probe in the
loop, and its step count is Monty's for every episode of the epoch.

## Phase 3 — benchmarks and profiles

- `mix monty.bench` (exists) times the timestep loop per experiment shape.
- Accuracy harness against Monty's own benchmarks (`benchmarks/*.csv`,
  `benchmarks/results/`): the same episodes, the same seeds, one table.
- **Blocked as of 2026-11-16**: the experiment this phase's milestone names cannot
  run yet. `base_77obj_dist_agent` is killed while its model is being built, before
  step 0, when a process passes the 4 GB ceiling — at a 3 GB ceiling of its own it
  dies at `Total Heap Size: 459 908 514` words, about 3.7 GB. The library is 213 MB
  of heap and the module holds that library rather than copying it, so the six
  gigabytes are the library **copied between processes**: a term sent as a message
  is copied, and this one is maps and lists rather than off-heap binaries. The
  readings and the correction of a first, wrong one are in
  [`validation.md`](validation.md#where-the-77-object-benchmark-stops-2026-11-16).

  Unblocking it, in order:

  1. Count the hand-overs. `scripts/measure_step_memory.exs` grows a mode that
     starts the run with a ceiling above the need and prints every process the
     runtime registered with the heap each holds, so the copies are named rather
     than inferred.
  2. Hold the library once. `Monty.Studio.Memory` already caches it in
     `:persistent_term`; `Setup.model_spec/3` hands the term itself to
     `Monty.Runtime.Model`, whose init hands it to each module. The change is to
     pass the cache key plus the shape a module needs, and let a module read the
     library where it stands — the same move `Monty.Studio.Memory.built/2` already
     makes for the loader.
  3. Only then measure the step, which is where the remaining time goes.

- Profiling before optimisation: `:tprof` for where the time goes, `:eprof` for
  call counts, `:fprof` when order matters. Optimise the loop the profile names,
  with a bench before and after in the same commit.
- Parallelism is already legal where it is safe: vote rounds have deadlines, and
  a deadline hit is reported rather than hidden.

- **Several viewpoints at once, and whether it is worth it.** A run can already
  put a ring of patch cameras on one agent and give each its own learning module
  with a vote between them: a shipped config does exactly that, and it steps here
  today —
  `mix monty.run randrot_noise_10distinctobj_5lms_dist_agent --steps 6 --episodes 1 --world ex_mujoco`
  prints a step whose percepts are every patch, and a vote round that answered
  for every module. So nothing in the architecture has to change to start from
  several sides of the object at once.

  What is not known is whether it is better. A step costs what its slowest module
  costs — the modules are separate processes and run concurrently — so the trade
  is one step of work multiplied by the number of viewpoints against fewer steps
  to a conclusion. Reading it means the multi-view config beside its one-sensor
  config on one machine: the conclusion, the step count, and the wall clock, as
  the same table Phase 3 wants for the benchmark. The memory is the same problem
  the 77-object bullet above describes, once per module.

  Four side views and one from above is a layout no shipped config has. An
  agent's `sensor_configs` is where it would be written, and it would be this
  port's own experiment rather than Monty's — so it belongs in
  [`monty-differences.md`](monty-differences.md) as a deviation with its numbers,
  not quietly in `conf/`.

**Done when**: a run of `base_77obj_dist_agent` produces a recognition rate
within the tolerance Monty's own noisy runs show, with its step count, and the
bench table is a CI trend.

## Phase 4 — episodes, training, artifacts

- Epochs and training episodes over the ported pipeline; supervised LM ids;
  model save/load as graph files on the filesystem, with the metadata in Postgres
  (the split the run history already makes).
- Mementos, per-episode metrics, and the log handlers Monty ships (its WandB
  handler becomes the studio's evidence charts).
- `Monty.Prerequisites` becomes load-bearing: a run that needs a model says so
  before it starts, with the download one click away.

**Done when**: a training experiment trains, saves, and a later run loads it —
from the page and from `mix monty.run`.

## Phase 5 — the studio, finished

- **Live, and honest, from the first runnable experiment** (not a polish pass):
  a run in progress draws its own graphs — evidence per object against the step,
  the most likely hypothesis with its location and rotation, how many
  hypotheses are still possible and how many are inside the 20 % band — and the
  frames its sensors actually received, per sensor, per step. A chart that cannot
  be explained from the module's state is not shown: the point of the graph is to
  see Monty think, and of the frames to see what it was thinking about.
- Config editor: edit a group, see the composed diff and the snapshot check
  before saving; a config Monty would reject cannot be saved.
- Step inspector: the CMP payload a sensor sent and what a learning module did
  with it — the view a Monty developer will actually debug with.
- Run comparison: two runs of the same experiment, side by side.
- The teleop mirror (7 modules, `Teleop.*`) gets the same treatment.

## Phase 6 — upstream

- `docs/contributing-a-module.md` (to write): port a Python file in one
  afternoon, with the naming rule, the fixture recipe and the gates it must pass.
- A draft TBP RFC describing the actor split, the vote deadline experiment, and
  what the studio is for — written for Monty's maintainers, in Monty's terms.

## Not in scope

No pretrained `.pt`/torch checkpoint import (graphs only; rebuild by running a training
experiment); no GPU or EXLA requirement — Nx is a lever, not a demand. **Clustering is no
longer out of scope**: a node can be named and joined to a cluster ([cluster.md](cluster.md),
[container.md](container.md)), additively — with `MONTY_CLUSTER` unset nothing starts and
nothing changes. Habitat-Sim is not carried: a Habitat config is refused as a world this
build does not have, rather than silently given MuJoCo's scene. wandb is where it was —
`WandbWrapper` and the Python client exist and are tested offline; what a deployment adds is
credentials, not code.

Two things that are not scope decisions but _later milestones_ — Monty's parallel episodes
(built: `Partition` + `Jobs.Run.run_wave`) and an episode against a live world — are worked
out in [parallel-and-live.md](parallel-and-live.md).

## Decision: the pretrained library lives as long as the experiment

Monty loads pretrained models per learning module and per episode; the same
megabytes are read and parsed again for every episode of every epoch. We will not.

- **Constructed once, at experiment start**, by the run worker, from the
  experiment's configured model directory. One parse, one place that reports
  "these models, from this path, loaded in this long".
- **Handed to each episode as data.** A memory is an immutable value here, so a
  thousand episodes referencing the same library cost a reference each, not a
  copy. Nothing needs a process to guard it, which means nothing can be mutated
  behind an experiment's back.
- **Read-only for recognition.** Eval episodes match against the library and
  never extend it, so there is nothing to leak into the next experiment.
- **Training episodes write to their own memory**, seeded from the library, and
  are persisted explicitly at the end of an epoch. A training run that crashes
  half-way therefore cannot corrupt the library a later experiment starts from.
- **A process only if loading becomes lazy**: a library too large to parse up
  front becomes a reader with a read-only contract, not a mutable cache.

"Constructed at experiment start" is therefore not a cache with a lifetime
problem — it is the experiment's input, with the experiment's lifetime.
