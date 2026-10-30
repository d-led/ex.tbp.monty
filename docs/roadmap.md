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

## Done — v0.1, the studio

| Piece | State |
| --- | --- |
| Phoenix/OTP app, Postgres, quality gates, CI | done |
| `Monty.Cmp`, `Monty.Geometry` | done |
| `Monty.Config` — Hydra composition, resolvers, 103/103 snapshot parity | done |
| `Monty.ModuleMap` — 131 modules mapped, target resolution, verification | done |
| `Monty.Runtime` — one process per module, step barriers, vote rounds with deadlines | done |
| `Monty.Studio` — faceted index, setup + checks, builder, diagram, synthetic run, frames | done |
| `Monty.Prerequisites` — streaming downloads into Monty's paths | done |
| Run history in Postgres, delete with confirmation | done |
| Headless `mix monty.run`, `mix monty.bench` | done |

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
9. **`experiments/`** — `MontyExperiment`, `MontySupervisedObjectPretraining…`,
   `MontyObjectRecognition…`: epochs, episodes, recognition policy, hooks.

**Done when**: `base_config_10distinctobj_dist_agent` reports `ported here 12/12`
and a run of it is the ported pipeline, not stand-ins.

## Phase 2 — the environment bridge

Accuracy cannot be compared before the world is real, so this comes before
benchmarks rather than after.

- **Done, for Habitat.** `Monty.Simulators.Port` is the boundary and
  `scripts/monty_simulator_peer.py` is Monty's own `HabitatEnvironment` and eval
  interface on the far side of it, running in Monty's pinned conda environment.
  Units and quirks are preserved on the way across: metres, `wxyz` quaternions
  decoded into `Monty.Geometry.Rotation`, sensor positions relative to the agent.
  A config's own model runs against it (`scripts/probe_world_episodes.exs`), and
  what that comparison shows — objects agree, step counts do not, because of the
  random-stream deviation of §2.1 in `monty-bugs.md` — is in
  `docs/validation.md`. MuJoCo is the same shape of job and has not been done.
- Observation transforms (`DepthTo3DLocations`, `MissingToMaxDepth`, noise,
  blur) in Elixir: pure math, testable, and the reason frames can still be drawn.
- Recorded transcripts replayed in tests; a live MuJoCo test tagged
  `:simulator` and excluded by default.
- `Monty.Simulators.Synthetic.Camera` is the boundary that changes last: it
  returns PNG bytes instead of SVG, and no page changes.

**Done when**: `mix monty.run base_config_10distinctobj_dist_agent` runs an
episode **against Monty's own world through the studio**, with no probe in the
loop, and its step count is Monty's — which needs the single-stream mode that
`monty-bugs.md` §2.1 describes. The world half is done; the stream half is the
remaining obstacle, and it is the one to do next.

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

- Config editor: edit a group, see the composed diff and the snapshot check
  before saving; a config Monty would reject cannot be saved.
- Step inspector: the CMP payload a sensor sent and what a learning module did
  with it — the view a Monty developer will actually debug with.
- Run comparison: two runs of the same experiment, side by side.
- The teleop mirror (7 modules, `Teleop.*`) gets the same treatment.

## Phase 6 — upstream

- `docs/contributing-a-module.md`: port a Python file in one afternoon, with the
  naming rule, the fixture recipe and the gates it must pass.
- A draft TBP RFC describing the actor split, the vote deadline experiment, and
  what the studio is for — written for Monty's maintainers, in Monty's terms.

## Not in scope

No pretrained `.pt`/torch checkpoint import (graphs only, rebuild by running a
training experiment); no Habitat; no GPU or EXLA requirement; no distributed
clustering (the design keeps it possible); no WandB.

Two things that are not scope decisions but *later milestones* — Monty's
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
