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
   never parity, and is not counted as such. Re-measure the count with the
   one-liner in `handover.md` §12 — at the end of 2026-11-06 it was **22 of 652**,
   all twenty-two the burst sampler's.

## Done — v0.1, the studio

| Piece                                                                                         | State |
| --------------------------------------------------------------------------------------------- | ----- |
| Phoenix/OTP app, Postgres, quality gates, CI                                                  | done  |
| `Monty.Cmp`, `Monty.Geometry`                                                                 | done  |
| `Monty.Config` — Hydra composition, resolvers, snapshot parity (`mix monty.config.snapshots`) | done  |
| `Monty.ModuleMap` — every Monty file mapped, target resolution, verification                  | done  |
| `Monty.Runtime` — one process per module, step barriers, vote rounds with deadlines           | done  |
| `Monty.Studio` — faceted index, setup + checks, builder, diagram, synthetic run, frames       | done  |
| `Monty.Prerequisites` — streaming downloads into Monty's paths                                | done  |
| Run history in Postgres, delete with confirmation                                             | done  |
| Headless `mix monty.run`, `mix monty.bench`                                                   | done  |

What the studio can say about an experiment today: its wiring, its checks
(Monty's own connectivity rules), how much of it is ported, and — for the ported
part — a real run. The "not ported yet" line is the backlog below, in one
sentence.

## Phase 1 — the numeric core, in dependency order

Each module arrives with the Python test that specifies it, translated, and a
fixture recorded from Monty where floating point is involved. `Setup.ported/1`
should move with every commit; when a mapped class is implemented,
`Setup.model_spec/2` uses it instead of the synthetic stand-in, so the page and
`mix monty.run` stop calling it a stand-in the day it lands.

1. **`math.py`, `geometry.py::Rotation`, `frameworks/utils/spatial_arithmetics.py`**
   — the tolerances every comparison shares, a rotation with exactly one spelling
   (quaternion `wxyz`, extrinsic Euler order, scipy's behaviour without scipy),
   and the pose-vector arithmetic everything later measures with. **Ported**:
   `TangentFrame` transport stays orthonormal over a thousand steps, and a
   mirrored frame shows up as a large alignment error instead of a silent zero.
2. **`frameworks/models/buffer.py`** — `FeatureAtLocationBuffer`,
   `BufferEncoder`. **Ported**: the buffer is a value (every Python mutation
   returns a new buffer), NaN padding is `nil`, and encoders are registered per
   module because Elixir structs have no parent classes.
3. **`evidence_matching/hypotheses.py`** — `Hypotheses` (**ported**: four
   parallel columns plus `take/2` for the subset a module still believes), then
   `hypotheses_updater/` (`BurstSamplingHypothesesUpdater`, `Displacer`,
   `EvidenceSlopeTracker`). Property tests for evidence updates, fixtures for
   the displacement. The pieces the updater is injected with are already ported:
   `FeatureEvidence.Calculator` (**ported**: numeric, circular and categorical
   comparisons, weighted per feature) and the two `FeaturesForMatching`
   selectors (**ported**).

   **`BurstSamplingHypothesesUpdater` (ported, 22 of Monty's 24 cases
   translated)** — the count per burst, the trigger and its duration, the
   tracker per graph id, the maximum slope the decision reads, the poses a burst
   proposes. What is open, and what the last four cases wait on:

   - **`features_for_matching_selector` is not wired into the sampler.** Monty's
     `DefaultFeaturesForMatchingSelector` turns feature evidence off for a
     channel with no feature weights, and whenever `feature_evidence_increment
<= 0`; this port always starts a newly sampled hypothesis with the node's
     own feature evidence. Port the selector into the updater and translate
     `test_sample_new_hypotheses_with_feature_matching` /
     `..._without_feature_matching`.
   - **The threshold refusal** —
     `test_init_fails_when_passed_invalid_evidence_threshold_config` — is
     translated, but not where Monty asserts it: Monty validates in the
     updater's constructor and this port parses the setting once when the module
     is built, so the case lives against `LearningModule.parse_config/2`.
   - A burst is where "which hypotheses get proposed" is decided, and that is
     the one measured difference left on `test/evidence_lm/evidence_mujoco`: our
     best hypothesis climbs monotonically where Monty's highest leaves the graph
     every other step. Translate the rest of this file's neighbours
     (`evidence_lm_test.py`, 16 cases) before hunting that difference by hand.

4. **`graph_memory/`** — `GraphMemory`, `ObjectModel`, `features`/`locations`
   bookkeeping. Fixtures: a small graph saved by Monty, loaded identically.
5. **`evidence_matching/learning_module.py`** — `EvidenceGraphLM`. The first real
   learning module; the `Setup` diagram's `learning_module_0` becomes genuinely
   ported rather than "planned".
6. **`sensor_modules/`** — `ObservationProcessor`, `SurfaceNormalMethod`,
   `SnapshotTelemetry`, `CameraSM`, then `two_d_sensor_module`. Golden-file
   tests on a recorded observation, feature by feature.
7. **`goal_generation.py`** — `EvidenceGoalGenerator` (and
   `GraphGoalGenerator`), then `motor_policies.py`, `motor_policy_selectors.py`,
   `motor_system.py`.
8. **`monty_base.py`, `graph_matching.py`, `evidence_matching/model.py`** — the
   classes that wire modules together; here the runtime's routing is replaced by
   the ported one where it is behaviour, and stays where it is supervision.
   **`evidence_matching/model.py` done:**
   `Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching`
   is the model a config naming it starts — the class is the name a run uses and
   `Monty.Runtime.Model` is the processes behind it — while a config naming a
   model this port has not written keeps running on the runtime, and the setup
   page says which of the two it got.
9. **`experiments/`** — `MontyExperiment`, `MontySupervisedObjectPretraining…`,
   `MontyObjectRecognition…`: epochs, episodes, recognition policy, hooks.
   **Episode loop done:** `Monty.Frameworks.Experiments.MontyExperiment.run_episode_steps/2`
   is Monty's `run_episode_steps`, and `Monty.Studio.Jobs.Run` drives every run
   through it — the step, the policy and the counter stay where they are, and the
   loop is the experiment's again. A stop and a step that dies come back as an
   outcome rather than an exception, which is the one place this port's needs go
   beyond Monty's. Epochs are not written: `MontyObjectRecognitionExperiment` only
   overrides `pre_episode` to call a base hook that is `pass` in Monty, so the
   subclass follows the epoch loop rather than leading it.

**Done when**: `base_config_10distinctobj_dist_agent` reports `ported here 12/12`
and a run of it is the ported pipeline, not stand-ins.

## Phase 2 — the environment bridge

Accuracy cannot be compared before the world is real, so this comes before
benchmarks rather than after.

- **Done, and MuJoCo is what a run steps.** MuJoCo is the default world
  (`config/config.exs`): Monty's own simulator, copied file for file into
  `priv/monty_py` and driven in the interpreter the release carries
  (`Monty.Simulators.Mujoco.{Host,Environment}`), so a step is Monty's own
  `MuJoCoSimulator`, its agents, cameras and actuations, with no checkout and
  nothing from PyPI. Its classes stay `:planned` in the map on purpose: the code
  is copied rather than ported, so there is no Elixir module per class to point
  at. Units and quirks cross unchanged — metres, `wxyz` quaternions decoded into
  `Monty.Geometry.Rotation`, sensor positions relative to the agent — and a
  config's own model runs against it
  ([`scripts/probe_world_episodes.exs`](../scripts/probe_world_episodes.exs)).
  What that comparison shows — objects agree, step counts do not, because of the
  random-stream deviation of §2.1 in [`monty-differences.md`](monty-differences.md) — is in
  [`validation.md`](validation.md).
- **The port, and what it is still for.** `Monty.Simulators.Port` is the boundary
  a world outside this release would come through, tested in both directions:
  [`scripts/monty_simulator_peer.py`](../scripts/monty_simulator_peer.py) is
  Monty's own `HabitatEnvironment` and eval interface in Monty's pinned conda
  environment, and
  `Monty.Simulators.Habitat.Environment.HabitatEnvironment` is the handle that
  would own it. Habitat-Sim is not carried — a conda package for another Python,
  and on its way out of Monty — so a Habitat config is refused as a world this
  build does not have rather than silently given MuJoCo's scene.
- **The MuJoCo classes themselves are still `:planned`, and that is not a gap in
  what runs.** All 17 of `simulators/mujoco/` — `agents.py` (`Axis`, `Embodiment`,
  `Agent`, `NoopAgent`, `DistantAgent`, `SurfaceAgent`), `objects.py`
  (`ObjectMetadata`, `ObjectMetadataDecoder` and the two errors a bad YCB entry
  raises) and `simulator.py` (`MuJoCoSimulator`, `MuJoCoAgentFactory`,
  `ModelMetadata`, `UnknownObjectType` and the three configuration errors) — are
  Monty's Python, carried as it is. Porting them to Elixir would be a rewrite of a
  physics front end for no gain: the same code runs a step today, inside the
  interpreter the release already ships. The map keeps them `planned` so that
  "ported" keeps meaning "there is an Elixir module to read", and
  [`from-monty.md`](from-monty.md) records the copy the same way it records the
  config tree.
- **Done: the observation transforms**, in Elixir — `DepthTo3DLocations`,
  `MissingToMaxDepth`, `AddNoiseToRawDepthImage`, `GaussianBlurRGB`,
  `GaussianSmoothing`, `NoDepthSensorPresent` under
  [`lib/monty/frameworks/environment_utils/transforms/`](../lib/monty/frameworks/environment_utils/transforms).
  They are pure math and tested on their own; their numbers are the ones in
  [`validation.md`](validation.md)'s table where a fixture exists, and they are
  what makes a frame drawable from a replay.
- **Done: recorded transcripts**, replayed through the real runtime
  (`Monty.Simulators.Recording.SensorModule`,
  [`test/monty/recording_episode_test.exs`](../test/monty/recording_episode_test.exs)).
  A live MuJoCo test — tagged and excluded by default — is not written; it cannot
  be until MuJoCo's peer exists.
- **Done: the picture boundary.** `Monty.Simulators.Synthetic.Camera` already
  answers base64 PNGs rather than SVG, so the page that draws a run's frames did
  not have to change to hold a camera's.

The random stream is Monty's too: `Monty.Random.Numpy` is NumPy's generator and
`Monty.Random.Stream` is the one stream an episode draws from, so an episode's
first action is Monty's to the last digit ([`validation.md`](validation.md)). What
is left is
the middle of an episode: two of ten episodes of the comparison end on Monty's
step, and the rest walk a path that parts from it later on. That is a diff of two
action logs, not a design.

**Done when**: `mix monty.run base_config_10distinctobj_dist_agent` runs an
episode **against Monty's own world through the studio**, with no probe in the
loop, and its step count is Monty's for every episode of the epoch.

## Phase 3 — benchmarks and profiles

- `mix monty.bench` (exists) times the timestep loop per experiment shape.
- Accuracy harness against Monty's own benchmarks (`benchmarks/*.csv`,
  `benchmarks/results/`): the same episodes, the same seeds, one table.
- Profiling before optimisation: `:tprof` for where the time goes, `:eprof` for
  call counts, `:fprof` when order matters. Optimise the loop the profile names,
  with a bench before and after in the same commit.
- Parallelism is already legal where it is safe: vote rounds have deadlines, and
  a deadline hit is reported rather than hidden.

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
- **A chart's values axis and its hover are part of that honesty** (done
  2026-11-06): labelled lines on round numbers — 1, 2 or 5 times a power of ten,
  about four of them — so the axis says where zero is instead of leaving it
  between two labels; and a hover that reads the line _at the pointer's x_,
  interpolating between the points it was drawn through, rather than snapping to
  a subsampled one. Both are `handover.md` §13, with the measurements that found
  them.
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

No pretrained `.pt`/torch checkpoint import (graphs only, rebuild by running a
training experiment); no GPU or EXLA requirement; no distributed clustering (the
design keeps it possible). Habitat and MuJoCo are not exclusions but bridges, and
Phase 2 holds their order: Habitat's is done, MuJoCo's is next. wandb is in the
same position — `WandbWrapper` and the Python client behind it exist and are
tested offline; what a deployment adds is credentials, not code.

Two things that are not scope decisions but _later milestones_ — Monty's
parallel episodes and an episode against a live world — are worked out in
[parallel-and-live.md](parallel-and-live.md): what is free here, what is not, and
what each one is done when.

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
