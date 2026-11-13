# Hand-over — 2026-11-06 (evening), continued through 2026-11-13

The newest section is 41. Sections 1–15 are the evening of 2026-11-06, sections
16–40 the days after it, and each is still right where it names a file, a commit
or a measurement. Note that 35 appears twice — two days of work took the same
number. Section 41 (2026-11-13) says what is left of the split runs.

What is open, what is already known, and where the evidence is. Written for
whoever picks this up next; every claim below was measured or read, and the
file and line that settles each one is named.

State at hand-over: **`scripts/quality.sh` is green** on the tree this file is
in — lint clean, 3 088 tests (67 properties, 3 021 test cases), CRAP worst 29.85
against a threshold of 20, `mix dialyzer` 0 errors. CI's last completed run
(`9521023`) was **success**. The Windows desktop leg failed once on `720655b`
with no failing step and hung twice earlier the same day, so a lone desktop
failure is not the signal to act on (section 41.7).

Two CI jobs have their own history worth keeping: a run on `4d92066` was red in
`lint` (one unformatted test file) and `types` (a real bug dialyzer found — the
module map's "unchanged" guard compared a binary with a `File.read/1` result, so
it never fired and every `mix test` rewrote the map), both fixed by `e5ad552`.
That is why `types` is run before pushing and not left to CI.

What is left, in order:

The cluster and the division are what the newest session left open: §41.5 is the
whole list, with the one decision still unmade (how a part's steps come back
from a peer). Behind them, the older queue:

1. **Which experiments run, and what the rest need** — answered by
   `mix monty.readiness` and by the page's first facet since §18. The class that
   alone unblocks the most is `FeatureGraphLM` (10), then two capability gaps in
   classes that already exist (`DisplacementGraphLM` on PPF, `GraphLM`'s own
   matching scheme). `docs/readiness.md` has the table and the order.
2. **Training makes fewer objects than Monty does** — the chart the user
   noticed: Monty's training built three graphs, ours two, from the same six
   training episodes (section 10.4). This is the first thing to look at.
3. **`GraphLM` + `DisplacementGraphLM`** — the keystone port, 62 experiments
   (section 10.6). Must land as a pair.
4. **Two decisions still with the user** (10.7): Monty's pytest fixtures in the
   catalogue, and whether Habitat-Sim stays a permanent refusal.
5. **Performance** (7) is unchanged and still the biggest single win left.
6. The deferred review of the colocated CSS/JS/hooks, which is written down in
   the repository memory, not here.

---

## 1. CI: the macOS leg was a runner label, not an entitlement — **closed**

`os: macos-latest` instead of `macos-14` (`6bd0bfe`); run `42178863188` came back
green in every job. Nothing to carry forward.

## 2. No tagged release exists, so "latest binary" means the nightly artifact

`gh release list` is empty and `desktop release` only runs on `v*` tags, so it is
skipped on every `main` run — that is the one line to expect in a green run. The
README's three download links and `scripts/run-desktop.sh` / `run-desktop.ps1`
all go through `nightly.link/.../workflows/ci/main/<asset>.zip`, which serves
the newest `ci` artifacts from `main`; all three returned **HTTP 200** when
checked (osx-arm64, linux-x64, win-x64). Nothing is broken — but a versioned
"latest release" page does not exist. A `v*` tag is what creates it.

## 3. A crashed step left no sentence on the run — **closed, and the diagnosis was one process too far**

Symptom: the run page said _"This run did not finish. It stopped without saying
why."_ — `Failure.explain(nil)`, the record has no `reason` at all. The
statistics sat beside it: the desktop database's
`4b2d9d31-0d2d-44ce-9511-7a496fcd760c` is `failed` with `steps_done: 2383`,

## 3. A crashed step left no sentence on the run — **closed**

`Failure.explain/1` said "stopped without saying why" for a record with no
`reason`. The record now carries it. **One piece of that family is still open**
and moved to §34.5: `mix monty.run` has its own episode loop and no `catch`, so a
raise there leaves the record `running` until a page reaps it (the task does exit
1, so a script sees the failure).

_stored_ — `np.all(state[agent].rotation == self._pre_jump_state.rotation)`, exact
equality — so it compares one value with itself. An agent's rotation here is
rebuilt from the world's answer by normalising the quaternion the world reports
(`Rotation.from_quaternion/1`), so a pose put back exactly still comes back
**1.1e-16** away; `Rotation.to_quaternion/1` followed by
`Rotation.from_quaternion/1` measures that directly. The comparison is now an
angle — a thousandth of a degree counts as where it started — and the raise says
how far the agent was turned, so the next reader has the number in the sentence
instead of having to reproduce the run. It is
`docs/monty-differences.md` §2.19.

**How it was proved.** Two policy tests (a rotation that came back a last bit
away is where it started; a five-degree turn raises and says "by 5.0 degrees");
then the config itself — `mix monty.run base_10simobj_surf_agent --no-record`
**finished all 140 episodes, every one ending in `match`: 22 842 steps in 437 s
(19 ms a step), exit 0, and not one undo-jump raise** — where the old code died
at the tenth recognition. The acceptance ladder is unchanged digit for digit:
`0.746 (192, 6)` … `6.338 (1429, 2)`, `goals 15065` under `MIX_ENV=test`, and
`0.908 (802, 4)` … `11.712 (2342, 1)`, `goals 15328` in dev.

## 5. The experiment page's run list — **answered; the query was sound**

The two candidates were a name mismatch and `search/1` reading a column the light
row no longer selects. The query settles both, against the database the report
came from: the desktop SQLite file
(`~/Library/Application Support/ex-tbp-monty/ex_tbp_monty.db`) has **two** rows
for `base_10simobj_surf_agent`, and the page's own predicate finds both —
`lower(experiment) LIKE lower('%base_10simobj_surf_agent%')` matches, and
`search(state: "all", text: name)` returns them (checked). So the list was not
"finding nothing": the page whose screenshot showed "No run of this experiment
yet" was showing a database without runs of that experiment — the dev Postgres
holds only `base_config_10distinctobj_dist_agent` (two finished runs).

What _was_ wrong is smaller, and is fixed: `recent_runs/1` read twenty-five rows
to keep five and then filtered them in Elixir, so an experiment whose name is the
beginning of a busier one's could show nothing at all. It is
`RunHistory.list_for(name, limit: @runs_shown)` now — the exact name in the SQL,
five rows read.

## 6. The desktop sidecar failed every log write before succeeding — **closed**

Every line in the desktop window's console was preceded by
`Failed to write log message to stdout, trying stderr`, so the console doubled
every line and buried the real ones.

The message is OTP's own: `logger_std_h:write_to_dev/2` writes the console handler
through the `user` process, and its first clause catches and apologises before
falling back to stderr. A sidecar has no console, so it failed on every line.
`config/desktop.exs` now creates the default handler with
`config: %{type: :standard_error}`, which takes the `standard_error` clause and
cannot fail that way; the window drains both streams
(`src-tauri/src/main.rs:388-453`), so nothing leaves its console.

Proved on a throwaway database
(`SQLITE_PATH=/tmp/deskdb.sqlite MIX_ENV=desktop`): the handler reads

## 4. The raise itself: the assertion was too strict here — **closed**

`InformedPolicy.assert_undo_jump_was_successful/2` was asserting a rule
`base_10simobj_surf_agent` does not obey. Relaxed where the config allows it.

per-hypothesis `mᵀ·m` in the hot loop, on the strength of 12 976
`Geometry.transpose/1` and 5 129 `Geometry.mul/2` calls in one step. The
function has **no production caller** — `grep -rn check_orthonormal lib/` finds
its definition and nothing else, and only
`spatial_arithmetics_test.exs:192` calls it. The counts belong to the
`align_orthonormal_vectors*` family (`:218`, `:340`, `:468`), `Cmp.Message`'s
rotation (`message.ex:187`) and `EvidenceGraphLM`'s pose comparison
(`evidence_graph_lm.ex:1260`, `:1441`, `:1605`). This is the trap the memory
warns about: a call count read off a profile was attributed to a neighbouring
function in the same module, and "optimising" it would have changed nothing.
If a cheap win is wanted, measure first and name the _caller_
(`MIX_ENV=test mix run scripts/probe_step_cost.exs` for the step's cost), then
run the ladder — `mix monty.run base_config_10distinctobj_dist_agent
--episodes 1 --steps 8 --no-record` — which must stay digit for digit:
`0.746 (192, 6)` … `6.338 (1429, 2)`, `goals 15065` under `MIX_ENV=test`.

## 8. Standing rules this codebase is held to

- `scripts/quality.sh` is the gate (lint, suite with coverage, CRAP); `mix
dialyzer` is the separate types job. `scripts/reformat.sh` formats.
- Module for module: Python `a/b.py::C` is `Monty.A.B.C`; `mix
monty.module_map.verify` enforces it. Never rename a mapped module.
- Functional core, actor shell: only `Monty.Runtime.*` owns processes.

## 5. The experiment page's run list — **closed; the query was sound**

Both candidates — a name mismatch, and `search/1` reading a column the light row
no longer selects — were wrong. The query was correct; nothing to carry forward.

---

## 10. This session: the map became tooling, the table became a page, the runner learned

### 10.1 What landed, in order

| commit    | what it changes                                                                                                                                                                 |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `d8590c5` | `mix monty.run` carries the memory between episodes and walks each phase's own objects (it started every episode from the eval list and learned nothing)                        |
| `f0fbb3b` | the module map carries `stand_in:` (19 classes) and `file:` (176), `Setup`'s findings read one table instead of keeping two lists, and `mix test` refreshes the map best-effort |
| `91a3226` | `/modules` — the generated map as a filterable table                                                                                                                            |
| `9025e2f` | each row links the file _and_ the test beside it, on both sides, by scheme                                                                                                      |
| `4d92066` | the evidence chart draws the zero line (`Chart.zero`)                                                                                                                           |
| `e87eb53` | the same on the run page (`Replay.Chart.zero`)                                                                                                                                  |
| `e5ad552` | the map's "unchanged" guard actually fires; the lint formatting CI asked for                                                                                                    |

## 6. The desktop sidecar failed every log write before succeeding — **closed**

Every console line was preceded by `Failed to write log message to stdout, trying
stderr`. Fixed in the sidecar's stdout handling.

### 10.3 `/modules`: 360 classes, four columns, two filters

`ExTbpMontyWeb.ModulesLive` (route `/modules`, `Monty.ModuleMap.Table` is the
pure half): Monty class (linked at the commit the map records), Elixir module
(linked at the file the map recorded, or at the path the name promises), status,
and what stands in. Filters are URL state (`?q=…&status=…`); `q` is any words
from the row, all of which must match.

### 10.4 The finding this session ended on: our training builds **two** graphs where Monty builds **three**

The user noticed it on the charts — Monty's pyview chart shows three lines
(`new_object0..2`), ours two — and said "this experiment must have 3 objects".
The config does not:

- `conf/env_interface/test_train_2obj_predefined_eval_1obj_predefined.yaml`
  names **2 training objects** (`capsule3DSolid`, `cubeSolid`) and **1 evaluation
  object** (`capsule3DSolid`); `n_train_epochs: 3`, `n_eval_epochs: 3`, so a run
  is **6 training + 3 evaluation episodes**, which is what both runners do.
- The third line is a _graph_, not a configured object. Monty names what a
  training episode learned `"new_object" + str(len(graph_memory))`
  (`evidence_matching/learning_module.py:590`, `set_detected_object`) whenever the
  episode ends `no_match` with possible matches, or with none — so the memory
  grows by one whenever training fails to recognise what it saw.
- Monty's own rows, `~/tbp/results/monty/projects/monty_runs/test_evidence_lm_evidence_mujoco_with_liveview/train_stats.csv`
  (6 rows): results `new_object0`, `new_object0`, `new_object1`, `new_object2`,
  `new_object0`, `new_object0`, steps 21/25/22/23/25/24, evidence ≤ 5.25.
  **Three graphs.**
- Ours, six training episodes in `/tmp/port_evidence_mujoco2.log`: steps
  25/28/29/28/27/32, last belief `nothing yet`, `new_object0` ×5, evidence up to
  11.74. **Two graphs** (`new_object0`, `new_object1`).

So the open question is not the object list but **training recognition**: our
training episodes report a match against graph 0 where Monty's fail to match and
create a new graph, and our episodes run 3–8 steps longer. Two candidates, in
order of likelihood: (a) our train-mode matching concludes too readily (evidence,
`object_evidence_threshold`, or the pose-narrowing rule), and (b) our episodes
have a different ending, so the `no_match` branch that creates a graph is not
reached. Compare per episode against the CSV above — same seed (42), same config.

**Answered — it was neither (a) nor (b).** The object was never _turned_. The
sampler that gives an episode its pose (`object_init_sampler`, `Predefined` by
default with rotations `[(0, 0, 0), (45, 0, 0)]` one per epoch) was `planned`
here, so every episode of every run showed the object in the pose the scene
placed it in. A graph built from one view then explains every later episode:
matching concludes on the evidence the first episode's own nodes supply, and the
memory never needs a second graph.

The evidence for it is Monty's own stream, captured by subscribing to the
dashboard's ZMQ publisher (`evidence_chart` carries the max evidence per graph
after every step): its training evidence goes **0.4 → −0.6** in episode 3 and
**0.19 → −1.81** in episode 4, at 45°, while ours climbed to 11.7 — the two
runs were looking at different sides of the same object. After the samplers were
wired: episodes 3 and 4 drop to −0.58 and −0.53 with no possible matches, and the
run builds **three graphs**, `new_object0..2`, as Monty does.

What remains different, smaller and named rather than fixed: episode 2 takes 28
steps against Monty's 25 (8 matching steps against 5, so our pose narrows later
than his at the same evidence), and the evaluation phase takes 4/4/4 where
Monty's takes 8/4/7. Both are conclusion timing at equal evidence, not the graph
count.

### 10.5 The runner's memory rule has one home

`Run.next_memories/3` is "what the next episode starts from": a training episode
hands on the graphs it built, an evaluation one hands on what it was given. Both
`Jobs.Run` and `mix monty.run` ask it. Measured on
`test/evidence_lm/evidence_mujoco`: it used to be 3 + 3 episodes with `nothing
yet` throughout and a `no_match` summary; it is now 6 + 3 with episode 2 already
seeing `new_object0 (112 hypotheses)` and a `match` summary.

### 10.6 The plan for 100 % of the map (the user's standing priority)

The bar is **0 planned classes**; at the time of writing 360 classes were **176
implemented, 182 planned, 2 excluded** (the excluded two are Hydra's own
tooling and stay excluded). It is **187 implemented** since §17, which is
`GraphLM`, `DisplacementGraphMemory` and
`MontySupervisedObjectPretrainingExperiment` and the classes they brought with
them. `mix monty.module_map.verify` prints the numbers; `/modules` shows them
with the reason for each.

Order by experiments unblocked:

1. `GraphLM` (`frameworks/models/graph_matching.py:497-1104`) — the keystone.
   Its surface is 43 methods but only eight are arithmetic:
   `_compute_possible_matches`, `_update_possible_matches`, `_update_memory`,
   `_update_target_graph_mapping`, `_agent_moved_since_reset`, `_add_displacements`,
   `_select_features_to_use`, `_add_votes_to_buffer_stats`. The rest is
   bookkeeping `EvidenceGraphLM` already expresses here, plus the LM struct's
   fields. Collaborators to check first: `FeatureAtLocationBuffer` (may not be
   written) and `GraphGoalGenerator` (ported).
2. `DisplacementGraphLM` — 62 experiments on its own.
3. `FeatureGraphLM` — 19. 4. `MontySupervisedObjectPretrainingExperiment` — 17.
4. `TwoDSensorModule` + `DefaultAttentionSystem` — 10.
5. `MontyBase`, the no-reset model, Omniglot — 8.

**The trap that decides how to sequence it**: `class_status` marks a class
`implemented` when `Code.ensure_loaded?` says its module exists. Creating
`Monty.Frameworks.Models.GraphMatching.GraphLM` on its own therefore makes the
page offer configs whose arithmetic is half written. `GraphLM` must land
**together with its first real subclass** (`DisplacementGraphLM`) and with
Monty's own `tests/unit/frameworks/models/graph_matching_test.py` translated as
the spec. The two shell classes stay `planned` on purpose — do not "implement"
them to move the counter.

**Items 1, 2 and 3 of that list have since landed** (§17): `GraphLM`,
`DisplacementGraphLM` and `MontySupervisedObjectPretrainingExperiment`, which is
why the count moved to 187. The trap above is why they landed together, and
`Setup` now refuses a learning module it cannot build rather than standing one
in — including the case where the map says `:implemented` and no module answers.

### 10.7 Two questions still with the user

- Monty's pytest fixtures are in our catalogue and are not experiments
  (`test/hierarchy/monty/*`, `test/hierarchy/environment/*`, `test/run*`,
  `test/base_config/base*`, `test/profile/base*`): should the catalogue label
  them "a Monty test fixture, not an experiment", or keep refusing them? With
  Habitat postponed (§18) almost all of them went with it, so this is now a
  question about a handful of configs.
- ~~Is Habitat-Sim a permanent refusal?~~ **Answered 2026-11-08: Habitat is on
  its way out upstream.** A config whose world is not MuJoCo is reported as
  `not planned` — postponed, not refused — and the page has a **World** facet so
  those rows can still be read on their own. `docs/readiness.md` has the rule.

---

## 11. The port's own computational gaps, and where they are written down

Sections 1–9 are about the app, CI, one crash and performance. The **gaps in
the port itself** are a different list and are not duplicated here — they are
kept where they are checked, so they cannot drift from the code:

| What a person needs                                                            | Where it lives                                                                                                                            |
| ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| What is ported, module by module                                               | `docs/features.md`                                                                                                                        |
| Every deliberate divergence from Monty, numbered, with Monty's own line quoted | `docs/monty-differences.md` (§1.1–§1.15 are Monty behaviours we either reproduce or refuse to; §2.x the numerical and stream differences) |
| The mapping the build enforces                                                 | `lib/monty/module_map/data.ex`, checked by `mix monty.module_map.verify`                                                                  |
| Which configs cannot run here, and why                                         | `Monty.Studio.Setup` — `phase_findings/1` and `not_ported_finding/2`                                                                      |

The gaps that are genuinely open, in the order they block work:

1. **Training runs, and its numbers do not yet match Monty's.** The refusal that
   used to sit here (`:training_not_implemented`) is gone: a training phase
   carries what each episode learned into the next one, and a run writes the
   memory it built (`Memory.save/4`, `<artifacts>/<run>/memory/trained/`). What
   is open is the _science_: our training builds one graph fewer than Monty's on
   `test/evidence_lm/evidence_mujoco` (section 10.4), and nothing yet compares a
   trained memory with Monty's own. [`training.md`](training.md) §3 is where the
   persistence notes live; the comparison is section 10.4 here.
2. **Unported classes are refused, not stubbed.** `Monty.ModuleMap.StandIns`
   names the two that exist as shells (`Monty`, `MontyForGraphMatching`) and the
   MuJoCo classes the carried world implements; anything else a config names is a
   finding that says so. The table on `/modules` is the same data, generated.
3. **The motor policy disagrees with the world on a surface-agent jump** — the
   raise in section 4 (`InformedPolicy.assert_undo_jump_was_successful/2`). This
   is the one computational gap with a stack trace attached, on
   `base_10simobj_surf_agent`, after nine objects were recognised. It may be a
   real difference in how the undo is accounted for, or an assertion stricter
   than Monty's behaviour; the port's `docs/monty-differences.md` is where it
   belongs once it is understood.
4. **Config values Monty interpolates may not resolve here.** A blueprint that
   says `n_eval_epochs: ${constants.rotations_all_count}` was refused with
   `:epochs_not_a_count` — the interpolation was not applied before the value
   was validated. Check whether this is still true (`Monty.Studio.Blueprint`)
   before treating it as open; it was recorded as open point 11 and may have
   moved with the blueprint work.
5. **Votes between modules** were the cause of a `CaseClauseError` on
   `tutorial/dist_agent_5lm_2obj_eval` (open point 12). `_combine_votes` was
   ported and the ladder's eight lines did not move — verify against that
   config rather than trusting this note.

**The rule that keeps this list honest**: a computational gap must surface as a
refusal with a sentence, never as a stand-in that runs. That is what `7cba014`
established and what section 3 is trying to extend to crashes — the same
principle, applied to a process that dies instead of a class that is missing.

Where the two lists above are about _behaviour_, §12 is about the **tests**: what
referees them, how many of Monty's own cases are translated (124 of 652 on
2026-11-08), and the order in which the rest should be done.

---

## 12. The tests themselves: Monty's 652 cases, and what a translation has been paying

The question that opened this was "have we validated all individual components?".
For the _numbers_ the answer is mostly yes: sixteen Monty recordings referee
feature evidence, the slope tracker, the recognition policy, the motor policy,
positioning, salience, vocus2 and a whole pretrained episode. For the _code_ the
answer is no, and it is measurable in one line:

    grep -rh "def test_" $(find tests/unit -name "*_test.py") | sed 's/.*def \(test_[a-z0-9_]*\).*/\1/' | sort -u

says Monty's `tests/unit` holds **652 distinct case names**, and of those, **22**
are named anywhere in our `test/` — all of them translated on 2026-11-06, all in
`burst_sampling_test.py`. Our 187 tests in `test/monty/frameworks/models/
evidence_matching/` are hand-written behaviours and parity fixtures; they are
worth keeping, but they are not translations and were never proof of parity.

### 12.1 The rule, now in `AGENTS.md`

> **Tests are translations.** A ported module's tests come from Monty's own
> `tests/unit/**/test_*.py`, one case for one case, each naming the case it
> translates. Where Monty's case drives a private method, drive the nearest
> public entry point and say so in the comment. A hand-written behaviour test
> states intent; it is not evidence of parity, and it must not be counted as
> such. A case that cannot be translated is listed, never dropped silently.

### 12.2 What the first eleven bought: two defects and one of my own

1. `BurstSamplingHypothesesUpdater.new/2` accepted a **negative
   `sampling_multiplier`**, which asks a burst for a negative number of
   hypotheses. Monty's constructor raises `ValueError("sampling_multiplier
should be >= 0")`; ours now raises the same sentence (`c88cca6`).
2. `max_global_slope/1` answered **`0.0`** where Monty answers **`-inf`** when
   nothing is measurable. With the default trigger slope of 1.0 the two agree by
   accident; with any negative `burst_trigger_slope` the first step opens a burst
   in Monty and not here. A BEAM float cannot hold `-inf`, so `nil` now carries
   that state and `begin_step/1` counts it as stalled.
3. And the regression that (2) caused, which is the useful part: the first
   version moved the `sampling_burst_steps == 0` guard _inside_ the comparison,
   so a burst that was already running restarted itself on any step where
   nothing was measurable yet — every burst stretched, more hypotheses sampled
   than Monty: `step 39: banana has 1735, Monty 1437` in
   `test/monty/pretrained_replay_test.exs`. Monty keeps the guard outside the
   comparison. Four of Monty's own cases (`test_burst_does_not_trigger_when_
already_in_burst`, `..._max_slope_above_threshold`, `test_sampling_burst_
steps_decrements_in_exit`, `..._does_not_go_negative`) now pin what the
   referee caught.

The referee already in the tree found that in one run. That is the argument for
translating the rest: the fixtures catch differences in _outcome_, and Monty's
cases catch differences in _rule_, which is where a bug survives the outcome for
a while.

### 12.3 How to translate one, in order

1. Read Monty's case and write down the rule it pins in one sentence.
2. Find our public entry point for the same rule (`update_evidence/5`,
   `begin_step/1`, `end_step/1`, `sample_count/5`…). Our helpers are `defp`;
   drive the entry point and say in the comment that Monty drove a private
   method.
3. Port the fixture **honestly**: Monty's `Mock()` tracker becomes a real
   `EvidenceSlopeTracker` whose slopes the test then asserts on, so the fixture
   proves its own premise before the assertion it was built for.
4. Assert the same outcome Monty asserts, with our vocabulary.
5. Name Monty's case in a comment, so the count is greppable.

Traps hit while doing this (all now in `test/monty/frameworks/models/
evidence_matching/burst_sampling/burst_sampling_hypotheses_updater_test.exs`):

- Monty writes initial poses as **Euler degrees**; ours wants a 3×3 matrix, and
  inverted: `Rotation.from_euler_degrees/1 |> Rotation.invert() |> Rotation.to_matrix()`.
- `Hypotheses.pose_bytes/1` wants a **3×3 nested matrix**, not a flat nine-list.
- A fixture memory must store **`pose_fully_defined`** and list it in
  `features_to_use`, or `HypothesesDisplacer.node_poses/4` raises `KeyError`.
  Monty's trained graphs always carry it.

### 12.4 What is left, in the order it should be done

| Area (Monty's cases)                                    | Translated | Left |
| ------------------------------------------------------- | ---------: | ---: |
| `evidence_matching/burst_sampling_test.py` (24)         |         22 |    2 |
| `evidence_matching/evidence_lm_test.py` (16)            |          0 |   16 |
| `evidence_matching/evidence_slope_tracker_test.py` (11) |          0 |   11 |
| `evidence_matching/hypotheses_displacer_test.py` (3)    |          0 |    3 |
| `evidence_matching/graph_memory_test.py` (2)            |          0 |    2 |
| the rest of `tests/unit`                                |          0 | ~590 |

The last row is what the other areas hold: frameworks 530 cases (models 245,
actions 129, utils 106, ...), simulators 100, attention 45, experiments 53,
sensor modules 11, environment utilities 17, environments 6, telemetry 8.

Burst sampling first, because the measured remaining difference lives there: in
`test/evidence_lm/evidence_mujoco` our best hypothesis climbs monotonically
(`1.0 → 3.0 → 4.481 → 6.481 → 7.981 → 9.981`) where Monty's highest drops out of
the graph every other step (`0.964 → 2.320 → 1.320 → 0.320 → 2.300`). Which
hypotheses get proposed is what a burst decides, so the two cases left there
are the ones that can turn that divergence into a failing test.

Then `evidence_lm_test.py`, which is where a hypothesis is displaced, scored and
dropped — and where our trained graph's node counts (38/9/13 against Monty's
45/16/10) are decided.

**Two of the twenty-four cannot be translated as this port is written**, and they
are named rather than dropped:

- `test_sample_new_hypotheses_without_feature_matching` and
  `..._with_feature_matching` — they swap Monty's `feature_evidence_calculator`,
  `get_feature_array` and `get_feature_order` for mocks behind a
  `features_for_matching_selector`. That seam does not exist here: this port
  **always** starts a newly sampled hypothesis with the node's own feature
  evidence. Monty's default selector turns that off for a channel with no
  feature weights, and whenever `feature_evidence_increment <= 0`
  (`features_for_matching/selector.py`), so a config that disables feature
  evidence would start its hypotheses at zero in Monty and at a score here. That
  is the next thing to port in this file, and the reason those two cases are
  listed rather than translated.
- `test_init_fails_when_passed_invalid_evidence_threshold_config` **is**
  translated, but not where Monty asserts it: Monty validates in the updater's
  constructor and this port parses the setting once when the module is built, so
  the case lives in `evidence_graph_lm_config_test.exs` against
  `parse_config/2`.

**One rule for the work itself**: run
`mix test test/monty/pretrained_replay_test.exs` on every change to sampling
before believing any result. It is the only referee in the tree that measures
what a burst does to a real episode, and it is fast.

---

## 13. The replay chart: three things it was doing that the data did not say

Reported as "hover jumps between points instead of being true to sampling the
graph where the mouse is", "the 0 is not on the y axis" and "normalize the
ticks, adaptive but not arbitrary". All three were real, and the DOM said so:
the value axis read `-6.4, -1.4, 3.7, 8.7`.

1. **The ticks were the range cut into quarters.** `Replay.Chart.ticks/2` walked
   `min + (max - min) * i / 3`, so no label was a number anyone compares in their
   head, and zero — the line every episode starts on — fell _between_ two of them
   and was never named. They are now the multiples of one, two or five times a
   power of ten inside the range, with the step chosen so the axis carries about
   four: `0.0 … 12` is labelled `0, 5, 10`, and `-6.4 … 8.7` is labelled
   `-5, 0, 5`. The decimals follow the step, so two labels can never read alike.
2. **The hover snapped to a subsampled point.** Only 160 points per line were
   sent to the browser (`@samples_per_line`), and the hook picked the nearest of
   them, so a 162-step run jumped between every second step. Every drawn point is
   sent now, and the hook reads the value _at the pointer's own x_: straight
   between the two points that bracket it, and the nearer of the two when they
   are not consecutive steps — an object that was not reported has no line there
   to read, and a pointer past the end of a line is not over it.
3. **The sentence was written twice.** The server composed `object · #step ·
value unit` for each sample, and the hook interpolates a position the server
   never had, so the sample now carries the parts (`line`, `step`, `value`,
   `unit`, `named`) and the hook writes the one sentence. `label/5` and
   `unit_note/1` are gone, and the page's tests assert the parts.

Two more came out of walking the pointer across the axis a percent at a time,
which a screenshot cannot show:

4. **The overlay kept a stale reading over blank stretches.** Before the first
   recorded belief — thirteen percent of this run's axis — no line exists, and
   the crosshair stayed where the pointer had last found one, naming a step the
   pointer was nowhere near. `hover` now hides when there is no reading.
5. **The tooltip was pinned to a plot edge**, while the place it named sat
   mid-height. It now sits just above its own point (below it when there is no
   room above) and stays inside the box.

Proved in the browser, not just in ExUnit: at a drawn vertex the readout reads
exactly the stored sample (`#48 · 8.69`), half a step later `#48.5 · 4.54`; over
one-percent steps across the whole axis the crosshair's left edge equals the
pointer's position at all 86 positions that have a line (drift ≤ 0.8 %), the step
advances 1.6–1.7 per percent with no discontinuity, and nothing is shown at
1–13 % or past the final step.

---

## 14. Open: `image amd64, scan, non-root` is red, and it is not a code failure

The run for `9f476f5` failed on one job of fourteen. Every other job was green:
lint, types, the four test partitions, coverage/CRAP/parity, both desktop
bundles, `image arm64`.

The failing step is **`Scan the image`** (`aquasecurity/trivy-action@v0.36.0`,
`exit-code: "1"`, `severity: CRITICAL,HIGH`, `ignore-unfixed: true`,
`.trivyignore.yaml` for read exceptions). `Build linux/amd64` succeeded and the
two steps after the scan — `Run as an unprivileged user` and `Runs with no
database server at all` — were skipped, so what failed is the gate rather than
the image being unbuildable.

What that means: the amd64 image now carries a **fixable** CRITICAL or HIGH
finding — the packages come from the base image, so this is an upstream update
that arrived between runs, not something a commit in this branch introduced.

To pick up:

1. Read the findings (`gh run view --job <id> --log` once the run completes; the
   log is not downloadable while the run is in progress).
2. Bump the base image in `Dockerfile` so the package is fixed upstream.
3. If the finding cannot be fixed yet, add an entry to `.trivyignore.yaml` with
   the reason and the date the exception expires — never a blanket suppression,
   which is what that file's own comment says.

Until this is done, a cancelled or failing amd64 leg is **not** a green one, and
the arm64 image (which built and passed) is not evidence about it.

---

## 15. For whoever picks this up: the state, and the order

**State at `2116249`.** Gate green — `./scripts/quality.sh` (2355 tests, 19
properties, lint, coverage/CRAP/parity) and `MIX_ENV=test mix dialyzer` at 0
errors. CI is green in every job **except** `image amd64, scan, non-root`, which
is section 14: a fixable CRITICAL/HIGH finding in the amd64 base image, not a
code failure. The macOS leg is cancelled before it starts (section 1, runner
label). Neither is a green leg, and neither is caused by anything in this
branch.

### 15.1 What landed, and what each one is worth

| Commit               | What it does                                                                     | How it is known                                      |
| -------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------- |
| `4ba5875`            | a step reads the module's own conclusion instead of a cache                      | the 2-vs-3 graph difference disappeared              |
| `334a92c`, `93792f7` | `object_init_sampler` ported and wired (pose per episode)                        | epoch 1 turns the object 45°, as Monty does          |
| `c88cca6`            | negative `sampling_multiplier` refused; 3 translated cases                       | the refusal case failed before the guard             |
| `9f476f5`            | `max_global_slope` says "nothing measured" rather than `0.0`; 8 cases            | the replay referee caught the regression this caused |
| `9acbab4`            | replay chart: round ticks that name zero, hover reads the line under the pointer | measured in the browser, section 13                  |
| `17387b9`            | the readout hides where nothing was recorded, and sits on its own point          | one-percent pointer walk across the axis             |
| `01bb813`            | 22 of Monty's 24 burst cases; the two that cannot be, named                      | the replay referee still green                       |
| `df0cce9`, `2116249` | the red scan job and the pointer-walk faults written down                        | —                                                    |

### 15.2 The rule that decides what "done" means here

A ported class's tests come from Monty's own `tests/unit/**/test_*.py`, one case
for one case, each naming the case it translates. A hand-written behaviour test
is intent, not parity, and must not be counted as evidence. `AGENTS.md` has it
beside "Module for module"; section 12 has the method and the traps.

Re-measure the whole tree in one command (from `monty-orig`):

    for n in $(grep -rh "def test_" $(find tests/unit -name "*_test.py") |
               sed 's/.*def \(test_[a-z0-9_]*\).*/\1/' | sort -u); do
      grep -rq "$n" ../ex.tbp.monty/test/ && echo "$n"
    done | wc -l

It said **11** at the start of that session and **22** at the end: every one of
them a case in `burst_sampling_test.py`, which is now 22 of its 24. Run again on
2026-11-08 it says **124** — the attention package, edge detection, salience and
twelve of `evidence_lm_test.py`'s sixteen (§28) have since cited the case they
translate. The rest of `tests/unit` — 528 case names — has no counterpart yet.

### 15.3 The order, and why each step is next

1. **Wire `features_for_matching_selector` into the burst sampler.**
   Monty's selector turns feature evidence off for a channel with no feature
   weights and whenever `feature_evidence_increment <= 0`; this port always
   pre-scores a newly sampled hypothesis. Two of the four untranslated burst
   cases are exactly this switch, so the port and the case land together.
2. **Translate `tests/unit/frameworks/models/evidence_matching/evidence_lm_test.py`
   (16 cases).** This is where a hypothesis is displaced, scored and dropped —
   and where the one measured difference lives: our trained graph keeps 38/9/13
   nodes where Monty's keeps 45/16/10, and our best hypothesis climbs
   monotonically (`1.0 → 3.0 → 4.481 → 6.481 → 7.981 → 9.981`) where Monty's
   highest leaves the graph every other step (`0.964 → 2.320 → 1.320 → 0.320 →
2.300`). Do not hunt that by hand before the file is translated: each
   translation is a candidate explanation, and a red one is the answer.
3. **Then the rest of that directory** — `evidence_slope_tracker_test.py` (11),
   `hypotheses_displacer_test.py` (3), `graph_memory_test.py` (2) — and only
   then the wider tree (`frameworks` 530, `simulators` 100, `actions` 129,
   `utils` 106, `attention` 45, `experiments` 53, the rest smaller).
4. **A trained memory against Monty's own `model.pt`** is still uncompared
   (section 11, open point 1). That is the check the node counts above need.
5. **The amd64 scan** (section 14): bump the base image, or record an exception
   with a reason and an expiry in `.trivyignore.yaml`.

### 15.4 What not to trust

- **A hand-written test as parity.** It says what someone intended, not what
  Monty does. A hundred and twenty-four cases are translated; the rest of our
  suite is not.
- **A cancelled or failed leg as green.** The macOS job never starts; the amd64
  image's scan currently fails. Say which leg you mean.
- **A pending run as proof of an intermediate commit.** `main`'s concurrency
  group is `cancel-in-progress: false`, but GitHub still replaces an older
  _pending_ run with a newer one, so on this branch five pushes in an hour can
  leave three runs cancelled. Only the run for the head commit proves anything;
  check `gh run list --limit 1` after the last push of a session, not the runs
  for the commits in between.
- **The arm64 image as evidence about amd64**, or the other way round.
- **`mix lint 2>&1 | tail`** — it hides the exit code, and a "clean" tail after a
  failure reads exactly like a pass.
- **A local full-suite run on a loaded machine.** The heavy cases
  (`recording_episode_test.exs`, the MuJoCo `host_test.exs`) time out at a load
  average near 90; run them alone or believe CI.

## 14. `image amd64, scan, non-root` — **closed**

It was a fixable CRITICAL/HIGH finding in the amd64 base image, not a code
failure: `Build linux/amd64` succeeded and the scan gate failed. The base image
moved and the leg is green (`image amd64, scan, non-root  success`, run
`42628601534`). The rule for a future red scan still applies: bump the base image
or add a dated entry to `.trivyignore.yaml` — never a blanket suppression.

| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `de96fe7` | a run's steps stream from memory through `Monty.Studio.RunStream`; the row is written at every episode boundary and once when the run settles | the row was being rewritten whole per step: 13 MB/step at the tail of an 887-step run, its last hundred steps at 5 s each against 157 ms for its first |
| `de96fe7` | a run ended out of band keeps its steps: whoever closes it writes what memory holds | the ended run had recorded `0 steps` while its page drew 55 |
| `de96fe7` | the chart's value axis always spans zero; the axis column's height is rendered with a unit | in the browser: labels `0, 20, 40`, and the column is 150 px instead of none — the unit-less `height: 150` was why labels piled on one spot |
| `5682859` | the write path asks whether the run exists instead of reading `update_all`'s answer | dialyzer 0 errors and the 94 tests green together |
| `4c5e22c` | the chart's view (series, window, step) belongs to the run it was chosen for | a series picked for one run no longer follows the reader to the next; a test patches between runs to prove it |
| `4cd0a5b`, `8d49404`, `1079af6`, `3c43031`, `ff42f52` | `docs/speed.md` carries today's numbers; two instruments added | below |

### 16.2 The speed numbers, and the four things they ruled out

A step is **7.1 M reductions and 188 MB of garbage**, split learning module 51 %,
caller 26 %, sensor modules 19 % (`scripts/probe_step_cost.exs`, ten objects, six
steps). `docs/speed.md` has the tables; these are the conclusions:

1. **A mutable-state NIF for a module's hypothesis space — measured, rejected.**
   The state is 55.5 MB and `Model.state/1` costs 176 ms, but it is called
   **once per episode** (`Logging.report/3`). Per-step replies are `:ok`, which
   is why `Model.status/1` is 2 µs.
2. **Flat binaries for the camera arrays — measured, rejected.** One step's
   observations cost **1 582–1 748 µs to copy as lists and 1 µs as binaries**
   (`scripts/probe_copy_cost.exs`), but a step is ~275 ms, so the whole payload
   copy is under 1 %. The 71.5 % of _words_ under `gen_server:loop/5` in tprof's
   table is allocation inside the frame, **not** the size of the messages.
3. **Batching `Geometry.dot` — rejected.** It is **6 reductions a call**
   (`scripts/probe_hypothesis_cost.exs`); `dot` and `transpose` together are 2 %
   of a step.
4. **Deleting `sensor_frame_data` — refused.** Nothing in this port reads it,
   but Monty's `DepthTo3DLocations` produces it and

## 15. The state and the order — **superseded by §34**

The "state at `2116249`" paragraphs here are three days old, and the open list
they end with was worked through in §§16–33. **§34 is the current state and the
current order.** What survives from this section is the acceptance rule, now in
§8 and in `AGENTS.md`: a ported class's tests come from Monty's own
`tests/unit/**/test_*.py`, one case for one case.

positioning and action stream, and it is the next thing to look at if a graph
ever grows a different shape.

The first comparison ever made between a trained memory here and Monty's own
`model.pt` is therefore this one, and it is the check §11 open point 1 asked for
on the one experiment where it is cheap: `/tmp/monty_first_exp/first_experiment/
pretrained/model.pt` against `Run.next_memories/3` of the same run.

### 17.3 What this opens, and what it closes

Closed:

- **`DisplacementGraphLM` is runnable.** It answers the whole behaviour, so the
  coordinator can step it; the module map's `:implemented` is now true of it.
- **The tutorial experiment runs end to end** — `mix monty.run
tutorial/first_experiment` — and the studio page offers it.
- **`Setup` no longer stands anything in for a learning module.** A class it
  cannot build is a finding with a sentence, and an `:implemented` class with no
  module is refused as the port defect it is.

Opened, in the order it blocks work:

1. **`GraphLM`'s own tests are two of its four Monty cases.** Our
   `graph_lm_test.exs` translates all four of
   `tests/unit/frameworks/models/graph_matching_test.py`
   (`propose_goals` ×2, `propose_region` ×2). `displacement_matching.py` has no
   unit test upstream; `graph_building_test.py` needs Habitat-Sim and is skipped
   without it, which is why §2.20's behaviour is stated as hand-written intent
   rather than as a translation.
2. **The tutorial's evaluation phase has never run.** `do_eval: false` and
   `n_eval_epochs: 3` in the config mean Monty's `evaluate/1` warns and does
   nothing, and the phase plan here does the same. A pretraining run that wants
   to _check_ the graph it built is a different experiment (Section 10.6's
   `MontySupervisedObjectPretrainingExperiment` — 11 configs — is the training
   half only).
3. **The memory is written but never read back into a module here.** The run
   writes `memory/trained/<name>.jsonl.gz`; `Setup.memories/1` loads a memory
   named by the config. Nothing yet points a config at the memory the previous
   run trained, so "train, then evaluate" is two runs and a path.

### 17.4 The gate, watched

`scripts/quality.sh` green (2 453 tests, 19 properties, worst complexity 29.85)
and `MIX_ENV=test mix dialyzer` at 0 errors at every commit of this section.

CI is **green in every job** on `2bc3ef5` (`42412540254` excepted only in
`desktop release`, which is skipped without a `v*` tag — §2): `lint`, `types`,
the four test shards, `coverage, CRAP and parity`, both images, the image index
and all three desktop bundles. That includes **`image amd64, scan, non-root`,
green for the first time since §14**: the base image's finding was fixed
upstream, so §14 needs no exception in `.trivyignore.yaml`.

Two runs went red on the way, both for one reason worth keeping: the supervised
tests were written against MuJoCo, and `priv/monty_py` loads a YCB mesh CI does
not have (`UnknownObjectType: mug`). They now skip unless the prerequisite is
present — the convention `host_test.exs` already used — and run on a machine
that has it. A test that needs data the suite does not carry is a test that has
to say so.

---

## 18. 2026-11-08: every experiment asked what it needs, and the page says it

The question this answers is _"which experiments still need module translation to
be able to run?"_ — which used to be answerable only by reading a refusal on each
page, one experiment at a time, and then counting by hand.

### 18.1 What landed

| commit | what it does                                                                                                           | how it is known                                                                                                    |
| ------ | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| this   | `Monty.Studio.Readiness` — one experiment's answer, the counts, and the classes ranked by what they alone unblock      | pure where it can be: `classify/1` and `summarise/1` are tested on a fixture; `catalog/1` is the edge              |
| this   | `mix monty.readiness [--world] [--all] [--json]`                                                                       | 210 experiments in ~2 s, or 0.06 s from the cache                                                                  |
| this   | `/experiments` grows a **Runs here?** facet, so the page opens on the answer                                           | the pill counts respect the other facets, like every other one                                                     |
| this   | a second facet, **World** (`Setup.engine/1`), and a third answer, `not planned`, for a world this build does not carry | `?world=habitat` and `?ready=not_planned` narrow to the same rows; the postponed count is 87 under every `--world` |
| this   | `Setup.modules/1` and `Setup.blocking/1` — the classification `module_findings/1` used to keep private                 | one home: the refusal text and the survey count the same list                                                      |
| this   | **a bug the facet surfaced**: the list rendered a page of unfiltered rows under every filtered link                    | 30 stale rows under `?agent=surf`; now exactly the filtered ones                                                   |

That last one is worth its own line: `mount/3` streamed the first page and
`handle_params/3` then streamed the filtered rows with `reset: true`. In a
browser the reset replaces the children, but the first paint already carried the
wrong list, and in the test the merged DOM kept both. Rows are streamed in
`handle_params/3` alone now, which is where the filters arrive.

### 18.2 The numbers (MuJoCo, the default world)

210 experiments: **87 run here, 36 refused, 87 postponed, 0 do not compose**. In
the stand-in scene it is 73 / 50 / 87 / 0 — a sphere refuses more, because a
supervised experiment cannot state an object it never showed.

**Habitat is postponed, not refused** (your call, 2026-11-08: it is on its way out
upstream). This build carries one world — MuJoCo — so a config that names any
other is `not planned`, and §10.7's first open question is answered by that. The
postponed set is 87 in every deployment, because it is a fact about the config;
`--world` still decides the rest.

`docs/readiness.md` has the full table. The rows that matter:

- **30 of the 36 are refused for a class nothing stands in for**, and the ranking
  by what each one alone unblocks is `FeatureGraphLM` 10, `MontyBase` 3,
  `DisplacementGraphLM` 2, `GraphLM` 1, `TwoDSensorModule` 1 (17 naming),
  `DefaultAttentionSystem` 0 (9). The Saccade and Omniglot families left the
  ranking entirely: every config naming them is a Habitat config.
- **18 wait on a missing pretrained library**, which is `/prerequisites`'s job
  and not a port at all; 16 of those are the cows family, which also wants
  `TwoDSensorModule`.
- **1 is `${constants.rotations_all_count}`** among the refused — §11's open
  point 4, still true, but almost every config it bites is a Habitat fixture.

### 18.3 The order this suggests, and why it changed

The old order was `GraphLM` → `DisplacementGraphLM` → `FeatureGraphLM` → …,
written when both of the first two were missing. Both are written now (§17), so
what is left of them is a **capability inside a class that exists**:

1. `DisplacementGraphLM` refuses `match_attribute: PPF` in its own words —
   "matching on PPF is not ported, only displacement is". Two experiments, and it
   is a branch to translate, not a module.
2. `FeatureGraphLM` — ten experiments, the largest single win.
3. The cows family — 17 configs wanting `TwoDSensorModule`, 9 of them
   `DefaultAttentionSystem`, 16 a pretrained cows library. One family, three
   things, and the only group that is neither Habitat nor a fixture.
4. `MontyBase` last, because all three of its experiments are Monty's own pytest
   fixtures and §10.7 has not decided what those are.

### 18.4 What not to trust

- **A count of unported classes as a count of blocked experiments.** One class
  can block twenty-one experiments (`FeatureGraphLM`) or none
  (`SaccadeOnImageInterface` is always accompanied by something else).
- **`blocked_by` as "classes to write".** It now also names a written class that
  refuses a config — `GraphLM` today, and `DisplacementGraphLM` until §19 landed
  it — because that is the work too, and the mix task's
  `learning_module_not_buildable` row is where those show.
- **The stand-in world's number as the MuJoCo one.** Different refusals, both
  true, `--world` decides which you are reading.

### 18.5 The gate, watched

`scripts/quality.sh` green (2 471 tests, 19 properties, worst complexity 29.85)
and `MIX_ENV=test mix dialyzer` at 0 errors. CI run `42424897200` on `1917d13`
is **green in every job** — `lint`, `types`, all four test shards, `coverage,
CRAP and parity`, both images including `image amd64, scan, non-root`, the image
index and all three desktop bundles. `desktop release` is the one skipped job,
because there is no `v*` tag (§2).

The acceptance ladder was re-run after `Setup`'s classification became public
and is unchanged digit for digit: `0.908 (802, 4)` … `11.712 (2342, 1)`,
`goals 15328`.

### 14.1 It came back, and the fix is one package (2026-11-08)

The same job failed again on `a2a52a1`, one run after it was green: `zlib1g`,
CVE-2026-76844 and CVE-2026-85091, HIGH, **fixed** in
`1:1.3.dfsg+really1.3.1-1+deb13u1` while the base image pins `+b1`. Nothing in
the tree changed between the two runs — this is what §14 describes, an upstream
fix appearing in the base image's repository.

The runtime stage already names `apt` for the same reason (CVE-2026-109518), so
`zlib1g` is named beside it. Verified in the base image itself rather than by a
full build: `docker run --platform linux/amd64 debian:trixie-20261020-slim` →
`dpkg-query -W zlib1g` after the install says `+deb13u1`. No `.trivyignore.yaml`
entry: the finding is fixable, and the rule there is that exceptions are for what
cannot be.

## 19. 2026-11-08: `match_attribute: PPF`, and what the run against Monty did and did not prove

The readiness order's first item is done: `DisplacementGraphLM` matches on point
pair features, so `test/graph_learning/ppf_pred_mujoco`,
`test/graph_learning/fixed_actions_ppf_mujoco` (both refused before) and
`test/graph_building/load_mujoco_for_ppf` run. The class is no longer ranked in
`docs/readiness.md`; the counts there are 89 / 34 / 87.

### 19.1 What the attribute is

A point-pair feature is four numbers for the step between two sensed locations:
the length, and three angles — the first location's normal against the step, the
second's against the step, and the two normals against each other. It replaces
the three-number displacement, and what it buys is that a _direction_ stops
mattering: a step has no sign, because `[|d|, angles]` is the same for `A→B` and
`B→A`. That is exactly what the port shows in
`displacement_graph_lm_test.exs` — every decimetre edge is kept, in both
directions, where a displacement keeps the two it was learned with.

The four numbers are `torch_geometric.nn.conv.PointPairFeatures(cat=False)`,
which is what Monty's `add_ppf_to_graph` calls:
`[|d|, angle(n_i,d), angle(n_j,d), angle(n_i,n_j)]` with `d = pos_j − pos_i` and
`angle(u,v) = atan2(‖u×v‖, u·v)`.

### 19.2 Where it had to travel

Four places, and three of them are places a reader would not look for a
matching change:

- **The object model.** `GraphObjectModel` gains `has_ppf`, set from
  `object_model_options: [has_ppf: match_attribute == "PPF"]`, and every build
  and update ends in `with_ppf/1` — the same place Monty calls
  `add_ppf_to_graph`. `set_graph/2` does it too, because that is where a loaded
  memory re-derives what it needs; Monty's `load_state_dict` behaviour is the
  same idea.
- **A memory that was learned without it.** `DisplacementGraphMemory.with_ppf/2`
  walks the channels and adds the features to a graph that lacks them, so a PPF
  module given a displacement-trained memory does not silently match on three
  numbers where it meant four.
- **The query.** `DisplacementGraphLM.query/1` reads the buffer's
  `current_ppf`, and the buffer's `first_displacement_len/1` reads
  `ppf[1][0]` — index 1, not 0, because the first step has no move to measure and
  Monty stores a zero row for it.
- **The relative length.** With `use_relative_len`, Monty divides the query's
  first component by the buffer's first step, and divides an edge's first
  component by **the length of the first edge of the path being tested** — not by
  the edge's own length. The path's scale factor is `scale_factors[graph_id][path_id]`
  and this port already carried it for displacements; the only new thing is that
  the first component of a PPF row is where the length lives.

### 19.3 The run, and why it is not parity evidence

Same config on both sides (`test/graph_learning/ppf_pred_mujoco`, seed 42, 3
train + 3 eval epochs), Monty's own checkout at `760ad174`:

|                    | Monty                                         | this port            |
| ------------------ | --------------------------------------------- | -------------------- |
| train              | 6 episodes, 21–24 steps, 5 graphs             | 6 episodes, 6 graphs |
| eval, rotation 0°  | `no_match`, ruled out at step 1               | `no_match`           |
| eval, rotation 45° | `correct`, 1 possible match, path `[0 6 4 1]` | `no_match`           |
| eval, rotation 0°  | `no_match`, ruled out at step 1               | `no_match`           |

Two of three eval verdicts agree, and the third does not — but this experiment
cannot settle a port's parity either way, and the reason is worth writing down
before anyone reads the table as a score:

- **The sensor data is not the same data.** Our MuJoCo world is
  `priv/monty_py/world.py`, not Monty's camera and depth pipeline. The steps'
  lengths and normals are close and not identical, and this config compares them
  at `tolerance: 0.001` on all four numbers — so an episode's verdict can flip on
  a millimetre. Monty's own three eval epochs disagree with each other for the
  same reason: two different rotations of the same object, one match, two
  refusals.
- **The training divergence is the same kind.** Monty ends training with five
  graphs and we end with six, because Monty matched its second training episode
  into the first one's graph and we did not. At a tenth-of-a-radian tolerance
  with a relative length, whether a cube's steps look like a capsule's is a
  property of the world, not of the comparison.
- **So the evidence for the port is the fixture, not the episode.** The four
  numbers are checked against PyG's definition with hand-computable angles
  (`graph_object_model_test.exs`), and the matching is checked against Monty's
  own rules read from `displacement_matching.py` — the ratio comparison, the
  tolerance, the both-directions consequence
  (`displacement_graph_lm_test.exs`). Monty has **no unit test** for
  `displacement_matching.py` at all, which is why these are hand-written intent
  rather than translations, and why the tests say so in their moduledoc.

What a cleaner referee would need: Monty's own percepts for one episode, replayed
through this port. Monty's recordings do not carry them (§13's lesson again), so
that is a data-export job rather than a test — worth doing before the next
learning module, because `FeatureGraphLM` has the same problem.

### 19.4 The gate, and the one test that had to change

`scripts/quality.sh` green (2 491 of 2 492 tests — the one failure was
`ReadinessTest`'s "a learning module that refuses the config", which used
`test/graph_learning/ppf_pred` because that config matched on PPF upstream and on
displacement here; the verdict changed the moment PPF landed). The case now uses
`tutorial/surf_agent_2obj_train`, which names the base `GraphLM` itself — a class
this port writes and which refuses to match, as Monty's does. Its assertion on the
code list became a membership test, because that config also earns
`no_target_to_supervise` and which other codes it earns is not what the case is
about.

The acceptance ladder is unchanged digit for digit: `0.908 (802, 4)` …
`11.712 (2342, 1)`, `goals 15328`.

## 20. 2026-11-08: `FeatureGraphLM`, the readiness order's largest single item

Ten experiments turned on at once: `test/graph_learning/feature_pred_mujoco`
and its `off_object`, `off_object_train`, `time_out` and
`feature_uniform_initial_poses` siblings, `five_lm_feature_mujoco`,
`fixed_actions_feat_mujoco`, and three `test/graph_building/*` configs. The
counts in `docs/readiness.md` go 89 → 99 runnable, 34 → 24 refused.

### 20.1 What the class is

Twelve hundred lines of Elixir behind two questions per graph per step:

- **Which nodes could I be standing on?** Every node whose stored features lie
  within the observed value's tolerance, ignoring where those nodes are. This is
  `FeatureGraphMemory.match_all_node_features/5`, and it is the only place a
  whole graph is compared against one observation.
- **Does the move agree with a pose I could be in?** For every path still
  possible and every rotation still possible on it, turn the observed step by
  that rotation, land on a place, and keep the path if the nearest node within
  `max_match_distance` carries the pose the rotation predicted.

Recognition is one object left whose path is unique _and_ whose rotation is
unique — or, for an object that looks the same from several sides, the same set
of poses lasting `required_symmetry_evidence` steps. That second condition is
`_check_for_symmetry`, and it is why the module has a counter instead of a
comparison: an apple is not one pose, and refusing to conclude would be wrong.

### 20.2 The three places the port had to decide

- **`possible_poses` is parallel to `possible_paths`**, one list of rotations per
  path, and it lives in the outer struct while the paths stay in the graph
  module's `possible_paths`, because the paths are what `GraphLM`'s conclusion
  reads. Monty gets both for free by overriding an attribute; a port that
  composes has to say which struct owns what.
- **The comparison takes its tolerances from the module, not from the memory.**
  Monty's memory holds `features_to_use` _and_ the tolerance numbers, because the
  module assigns its tolerances to it. This port's `GraphMemory.features_to_use`
  is a map of feature **names** — what the evidence kernel reads — so
  `match_all_node_features` is handed the tolerances explicitly, and the memory
  keeps the names it builds rows for. Two shapes, one source of truth.
- **A node is its own nearest neighbour on a zero-length step.** A symmetric
  object is recognised by staying still, which is what the symmetry test in
  `feature_graph_lm_test.exs` does: two identical observations, then a match.

### 20.3 The run, and what it did and did not prove

Same config both sides (`test/graph_learning/feature_pred_mujoco`, seed 42, 3
train + 3 eval epochs):

|          | Monty                                                                     | this port                                                |
| -------- | ------------------------------------------------------------------------- | -------------------------------------------------------- |
| train    | 4 `no_match` building graphs 0–3, then `new_object0`, `new_object1`       | the same, in the same order                              |
| eval 1–3 | correct (`new_object0`), correct (`new_object2`), correct (`new_object0`) | match (`new_object0`), `no_match`, match (`new_object0`) |
| steps    | 158                                                                       | 187                                                      |

This is much closer than the PPF experiment of §19, and for a reason worth
writing down: a feature match does not compare a _length_. Its tolerances are
`rgba ±10` out of 255 and angles of 20–40°, so a millimetre of difference between
our MuJoCo scene and Monty's camera changes which nodes match only at the edges
— whereas PPF compares a length at 0.001 and a millimetre is decisive. The one
disagreement, eval epoch 2, is the cube at an unseen rotation: Monty still had a
path for it, we did not.

The referee's standing limitation is §19's and unchanged: Monty's recordings do
not carry percepts, so an episode cannot be replayed exactly, and no episode is
parity evidence. The evidence for the port is the nine cases in
`feature_graph_lm_test.exs` — hand-written intent, because Monty has no unit test
for `feature_location_matching.py` either, and the moduledoc says so.

### 20.4 What is documented rather than ported

- **Pose jitter is not ported.** Monty samples `n_samples` extra rotations per
  aligned pose with `ctx.rng.vonmises`; its only caller passes zero, so there is
  nothing to sample and no config asks.
- **Votes are negative only.** Monty's feature module also votes on the
  locations and rotations it still considers, and prunes its paths with other
  modules' such votes. This port's model routes one kind of vote. Monty's own
  comment on that path says it is not being developed further, so the callback
  answers the negative vote like the other modules and `five_lm_feature_mujoco`
  narrows on objects only.
- **The nearest matching node is found by sorting**, not by a k-d tree. Monty's
  tree wins on graphs of tens of thousands of nodes; these experiments are graphs
  of hundreds, and a sort is the same answer with nothing to keep consistent.

### 20.5 The gate

`scripts/quality.sh` green — 2 501 tests, 19 properties, worst complexity 29.85 —
and `MIX_ENV=test mix dialyzer` at 0. Seven tests had to change, and all seven
had used `FeatureGraphLM` as _the example of a class this port has not written_:
the module-map table's filter and its "no test link" case, the modules page's two
filters, `Setup`'s refusal case, and two MCP preview cases. Each now names
`TwoDSensorModule`, which is still unwritten, and the table case that said "a
class that is only named has no test of ours" now asserts the new module's own
test link instead.

## 21. 2026-11-08: the edge detector, and the OpenCV this port does not have

The cows family — 17 configs, the last big group in `docs/readiness.md` — reads
a 2-D dataset through `TwoDSensorModule`, and that module's first question is
"which way does the edge at this point run". `edge_detection.py` answers it: a
structure tensor over Sobel gradients, aggregated over a neighbourhood weighted
towards the patch's centre, and reported only when it is strong **and** coherent.
All nineteen of Monty's cases in `tests/unit/frameworks/utils/edge_detection_test.py`
are translated, ten of them as properties.

### 21.1 Three questions, in the order the module asks them

- **Was anything seen?** A flat patch has no gradient, so the aggregate is zero
  and there is no edge — not "an edge of strength zero in an arbitrary
  direction", which is what an unguarded argmax would report.
- **Is the edge in the middle?** The weighted centroid of the gradient, measured
  along the edge's normal, is how far the edge is from the patch centre. A patch
  half full of background has its edge at the rim, and a module that just moved
  _to_ an edge does not want to hear about a different one.
- **Is it a crease in the world?** The depth gradient across the brightness edge,
  in a band 1.5 pixels wide, at its 95th percentile. Ink on a surface and the
  surface ending against the background look the same in colour and completely
  different in depth, and a 2-D model built from the first kind is wrong at its
  border.

### 21.2 What the port had to write that Monty borrows

`cv2.cvtColor`, `cv2.Sobel`, `cv2.GaussianBlur` and `np.percentile`, in
`...EdgeDetection.ImageOps`. Three details are the whole of the fidelity:

- **Fixed-point luma**, `(4899 R + 9617 G + 1868 B + 8192) >> 14` — 0.299,
  0.587 and 0.114 in 14 bits.
- **`BORDER_REFLECT_101`** — `-1` reads `1` and `n` reads `n - 2`, so the patch's
  rim is a continuation of the surface rather than an edge of its own. A filter
  that zeroed outside the patch would make every patch's border the strongest
  feature in it.
- **A separable Gaussian**, one vector of weights applied to rows then columns,
  normalised to sum to one.

That these agree with OpenCV closely enough is not asserted — it is measured by
the five closed-form camera cases and a property over random rotations, both of
which demand the detected angle within 0.1 rad of the angle the fixture patch was
cut at.

### 21.3 The two bugs the translation caught

Both were in `angle_to_pose_2d`, and both were written wrong first:

- **The perpendicular has to come from the normalised tangent.** Monty
  normalises `[u, v, 0]` and then builds `[-v, u, 0]` from _those_ components; the
  port first used the raw dot products, which is the same only when the tangent
  frame is exactly orthonormal. The transported-frame case is the one that
  noticed — 0.38 radians of it.
- **The signature of a wrong frame is a reflection, not a rotation.** The
  expected pose in that case is computed in the test by the _other_ spelling of
  the same formula (`cos·x − sin·y` against production's `cos·x + sin·(−y)`),
  which is why the case is an independent check rather than a restatement.

### 21.4 Where the cows family stands now

- `StructureTensor`, `EdgeFeatures`, `EdgeDetector`, `Monty.Math`'s tolerance,
  `TangentFrame` and `project_onto_tangent_plane` — all written.
- Still missing: `TwoDSensorModule` itself (368 lines, which also wants
  `arc_length_corrected_displacement` and `Monty.Memento`), `DefaultAttentionSystem`
  for 9 of the 17 configs, and a pretrained cows model on the machine for 16 —
  which is what `/prerequisites` exports rather than code.

### 21.5 The gate

`scripts/quality.sh` green — 2 532 tests, 31 properties, worst complexity 29.85 —
and `MIX_ENV=test mix dialyzer` at 0. The module map now says 193 of Monty's 360
classes are written.

## 22. 2026-11-08: `TwoDSensorModule`, and a shape correction that came with it

The cows family's last missing class. Eight of its seventeen configurations now
compose with nothing but this — they also want a pretrained cows model, which is
a `/prerequisites` export rather than code — and the readiness counts go 99/24 to
100/23.

### 22.1 What it does, in the order it does it

A surface agent's patch sees a piece of a curved surface. The module reports
where the sensor is on a _flat_ version of that surface and which way the edge
under it runs, which is what a 2-D model of a logo needs:

1. **Features**, from the same `ObservationProcessor` every sensor uses.
2. **The pose is withdrawn** (`pose_fully_defined` set false) and given back only
   if the edge detector finds an edge through the patch's middle. A _geometric_
   edge — a crease in the world, from the depth image — does not count: the
   module is looking for ink, not for where the object ends.
3. **The tangent frame** follows the surface, transported rather than rebuilt.
4. **The step is unrolled**: the 3-D movement projected onto the tangent plane,
   resolved along that plane's basis, and corrected from chord to arc with the
   curvature frame the sensor fitted _before_ the edge replaced it.
5. **The noise and the percept filter**, in Monty's order — which matters,
   because the filter decides whether this percept is new enough to send, and it
   sees the 2-D location, not the 3-D one.

The first observation of an episode defines the origin: world `x` and `y` with
`z` set to zero. Monty's own note says why this is only right for a camera whose
image plane is aligned with world `xy`, and the port repeats it rather than
papers over it.

### 22.2 The observation was a struct for one commit, and should not have been

The edge detector's commit gave `Monty.Observations.SensorObservation` a struct
with `rgba`, `depth` and `cam_to_world` fields. That was wrong, and this module
is what showed it: in this codebase an observation is a **string-keyed map** —
what `depth_to_3d_locations` writes, what `ObservationProcessor`, `SalienceSM`
and `on_object_observation` all read — so the struct was a second shape for one
thing, and `ObservationProcessor.process/2` could not even take it.

It is now a module of named accessors over that map (`rgba/1`, `depth/1`,
`cam_to_world/1`, `point_cloud/1`), each raising a sentence when the key is
missing, because a missing `"semantic_3d"` means the depth-to-3D transform did
not run and not that the observation is empty. The lesson is the one §19 and §20
keep teaching from the other direction: read what the codebase already passes
around before giving a Python `TypedDict` an Elixir shape.

### 22.3 How the cases were translated

Monty's `two_d_sensor_module_test.py` patches `_observation_processor.process`
with a mock and hands the module a hand-built percept. There is no method object
to patch here, so the cases build a small patch of points and let the **real**
processor make the percept — closer to the truth than a hand-built one — and
inject only the edge detector, as `{module, detector}`, the shape the module's
noise and percept filter already take. `Monty.Test.CannedEdgeDetector` is that
injected module.

Two assertions had to be re-stated rather than copied. Monty asserts the tangent
frame is the _same object_ after two steps (`is`); Elixir has no identity to
compare, and the property that matters is that the _basis did not move_ — a frame
rebuilt from the second normal would pick a different axis — so that is what the
case asserts. And Monty's off-object case asserts `msg.displacement["displacement"]`;
here a message's displacement is a plain field.

### 22.4 The gate

`scripts/quality.sh` green — 2 556 tests, 41 properties, worst complexity 29.85 —
and `MIX_ENV=test mix dialyzer` at 0. Seven test fixtures moved again: they had
used `TwoDSensorModule` as _the_ example of a class this port has not written,
and now name `DefaultAttentionSystem`, which is what the ranking leads with. The
one that checked "a sensor class this port has not written gets the stand-in"
now uses Monty's own test fake (`monty/sensor_module: fake`) — the only sensor
class in the tree that is still unwritten — and a new case asserts that the
three-sensor config builds the real 2-D module.

## 23. 2026-11-08: the attention package — seven files, one seam, and nine configs that now want an export

`src/tbp/monty/attention/` is a package rather than a class: a sparse grid, a
pooler, a decay, a merge, a goal filter, a telemetry and the system that wires
them. All seven files are ported here, seventeen classes, with the unit cases
translated one for one. The readiness counts do **not** move — still 100/23 — and
that is the interesting part: the nine cows compositional and monolithic
configurations the ranking put behind `DefaultAttentionSystem` were refused for a
second reason too, the pretrained model. Writing the attention system leaves them
refused for `no_pretrained_memory` alone, which is a `/prerequisites` export and
not code.

### 23.1 What attention does

Sensors propose where to look (`AttentionRegion`: locations and weights), the
goal generator proposes what to do (`Goal`), and the attention system sits
between them:

    proposed = regions → voxels → one pooled weight per voxel
    step:  decay(grid) → expire → merge(expired, proposed) → goal filter(goals)

`expire` is what makes the grid a memory rather than an accumulator: a weight
whose magnitude has decayed below `1e-6` is dropped, so a place that has not been
looked at for long enough stops being a voxel at all. `merge` is a union in which
the newer grid wins where they overlap, and the goal filter then reads the merged
grid: a goal in an inhibited voxel is dropped, a goal outside the grid is dropped
unless every voxel is inhibited, and a goal without a location is never filtered
at all — it is not a place, so there is nothing to look up.

### 23.2 Where the port could not be a transcription

**The pandas frame is a map.** Monty's `VoxelGrid` is a `DataFrame` with an
`(x, y, z)` `MultiIndex`, and its tests can therefore build a malformed frame and
watch `validate_dataframe` refuse it: no `(x, y, z)` index, a duplicated index, no
`weight` column, a weight column that is not one dimension. A map cannot hold
those shapes — a duplicated voxel is simply one entry — so four of the six
`ValidateDataFrameTest` cases have no counterpart here, and the one rule a map
_can_ break survives as `VoxelGrid.new/3` refusing two weights for one voxel.
`voxelize_and_bin_points` returns the rows (`{voxel, weight}`) that pandas would
have grouped; `weights_at_points` answers `nil` for an unoccupied voxel, the NaN
of this port.

**Nothing mutates.** Monty's decays, telemetry and attention system are objects
with state they change in place, so its cases can hold a `MagicMock` up to one
collaborator and assert _that it was called, with what_. Here every step is a
value: `step/3` answers `{system, goals}`, a decay answers a decayed grid, and the
telemetry is threaded. Most of `DefaultAttentionSystemTest`'s seventeen cases are
therefore translated into what the mock was protecting — the grid the step
produced and what the telemetry recorded — with
`DefaultAttentionSystemTelemetry` standing in as the recording double. The four
cases that drive `_voxelize_attention_regions`, a private method there, are read
off the proposed grid `step/3` hands to the telemetry.

**A one-method protocol is a function.** `WeightPooler`, `VoxelGridWeightDecay`,
`VoxelGridMerge` and `GoalFilter` are all `Protocol`s over `__call__`, i.e.
callables with state bound to them. The port writes the contract as a behaviour
and stores the collaborator as a function (Monty's bound `__call__`), so
`new/1` turns a decay _value_ into one for you. `telemetry` is the exception and
stays a value, because it is the one collaborator with state of its own.

### 23.3 The gate

`scripts/quality.sh` green — 2 604 tests, 63 properties, worst complexity 29.85,
unchanged — and `MIX_ENV=test mix dialyzer` at 0. The module map went 195 → **210
implemented** of 360 classes.

Nine test fixtures moved, the same churn every landed class causes: they had used
`DefaultAttentionSystem` as _the_ example of a class this port has not written.
They now name `MontyBase`, which the ranking leads with — and the cows
compositional configurations are no longer a usable example of "refused because a
class is missing", so the readiness, setup, MCP and experiments-page cases moved
to `test/base_config/base_mujoco`, whose `MontyBase` is still unwritten.

`Monty.Attention.Telemetry` has no test of its own in Monty (its telemetry is
exercised through the attention system there); the three cases in
`telemetry_test.exs` say so and are marked as intent tests, not translations.

## 24. 2026-11-08: `MontyBase` was not missing — its job is the runtime's, and a name nobody can place is now refused

The readiness ranking's last class was `MontyBase`: three MuJoCo configurations,
all of them Monty's pytest fixtures. The question was whether to port it. The
answer, from reading it against what is already here, is that there is nothing to
port — and that the three configs were refused for the wrong reason.

### 24.1 What `MontyBase` is, and who does it

`MontyBase` is the concrete stepping of the abstract `Monty`: it owns the module
lists, runs sensors → outputs → inputs → learning modules → the vote round →
`_pass_goals` → the motor system, counts the steps, decides the terminal state,
and answers a state dict. `Monty.Runtime.Model` owns the modules, `Monty.Runtime.Step`
runs that same sequence, `Monty.Runtime.Step.State` carries the same counts, and
`Monty.Studio.Run` is the episode. `Monty.ModuleMap.StandIns` already said so for
`Monty`; `MontyBase` was simply not listed.

It is listed now. The evidence is not the reading, it is a run: with `MontyBase`
classified, `mix monty.run test/base_config/base_mujoco --episodes 1 --steps 12`
composes, prints `test/base_config/base_mujoco (monty) — MontyExperiment on
MontyBase`, and steps (`step 0 · 18.2ms`). The class is the runtime's job, done.

### 24.2 The run then failed, and the failure was the point

It failed two steps later, in the carried MuJoCo world: `get_eval_info_bytes`
raised `StopIteration` while MuJoCo wrote to stderr. Real, and separate — but the
preview had also said, twice, that this config names classes **the module map does
not know**: `tests.unit.frameworks.models.fakes.sensor_modules.FakeSensorModule`
and `…learning_modules.FakeLearningModule`. They live in Monty's `tests/` tree, so
no port can have them; `test/base_config/base_mujoco` is a fixture that a port can
never run.

Those two findings were `:warning`, so the config read as **runnable** the moment
`MontyBase` stopped refusing it. That is the worse of the two lies: a class that
cannot even be named is now an **error**, on the same reasoning `not_ported_finding`
already used — a run under a name nobody can resolve is a run of something else
wearing the experiment's name. The CLI refuses it before starting and names the
fake; readiness counts go back to 100 runnable of 210, with `unknown_module_class`
refused 3 and postponed 3 replacing `modules_not_ported`, which is now **0 refused**
for the first time: no configuration in Monty's tree is refused for a class this
port has not written.

`Readiness.blocked_by` names those classes too, so a refusal that is about a name
is not a refusal with no reason.

### 24.3 `_pass_goals`: one ordering difference, and Monty's case that finds it

`MontyBasePrivateTest` has exactly one case, and it is about `_pass_goals`: the
goals are the learning modules' then the sensors', the regions are the **sensors'**
then the learning modules', and the pair goes to the attention system. The
runtime's `propose_goals/1` already collected goals in Monty's order;
`propose_regions/1` collected regions the other way round. Nothing reads the order
today — attention pools every weight about a voxel with `min`/`max` and groups by
voxel before answering — but a difference nothing reads is a difference the next
change inherits, so it is Monty's order now, and Monty's case is translated in
`step_test.exs` to hold it: two sensors and three modules, a recording `attention`
function in place of the `MagicMock`, and the assertion that what attention
answers is what the motors were given.

### 24.4 The gate

`scripts/quality.sh` green — 2 605 tests, 63 properties, worst complexity 29.85
unchanged — and `MIX_ENV=test mix dialyzer` at 0. Five fixtures moved: they used
`MontyBase` as the example of a class this port has not written, and there is no
longer such a class in a refused config, so they now prove what actually refuses —
a config naming a name the map cannot place.

## 25. 2026-11-08: the cows memory — three readers nobody had written, and one library that was the same file seven times

Eighteen of the cows family's configurations were refused for `no_pretrained_memory`.
The ranking called that "a `/prerequisites` export rather than code". It was code:
exporting the release found three things the reader could not do, and one thing the
library format could not say.

### 25.1 What the archive holds, and what the reader expected

`pretrained_compositional_objects_v8` is 31 MB and seven models. The export walked
them and failed on `no function clause matching in Tensor.rows/1`, because that
release's models are not torch `Data` graphs: each keeps its nodes in a
`GridObjectModel`, whose graph is a **`NumpyGraph`** — a map of `pos`, `x` and
`feature_mapping` whose two arrays are numpy, not torch. Three readers were missing:

- **`Monty.Studio.Pretrained.Numpy`** reads a pickled numpy array: `_reconstruct`
  inside the pickle carries a shape, a dtype code and the raw bytes, which is
  everything `Tensor` needs. Row-major and column-major are carried as strides
  (`[columns, 1]` against `[1, rows]`) rather than copied, since `Tensor` already
  reads through strides. A string array is one more object the walk ignores; a
  numeric dtype with no decoder is refused by name, because a feature column read as
  "absent" is a graph that matches nothing for a reason nobody can see.
- `Tensor` grew `:i32` and `:u8` — a surface model stores a flag as an unsigned
  byte, and its coordinates are the same `f8` as everywhere else.
- `graph_of/1` needed no change after all: `NumpyGraph`'s object state is already
  the map with `x` in it.

### 25.2 The library was one memory, and a heterarchy has three

With the reader working, all seven libraries came out **byte-identical** — md5
`aa5a6fae…` seven times. That is the export's own trap ("exporting a memory by
exporting nothing") in a new dress: `module_memory/1` took `lm_dict[0]`, and in
every cows model module 0 is the same 3-D child. The high-level module — the one
that recognises a mug with a logo on it — was never exported at all.

So a record now carries `"lm_index"`, `stream_records/1` walks every module, and
one library holds one memory per module:

- `lm 0` — five 3-D objects with `hsv` and log curvatures,
- `lm 1` — the two logos with `hsv`,
- `lm 2` — nineteen compositional objects, fed from `patch_2` _and_ from the two
  child modules as hierarchy inputs.

`Memory.load_module/4` reads the one a caller asks for, `Memory.modules/3` says how
many a library holds, and `Memory.load/3` is still `(name, release, dir)` for the
single-module case — the module index got its own name rather than a third
positional argument, so a directory and an index cannot be confused.

The features a record carries are now **the ones its graph holds**, not the four
this port's evidence kernel matches on: a 2-D child's graph has a colour and a pose
frame and no log curvatures, and asking for a column that is not there stopped the
export of a whole release on one module. Which of them a memory is _matched_
through is the module's decision, taken when the library is read.

### 25.3 `Setup.memories/1` was wrong about Monty

It gave every learning module the same memory, and said so as a fact about Monty
("Monty loads the model's memory once and every learning module matches against the
same graphs"). Monty's pretrained store is `lm_dict`, one memory per module, and
`setup_model` hands `lm_dict[i]` to `learning_modules[i]`. Each module now reads its
own by index — the change that makes a compositional run mean anything, since three
modules sharing the child's memory is a run answering with confidence about the
wrong thing.

### 25.4 Two refusals that were promises

Adding the memory made sixteen cows configurations read as runnable while their
objects — 1.6 GB — are not on this machine. `object_in_world_findings/1` only asked
whether a config _named_ an object, never whether the object was on disk, so the
world's own directory was never checked.

- `world_data_missing` (error) — the config's `data_path` is not a directory. This
  is the 19 that are now refused, and the message points at `/prerequisites`, which
  now offers `compositional_objects_1.4_mujoco`, its `random_locs` sibling, and
  `pretrained_compositional_objects_v8` (all three added to
  `priv/prerequisites.yaml`, so they are fetched and exported by the same saga as
  every other archive).
- `world_holds_no_object` (error, was a warning) — the directory is there and none
  of the meshes the config names is in it.

Both are the reasoning §24 used for an unplaceable class: a run that steps a scene
with nothing in it spends the episodes and answers none of the experiment's
question, which looks like a result.

### 25.5 The gate

`scripts/quality.sh` green — 2 614 tests, 63 properties, worst complexity 29.85
unchanged — and `MIX_ENV=test mix dialyzer` at 0. Readiness is **97 runnable, 26
refused, 87 postponed**: 100 → 116 when the memory arrived, 116 → 97 when the data
check told the truth. `no_pretrained_memory` is down to 2. The libraries are in
`priv/monty/libraries/pretrained_compositional_objects_v8/` (0.8–3.7 MB each, seven
distinct files).

## 26. 2026-11-08: the cows run steps, and an image is either bytes or fractions of one

The cows family's objects are not on this machine, so the experiment itself cannot
run (readiness refuses 19 configurations for `world_data_missing`). What _can_ be
checked is everything upstream of the world: the three exported memories, the
model that carries them, and the sensors. `base_infer_cows_small_compositional`
opened on the stand-in scene runs six steps with

    inputs: %{"learning_module_0" => 1, "learning_module_1" => 1, "learning_module_2" => 1}
    percepts: ["patch_0", "patch_1", "patch_2", "view_finder"]

— the 3-D child, the 2-D child and the high-level module all fed on every step,
with the memories §25 exported, and no conclusion, which is right: a sphere is not
a mug with a logo on it.

That probe found a crash worth keeping. `ImageOps.to_gray/1` is OpenCV's
fourteen-bit fixed point, which takes an **8-bit** image; the stand-in scene renders
rgba as **fractions of one** (`synthetic/camera.ex` says so). The fractional image
reached `:erlang.bsr/2` and raised — the whole step, on the first patch. The two
conventions now meet once, in `to_gray/1`: an image whose brightest channel is at
most 1 is fractional and is scaled before the fixed point, and the answer is the
answer the bytes give. Two cases hold it — one over the conversion itself, one
through the real detector in `TwoDSensorModule`, asserting that a byte image and its
fractional twin find the same edge with the same strength.

Monty has no such case because Monty's images are always a camera's bytes. It is
the stand-in scene that is unusual, and the port's job is to be right on both.

Gate: 2 616 tests, 63 properties, worst complexity 29.85 unchanged, dialyzer 0.

## 27. 2026-11-08: seven files under `conf/experiment` are not experiments

One configuration was refused for `epochs_not_a_count` — `n_train_epochs` was
`nil` — and the honest answer turned out to be that it has no epochs because it has
no experiment. Six more files were in the catalogue the same way.

Monty's own tests compose an environment, a sensor module and a learning module out
of files that live under `conf/experiment` and carry only their group's fragment:

    # @package experiment.config.environment
    env_init_args:
      agents: [...]

No `_target_`, no epochs, no experiment. The catalogue listed them because they are
YAML under the right directory, so it offered seven configurations that are pieces
of one, and refused the MuJoCo one for an epoch count it never declared.

`Monty.Studio.Catalog.read/1` now drops a file that names no experiment class. The
catalogue is **203**, not 210 — and four rows leave the reason table with them:
`epochs_not_a_count`, `sm_to_lm_matrix_missing`, `sensor_agent_mapping_mismatch`
and `learning_module_count_mismatch` were all about these seven. What the table says
now is only about experiments somebody could run: objects not downloaded (19), a
class nobody can place (3), a memory not exported (2), `GraphLM` refusing its own
config (1), and a world with nothing in it (1).

Readiness: **97 runnable, 25 refused, 81 postponed** of 203. Gate: 2 618 tests, 63
properties, worst complexity 29.85 unchanged, dialyzer 0.

## 28. 2026-11-08: twelve of Monty's evidence-LM cases, translated

`tests/unit/frameworks/models/evidence_matching/evidence_lm_test.py` is the file
the handover has twice named as the next thing (§15.3 item 2), because it is where
the one measured behavioural difference lives. Twelve of its sixteen cases are now
`test/monty/frameworks/models/evidence_matching/evidence_lm_test.exs`, one for one.

The fixture came first, from Monty's own `BaseGraphTest`: four percepts that walk a
corner of space one axis at a time, one pose at every point, so a pose never
disagrees and only the location says where the sensor was. A module learns those
four points through `exploratory_step`, is told the object it detected, and stores
them; a later episode walks them again through `matching_step`.

What the twelve say, in Monty's numbers:

| case                                             | what it pins                                                                                                   |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `object_id_features_are_unique_and_float32_safe` | 77 YCB and 126 compositional names share no id, and each is exact in a float32                                 |
| `top_two_mlh_ids_without_current_hypotheses`     | a module that has not started matching answers `{nil, nil}`                                                    |
| `same_sequence_recognition_elm`                  | evidence `1, 3, 5, 7` — one for the pose, one for the features, a step                                         |
| `reverse_sequence_recognition_elm`               | the same, walked backwards                                                                                     |
| `offset_sequence_recognition_elm`                | the same, the whole path moved a metre                                                                         |
| `new_sampling_recognition_elm`                   | the same, two points nudged by a millimetre or two                                                             |
| `different_locations_not_recognized_elm`         | matches `1, 1, 0, 0` — the second displacement is what fails                                                   |
| `location_only_step_displaces_hypotheses_elm`    | every hypothesis moves by its pose-rotated displacement; evidence and the MLH index do not change              |
| `symmetry_recognition`                           | one pose is never chosen, both `0,0,0` and `180,0,180` stay possible, and the ambiguity is counted once a step |
| `different_features_still_recognized`            | evidence `0, 1, 2, 3`: shape alone, one a step                                                                 |
| `different_pose_features_not_recognized_elm`     | evidence climbs by one, then falls below one, then below nought, and nothing is left                           |
| `moving_off_object_and_back_elm`                 | a percept the model drops earns nothing; the object is still recognised afterwards                             |

Two of these are worth reading twice. The **symmetry** case exposes a shape the port
had never been asked for: `get_possible_poses/2` lists every hypothesis' pose
without narrowing, so a symmetric object reports its two poses four times each —
which is Monty's own behaviour, and why its case reads the first and the last entry
rather than counting. The **pose** case is the port agreeing with Monty on a decay:
a first percept facing another way leaves evidence `> 1` at the second step, `< 1`
at the third and `< 0` at the fourth, because the pose the module started from stops
being possible without the object being wrong.

Four cases are not translated, and they are the four that need a goal generator:
`hypothesis_testing_proposal_for_id{,_with_transformation}` and
`..._for_pose{,_with_transformation}`. Each trains two objects (a square and the
"house" that is a square with one more corner), then asks
`EvidenceGoalGenerator._compute_graph_mismatch()` which location would tell them
apart. That needs a two-object fixture and the goal generator's private mismatch
walk, so it is the next unit rather than this one.

Gate: **2 630 tests, 63 properties**, worst complexity 29.85 unchanged, dialyzer 0.
CI on `147d517` failed four build jobs and only build jobs, all of them GitHub's own
504s: `failed to fetch https://github.com/astral-sh/uv/releases/...` while pythonx
compiled, `Unexpected HTTP response: 504` in `Install Erlang/Elixir`, and
`Error failed to bundle project: http status: 504` in Tauri's AppImage tooling.
Three re-runs moved the failures around — `osx-arm64` passed on a re-run — with no
test, lint, types or coverage job ever failing. Nothing in the tree was changed to
paper over a CDN.

## 29. 2026-11-08: the page says what it waits for, and what it counts

A reader using the app for an hour found five things wrong with its words, and
four of them were the same fault: the page said something true about the wrong
subject.

**"Refused" was two answers.** An experiment whose only obstacle is a file
`/prerequisites` can fetch is not refused by this port — it is waiting — and the
difference is what a person does next. `Readiness.waiting?/1` draws the line: every
finding against the experiment has to be one of the two codes a finished download
clears (`world_data_missing`, `no_pretrained_memory`) **and** the download has to
exist, so a directory no archive fills stays a fact about the machine rather than a
promise. The catalogue says `waiting for prerequisites`, sorts it between runnable
and refused, and the badges are pastel and coloured by the verdict: emerald runs,
amber waits, rose cannot, slate is not planned.

Two smaller bugs lived in that corner. The catalogue's cache key did not include
what is on disk, so a page went on saying waiting after the file had arrived — the
key carries `downloads_stamp/0` now, and `forget/0` matches the key's first
elements, so a key that grows cannot strand an entry. And a config's
`pretrained_dir` reaches the tree as a _quoted_ OmegaConf argument
(`${path.expanduser:"~/tbp/models/pretrained"}`), so `.../pretrained"` matched no
library: `Resolvers.argument/1` strips the quotes.

**Every missing thing now has a click.** `Finding.with_link/3` gives a finding the
action that answers it, `/prerequisites?fetch=<id>` starts that download when the
owner presses it, and the MCP catalogue entry carries the URL as text so a caller
without a mouse is not stuck.

**The needs were in the wrong box.** They were listed in a second alert above the
checks box, in sentences that had to be read twice — "this application can read no
memory it could start from" — while the box that actually blocks the run said
nothing. Now the box carries them, one line per need: a `missing` badge, what it
is, the path on its own line, and the action beside it — a download, `train it`
when the model's own trainer is in the catalogue, or a link to the page that
holds the rest. `checks/1` no longer repeats a need as a check.

**A counter that stood still.** The badge said `episode 9 · step 307 / 500` for
eight episodes, which reads as a run stuck at 307 of 500. Two faults met. The
number is episode-scoped — the step counter restarts inside every episode, and this
config's termination (`any1_naivescan_fixed5_tot6000`, `NaiveScan fixed_amount: 5`)
ends every training episode after exactly 307 steps, whatever the object — so 307
was right. But `{:episode, n}` did not reset the counter, and the guard that keeps
the badge from walking backwards inside an episode then discarded every step of
every later episode: a step is a _smaller_ number than the previous episode's
total. The episode message resets the count to zero now, which is the restart the
comment always promised. `progress_from/2` also keeps the live count while a record
still says `running`, so a reconcile cannot pull the badge back to the last
checkpoint. The regression test sends the stream of a new episode by hand, because
a run of two-step episodes lands on the right final number even when every
intermediate step is dropped — which is why the existing two tests never noticed.

**And the purge a day of runs needs.** "Purge N done" is a scope of its own
(`Selection`'s `:done`): every finished and stopped run, whatever the page is
filtered to, named before it goes and confirmed like the others.

Readiness with the archives now in place: **116 run here, 0 waiting, 6 cannot run
here, 81 not planned** of 203. The 4 that were waiting split two ways — two run,
and two ask for a memory no archive fills, which is a training run rather than a
download. `docs/readiness.md` carries the numbers and the six by name.

## 30. 2026-11-08: the graph family's vote round, and a run that says it is alive

`tutorial/dist_agent_5lm_2obj_train` — the config the next training run starts from
— died on its first step with

    ** (CaseClauseError) no case clause matching: MapSet.new([])
    monty_for_evidence_graph_matching.ex:74 heard/3

which is a ported module being handed a vote from the other family. Monty has one
model class driving two kinds of module, and `MontyForGraphMatching._combine_votes`
branches on the shape of a vote for exactly this reason:

- an **evidence** module names the hypotheses it still believes, with the pose and
  location each implies — a list, summed;
- a **graph** module names the objects it has **ruled out** — a set, and what a
  receiver hears from several sources is the _union_, because one module's doubt is
  not another's confidence and a sum of sets is not a thing.

`Monty.Frameworks.Models.GraphMatching.MontyForGraphMatching.combine_votes/2` is
that union, ported; `Runtime.Step.State.combine_votes/2` picks the calculation by
shape, as Monty's own `_target_` does. The module map is at **211 implemented of
360** with the class marked implemented. A detail worth keeping: `nil` is not the
empty set. `nil` is a module with no opinion — or one whose vote missed the
deadline — while the empty set is a module that considered everything and ruled it
all in. Union is the same either way, which is why Monty's version is a `reject`.

The same run then taught the second lesson the hard way. It stepped 22 of its 28
episodes without complaint and was then closed as **failed**: "it stopped before it
finished — nothing was working on it any more". Nothing had stopped. The diagnosis
had: every `mix run` used to read the record boots the whole application, so a
second node ran its own boot-time `Reaper.sweep/0`, could not see the first node's
registry, and found a record whose last write was a full episode old.

Two things were wrong, and only one of them was mine.

- **The queue worker never said it was alive.** A record is written at episode
  boundaries — about fifty seconds apart here, and _minutes_ on the 77-object
  configs — while the Reaper allows a minute of silence. `mix monty.run` has beaten
  a heartbeat since it was written; the worker that a page starts had no such thing.
  `RunHistory.heartbeat/2` is now the one place that says it, at most once every ten
  seconds (`alive/1`, the single small write, is what it calls), and both loops call
  it. Ten seconds against a minute of grace is six missed beats before a run looks
  dead.
- **A second node must not judge the first node's queue.** That is written down in
  `Reaper`'s moduledoc, and it is why the beat matters: the registry is this node's,
  the record is everybody's. Reading the database with `psql` while a server is up
  is the way to look at a run; `mix run` starts an application, queue and reaper
  included.

Gate: **2 645 tests, 63 properties**, worst complexity 29.85 unchanged, dialyzer 0.

## 31. 2026-11-08: `GraphLM` was refused for a capability it is never asked for

`tutorial/surf_agent_2obj_train` — the training half of the surface-agent
tutorial, and the run that writes the memory its evaluation half reads — was
refused with

> This config's learning module cannot be built here: a bare graph module has no
> matching scheme to narrow possible matches with.

That was true of the _port_ and false of Monty. `GraphLM` is the base class of the
graph family, `graph_1lm.yaml` names it, and Monty builds it and trains with it:
a supervised pretraining episode is handed the object and the pose it saw
(`supervised_lm_ids: all`), so `_compute_possible_matches` — the method every
subclass answers and the base class raises `NotImplementedError` in — is never
called. The port had turned "cannot match" into "cannot exist", and with it a
configuration nobody could run: the last class in `docs/readiness.md`'s ranking.

`GraphLM.from_config/2` builds the module now (its tolerances, its id, the memory
it is handed). `compute_possible_matches/4` still answers `{:error, :not_implemented}`,
which is Monty's own refusal at the point where a match is actually asked for, and
`Setup`'s `:no_matching_scheme` finding is gone because nothing produces it.

Readiness: **117 run here, 0 waiting, 5 cannot, 81 not planned** of 203 — and no
class blocks any experiment on its own. Verified by a run of the config:
`mix monty.run tutorial/surf_agent_2obj_train --episodes 1 --steps 5` steps,
learns (`added graph mug for patch`) and says `the memory now holds 1 object and 1
node`.

## 32. 2026-11-08: the next session starts with what the 147 planned classes are for

Handing over, at your direction: the next session begins with
[`planned-classes.md`](planned-classes.md), which answers the question rather
than asking it (§33). Its question was the one today's numbers raise and do not
answer — 119 of 203 experiments run here (`mix monty.readiness`), no production
class blocks one, and yet `mix monty.module_map.verify` still counts **147
planned classes** in 50 files.

What the brief measures, so the next session does not measure it again: only 11
of the 147 are named by a `_target_` anywhere in Monty's `conf/`, 80 are
mentioned by no other Python file, and the blocks are the
`*ActionSampler`/`*Actuator` pairs (28), `simulators/habitat/**` (23), MuJoCo's
agents and objects (13), the model base classes (12), environments (11), tacto
(8) and the teleop GUI (15). The two traps are written down with it: a base class
is not a config choice (`Monty` is mentioned by 34 files, `RuntimeContext` by 23,
`Observations` by 20), and "Monty has the class" is not "the port must have it" —
an action crosses `Monty.Simulators.Port` here, and _Simplify Simulator Protocol_
is completed upstream.

Also settled since §31, in this file's own terms: four commits on the run page
and the map — a trained model is one library with a module index a memory
(`5937cbf`), the chart offers a per-module view beside the ensemble's (`ead484b`),
it names itself and its axes (`66c30db`), and stepping is tested for the first
time (`ead484b`). Gate on `66c30db`: lint clean, 2 670 tests (63 properties),
CRAP worst 29.85, dialyzer 0.

## 33. 2026-11-08: 77 of the 147 planned classes were never work, and the map says so

The session §32 handed over ran, and the question it asked has an answer:
[`planned-classes.md`](planned-classes.md) is now the verdict document rather
than the brief. **147 planned → 70**, with 79 excluded and 211 implemented, and
`mix monty.readiness` did not move — 119 run, 0 waiting, 3 cannot, 81 not
planned — because none of the 77 is named by a runnable experiment.

The 77, one reason each, in the map's own data:

- **Habitat, 24.** Its six files are bindings to a C++ engine — `SceneNodeControl`
  subclasses driving magnum scene nodes, a wrapper over `habitat_sim.Simulator`,
  builders of `CameraSensorSpec`s. Nothing in them is Monty's arithmetic.
- **Tacto, 8.** The same, and its own test says so: `tests/unit/simulators/tacto/
tacto_test.py` skips without `habitat_sim`, and `TactoSensor.get_specs` answers
  a `habitat_sim` type. No config in Monty's tree names tacto.
- **The action protocols, 28.** Each is a `typing.Protocol` with one signature.
  Sampling is `ConstantSampler`/`UniformlyDistributedSampler`'s
  `sample_<action>` functions; acting is the carried world's, across
  `Monty.Simulators.Port`. The map already gave `ResettableSensorModule` this
  verdict; `Action`'s own moduledoc said "stay planned" and now points here.
- **The step hooks, 2.** `StepHook` is a Protocol and `NoOpStepHook` is its
  no-op, which is what a run with no hook is here by construction; no config in
  `conf/` names one.
- **The teleop GUI, 15.** Matplotlib panels, widgets, a live draw loop and two
  policy adapters that turn a click into an action. This app draws the same
  things with LiveView components over a run record, and `Monty.ModuleMap`'s own
  moduledoc already said the namespace exists for the module that _replaces_
  what a teleop developer wrote.

MuJoCo's 17 stay planned **and carried**: `priv/monty_py/world.py` defines
`MuJoCoSimulator`, the three agents, `ObjectMetadata` and the six exceptions, so
those classes run here in Python, and `stand_in:` on each is the record. With the
two shell classes (`Monty`, `MontyBase`) that is 19 planned that owe nothing; the
51 that remain are blocked out in `planned-classes.md` — the shapes in
`abstract_monty_classes.py` and `environments/environment.py` (12), the wandb
handlers (5), the two-dimensional worlds (6), experiment-side classes (11), and
17 singles.

Two traps found while measuring, both now pinned: `scripts/refresh_features.py`
read a `classes:` list with a bracket match, and a class carrying
`stand_in: [%{…}]` closed the list at the first `]` — the page printed 338
classes where the map has 360, and under-counted planned by 17. And three test
fixtures used `HabitatAgent` as "the example of a class this port has not
written"; they name a wandb handler now, which is owed work rather than a class
that will never exist.

Gate: lint clean (7 433 mods/funs), 2 670 tests (63 properties), CRAP worst
29.85, dialyzer 0. `mix monty.module_map.verify`: 131 files, 360 classes — 211
implemented, 70 planned, 79 excluded.

## 34. 2026-11-09: the experiment page's charts, and five things a reader caught

This session was one page's charts and the honesty of what they say. Most of it
came in as bug reports from the user, in this order, and each one turned out to
be a real defect rather than a preference.

### 34.1 What landed

| Commit                                                | What it fixed                                                                                                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `438c724`                                             | "follow latest steps" on the experiment chart, and the test that exposed `window_label` disagreeing with what was drawn                                       |
| `28aaba0`                                             | `MuJoCoSimulator` named 1-to-1 with Python's class, with the "why this looks nothing like it" disclaimer in the source, not in a page note                    |
| `ef48f75`, `a86d164`                                  | the run page: log tail 300 (24 329 rows were being rendered), `Replay.series/1` from 8 986 ms to 37 ms — the reconnect loop was a page taking 17–25 s per GET |
| `b23a656`, `4c696b9`, `29859e6`, `cfc015a`            | y-autoscale per chart, no decimation (it doubled every line), episode bands pastel-only, padded series                                                        |
| `4fb71f4`, `dc52782`, `5dbda71`, `96a4e4e`, `029df26` | per-chart full screen, the budget as a control, one gesture implementation, the two Windows packaging fixes                                                   |

### 34.2 Full screen, and the three attempts it took

The card expanded to `fixed inset-0` and the **chart inside it stayed 960×300**, so
"full screen" was a small chart in a large box with padding around it. Three
separate causes, each found by measuring rather than by looking:

1. The card held both `relative` and `fixed`. Tailwind emits `.relative` after
   `.fixed`, so the card stayed in the grid. One position utility per state now.
2. Even fixed, the plot kept its ribbon shape, because an SVG with `w-full` and a
   viewBox can only scale uniformly. The chart is now **drawn for the box**: the
   hook measures it and sends `{width, height}`, and the server redraws that one
   module's chart at that size.
3. On the _second_ expansion the chart was drawn for the **first** box, because
   the hook remembered the size it had already sent. `measure()` forgets it when
   the chart leaves full screen.

The lesson, written down because it will recur: `measure()` on the client is
state that survives a re-render, and anything it remembers must be invalidated by
the event that removes the thing measured.

### 34.3 "The experiment halts earlier" — it did not

A run of one episode of three steps, of a config whose panel says "2 eval", reads
exactly like an experiment giving up. The records say otherwise: every such run
had `inputs: %{"episodes" => 1}`, because the page's address bar carried
`?episodes=1&steps=3` — put there by this assistant while checking charts, and
inherited by every later run from that page, since `experiment_path/2` re-emitted
the budget on every patch.

Two changes:

- the run's budget is a **control on the page** (`#run-budget`): episodes "of N in
  the config", and the most steps one may take, with the config's own value as the
  placeholder;
- a zoom patch emits **the window and nothing else**. A chart link is about the
  picture; what a run does is decided where it can be seen.

The run at 14:58, with no slice, ran `episodes => 2, episodes_done => 2, steps =>
59` — the config's episodes are honoured.

### 34.4 Two charts were two implementations

The experiment page and a run's page draw the same kind of chart, and the way a
reader operates one was written twice: in the run page's `.ChartHover` and again
in the experiment chart's `.EvidenceChart`. That is why they zoomed by different
factors (×2 against ×1.33), why only the run page had drag-to-zoom, and why the
"second full screen" bug had to be fixed in a place only one of them could have.

`assets/js/chart.js` now holds `ChartZoom`; both charts answer to it, and say what
to call the gestures with data attributes (`data-zoom-event`,
`data-zoom-all-event`, `data-size-event`, the window and its gutters). Their
**readouts stay separate on purpose**: the run page names one value, the
experiment page names every object at that step. Those are different questions.

### 34.5 Still open, in the order they should be done

1. **Two geometry modules for one picture.** `Monty.Studio.Chart` draws ticks and
   labels inside the SVG with margins; `Monty.Studio.Replay.Chart` draws a
   full-bleed plot with HTML labels beside it. They produce different structs.
   The seam is real and small: `Replay.Chart.many/2` already takes
   `[%{id, label, points: [%{step:, value:, episode:}]}]`, derives bands from the
   episodes, autoscales to the window, and emits hover samples. `Monty.Studio.Chart`
   could build those series from beliefs and delete its own drawing; its ~40 tests
   would move to the module that now owns the behaviour.
2. **The runs table says the budget, not what happened.** `#experiment-runs-table`
   draws `run.steps` (the ceiling: `6000`) where the runs page correctly uses
   `RunHistory.steps_run/1`. Make the cell `31 of 6000`, or the runs page's single
   number plus the ceiling in a `title`.
3. **`took` is `0µs` for a run that is still going**, because `duration_us` is only
   written when a run is closed. Needed: `RunHistory.elapsed_us/2` (`finished_at ||
now` minus `started_at || inserted_at`) and both pages using it. `0µs` was read
   as "nothing is happening" — the one thing a live duration must not say.
4. **Stuck runs are judged by a timer where a process could be asked.** The
   reaper is already correct — `Run.held?/1` is a registry lookup keyed by run id,
   and a `running` record with no process and no queued Oban job is abandoned
   without any timeout. Where a timer remains: the one-minute grace for a job that
   has just started, and headless runs (`mix monty.run`) that no registry on this
   node can see. But **the page's** "quiet Ns" badge is `RunHistory.stalled?/1`,
   which is silence only and cannot tell a slow MuJoCo step from a process that is
   gone. It should ask the pid (`Process.info(pid, [:status, :current_stacktrace])`)
   and fall back to the timer only when there is no process to ask.
5. **The zoom hint lines differ by a word.** The run page says "drag to zoom ·
   shift-drag to pan · wheel to zoom · double-click for the whole run · each band
   is one episode…"; the experiment page says "wheel to zoom · double-click for the
   whole run". With one hook, the same sentence belongs in one place.

6. **`mix monty.run` has no `catch`** (carried from the old §3). Its own episode
   loop is not wrapped, so a raise there leaves the record `running` until a page
   reaps it, with the Reaper's truthful but uninformative "it stopped before it
   finished — nothing was working on it any more". The task does exit 1, so a
   script sees the failure; the record does not say why.
7. **The `Enum.slice/3` caller is answered** (`567861d`, 2026-11-10). It was 420
   `Enum.slice/3` calls and 16 083 slice operations a step: burst sampling asked
   `GraphMemory.get_rotation_features_at_nodes/4` for the frames of a few hundred
   nodes, and that walked the graph's whole `x` — one `Enum.slice` per node — then
   built a tuple of every node's rows. The frames now come from a cache built with
   the feature rows and dropped by `forget_rows/2,3`; `get_values_for_feature` no
   longer appears in a matching step's profile at all, and the read went from
   9 455 µs to 105 µs a step. The hypothesis columns were already packed, as the
   old note said — the waste was re-reading the graph's, not the hypotheses'.
8. **The next 10× is one piece of work, not a list.** After the three cuts of
   2026-11-10 (`567861d`, `22f7f2c`, `1ac30f9`) a matching step of the ten-object
   distant agent costs 1.6–2.4 M reductions: learning module 0.98–1.75 M, view
   finder 0.43–0.46 M, patch 0.21 M, coordinator 0.03 M. Inside the learning
   module nothing is above 6 % any more — fprof's own-time table is `Enum.reduce`
   plumbing 245, inner `Enum.map` closures 162, `Hypotheses.gather/3` 64,
   `EvidenceSlopeTracker.keep_where` 26, `remove_hyp` 26, `Hypotheses.bytes/2` 26,
   `update/3` 19, then six items of 13 or less — and all of it is **~60 Elixir
   function calls per hypothesis over ~13 000 hypotheses**, against Monty's ~100
   numpy calls for the same step. The way through is one kernel pass over
   representations that are already bytes: `Hypotheses.evidence_bytes/1`,
   `rows_at/2`, `GraphMemory.get_node_arrays/3`, the cached
   `rotation_features`, and `EvidenceSlopeTracker`'s ring. Two slices, in this
   order, each measurable on its own:
   - **burst sampling's construction** — `Hypotheses.new/1` builds ~6 400 rows a
     step per graph out of `List.duplicate |> Enum.concat` (ACC 84 of the LM's
     1 092). Given node indices, the rotation rows and the evidence column, the
     kernel can emit the four binaries directly.
   - **the gather** — `Hypotheses.take/2` and `rows_at/2` make 64 160
     `binary_part/3` calls a step (own 64, the largest named item). A kernel
     gathering f64 rows by index does the same copy without per-index sub-binary
     calls.
     Then, if a step is still above a few million reductions, the patch sensor's
     depth→3D walk (`docs/speed.md`, "the one small list a pixel") is the remaining
     per-pixel pass.

### 34.6 Two traps from this session

- **Tailwind emits competing utilities in its own order, not yours.** `relative`
  and `fixed` in one class list silently loses, and a test of the class string
  passes while the browser does the wrong thing. Check `getComputedStyle`, not the
  markup.
- **`render_hook` payloads are a boundary.** The chart hook sent `String(from)`;
  `range_window/3` called `round/1` on it and the LiveView died. Numbers are sent
  now and the handler parses anyway.

### 34.7 The gate at hand-over

`scripts/quality.sh` was last run green on `5dbda71`'s predecessor (lint 4 405
mods/funs, 2 720 tests, CRAP worst 26.67, complexity ok). After `96a4e4e` the
compile is warning-free and the two page suites pass (53 + 129), but **the full
gate was not re-run** — the user asked for a commit and push to hand over. Run it
first.

CI: `cc5c827`, `3238358` and `e78a19f` each closed everything except
`desktop (ex-tbp-monty-win-x64)`. Three links in that chain are fixed in order:
`e78a19f` asks `deps.compile ex_tbp_monty_core --force` for the crates (that is
what builds them; `mix compile --force` never did), `029df26` removes the hand
copy that then collided with the file Mix had just written and Windows had
mapped. `9f2fb84` puts back a `Sync-Kernels` that copies only what the build tree does
not have: it asks whether the two paths are the same file (a link) or hold the
same bytes (two copies), and skips the copy when they are. Whether the Windows
job is green after those three is the first thing to check.

## 35. 2026-11-11: the DB port that was set on nothing, and work that leaves the socket

### 35.1 `DB_PORT` was written on a module nobody starts

`config/runtime.exs` set the port on `ExTbpMonty.Repo`, which is the _delegating_
module. Dev and test name `ExTbpMonty.Repo.Postgres` as the repo this machine
runs, so the port was inherited by nothing and Postgrex fell back to its own
**5432** — on this machine the Homebrew cluster, which is why `mix ecto.setup`
dialled a database this project does not own and `mix test` had been reading a
different server from the one in `docker-compose.yml`. The port is now set on
`ExTbpMonty.Repo.Postgres` (`ec468ea`). CI is unaffected: its test job sets
`DB_PORT=5432`, and its service is on the default port.

Dev and test databases were created and migrated on 6432 as part of the fix. A
checkout that had pointed at 5432 keeps that data where it was; this is a port
change, not a migration.

### 35.2 What leaves the LiveView process, and what cannot yet

Moved into `start_async/3`, each verified in the browser:

| Where                         | Was                                              | Is                                               |
| ----------------------------- | ------------------------------------------------ | ------------------------------------------------ |
| `ExperimentLive` world switch | `Studio.open/2` inside `handle_event/3`          | a task; failures land in the flash               |
| `PrerequisitesLive` mount     | `df` (`System.cmd`) + a recursive directory walk | a task, "Measuring what these directories hold…" |
| `BuildLive` preview           | a whole compose per keystroke                    | `phx-debounce="400"` per typing pause            |

Two traps found doing it:

- **A bare `Task.start` cannot touch the database under the test sandbox.**
  `cannot invoke sandbox operation with pool DBConnection.ConnectionPool` — use
  `start_async/3`, which is supervised and carries the ownership the sandbox
  follows.
- **`render_async/1` waits for `assign_async`'s loading state, not for a
  `start_async` a page begins in `handle_info/2`.** It times out at 100 ms by
  default and returns _without_ the result, so a test that asserted on the async
  answer was asserting on stale assigns. The stale-run sweep therefore stays
  synchronous and _after_ the first paint (`send(self(), :reap)`), which is what
  its two tests pin. Everything else in the table above is a task.

### 35.3 Two reader-visible defects fixed with them

- **"follow latest steps" sprang back when unticked.** The checkbox's handler
  inverted the assign, so a label that activates its wrapping checkbox twice (the
  label carried `for=` _and_ wrapped the input) delivered two clicks and put the
  tick back. The tick now sends the value it means (`phx-value-follow`), on both
  pages.
- **Stop could say "already finished" about a run that was stepping.** Both pages
  read the job out of a queue map fetched when the page was drawn; a retried or
  replaced job made that map stale. `job_for/2` asks `Jobs.by_run/1` again before
  anything is concluded, and `cancel({run, nil})` does the same before a record is
  written off as orphaned.
- The series picker above the run page's plot overlapped the chart's border: the
  panel's gap was 2 px, less than a focused control's ring. It is 8 px now, and
  measured (`select.bottom + 3 < plot.top`).

### 35.4 What is still in the socket, in order of cost

1. `ExperimentLive`'s reap (`Reaper.sweep/0`) — one query per open run, once per
   page, after the first paint. It cannot move to `start_async` until its two
   tests can wait on the answer (see 35.2).
2. `RunHistoryLive`'s `with_steps/1` — `RunStream.steps/1` copies the whole
   in-memory log on every refresh; `steps_from/2` exists for exactly this.
3. `catalog/2` rebuilt whenever the log grows — 3 + N passes over the whole log,
   then `Chart.many/2` over the whole window.
4. `assign_charts/2` redraws every module at 4 Hz; the throttle is per page, not
   per module.

## 36. 2026-11-12: a step is answered from memory, and habitat stops being an engine

### 36.1 The three reads behind every step

A page following a run rebuilt itself four times a second (once per burst of
step messages), and each rebuild read three copies of the run's steps:

1. `RunHistory.head/1` — the row, which carries the whole `log` (a transcript
   read to learn what the page was just told),
2. `RunStream.steps/1` — the whole in-memory log, to replace what the row said,
3. `Enum.drop/2` in `append_log/2` — a second copy of the log, to work out which
   lines were new.

Now the row is asked only what memory cannot answer — how the run is doing — and
the steps are topped up from the position the page stops at.

- `read_run/2` reads `RunHistory.progress/1` (the counters; the sibling of
  `head/1`, already used by the experiment page) while this node holds a stream
  of the run, and `head/1` when it does not. A run with no stream here — settled,
  or stepped by another node — is still read whole, because then the row is the
  only account of it.
- `steps_after/1` asks `RunStream.steps_from(id, length(run.log) - 1)`; `:no_stream`
  (stream empty) is answered by reading the row, `:nothing_newer` by doing
  nothing.
- `keep_steps/2` keeps the page's steps across a poll: the stream is where they
  came from, and the row is the same run written down.

### 36.2 Two traps, both found by a failing test not by reading

- **`head/1` carries no pictures.** `pictures_less/1` drops `timeline`, so a page
  that has just read a row has its steps and _none_ of their moments. Topping up
  only the log left `log` at three steps and `timeline` at one, and the chart's
  bands are drawn from the moments — they vanished silently. The log and the
  moments are topped up separately, each from where it stops (`grown/1`).
- **The row's log is not the stream's log.** A row entry carries `step`, `at`,
  counts and (when the writer had them) `episode`; the stream's entry carries an
  episode and the modules' beliefs, which is what the bands and the per-object
  lines are drawn from. Mixing them gives a log whose middle has no episodes, and
  the one episode left starts at the window's last step — a band of zero width,
  which `bands/2` rejects. So when a stream exists the page takes the steps from
  the stream and keeps them; the row's copy is used only when there is no stream.

### 36.3 Habitat is no longer an engine

`Monty.Prerequisites` asked the carried interpreter whether `habitat_sim`
imports, which this build can never make true, and the experiment page offered a
world it does not run. The engine check, its badge, the dead option text and
`mix monty.readiness --world habitat` are gone; `@habitat_hfov` is
`@default_hfov`, which is what it measures.

The _world_ stays. `world: :habitat` is what the MCP tool's `world: "monty"`
maps to — an interpreter outside this build stepping Monty's own configs — and a
run of one still needs the dataset and the memory its config names, so
`for_setup/1` still asks for those. Upstream still ships
`src/tbp/monty/simulators/habitat`, so the mapped classes stay mapped.

### 36.4 A chart's resize listener

`ChartZoom` added a `window` `resize` listener and never removed it: the
experiment page draws one chart per learning module and replaces them as the run
steps, so a long run collected a handler per chart it had ever drawn, each of
them a server round trip per resize. `destroyed/0` removes it (and the pending
wheel's timer), the way `.ReplaySlider` and `.EscapeCollapse` already do.

### 36.5 A step costs the database nothing, and a test says so

The rule this page is built on is now pinned by a test rather than by a comment:
`run_history_live_test.exs`'s "a step costs the database nothing" attaches to
`[:ex_tbp_monty, :repo, :postgres, :query]` and counts what the repository ran
while the page showed one more step of a run it follows. It first proves the
counter against a read that certainly happens, so a wrong event name cannot pass
for "no reads".

It found two, both real and both fixed in `c043a88`:

- `with_pictures/2` asked for the shown step's frames whenever the moment had
  none — every step, for a run whose sensors kept no picture. Only a record with
  no `timeline` at all (the `head/1` case) has to ask; a moment handed over with a
  timeline came with whatever its sensors kept.
- `pictures: assigns[:pictures] || kept_pictures?(run)` re-asked at every step when
  the answer was `false`, because `false` is falsy. `Map.get_lazy/3` asks once.

### 36.6 Two traps this work found, both worth remembering

- **A page's first HTML is an API.** `scripts/boot-check.sh` starts the packaged
  release and requires `/prerequisites` to name the free space behind the roots —
  the check that once caught a Windows build reading the disk with a program the
  platform does not have. Moving _that_ measurement into `start_async` made the
  page usable while the disk is read, and made the check unsatisfiable: every
  desktop job in CI failed with "the release's /prerequisites says no room at
  all". The two facts are not the same cost — the room is one `df` per root, a
  walk of each directory is not — so the room is painted with the page and the
  walk is answered in the task. Before moving work off a page, ask what reads its
  HTML rather than its socket.
- **`Monty.Random.Stream` was the one call in a step on the default five
  seconds.** A step draws from it many times, and a draw that queued behind a long
  one — a suite running sixteen cases behind one shared stream, or a slow machine
  — killed the caller. Twice today the heavy parity test
  (`Monty.RecordingEpisodeTest`) failed with a pending `:step` message in the
  mailbox and passed on the immediate rerun; that is what this looked like. Every
  other server call in the runtime is `:infinity` because a step is
  computation-bound; the draws are now too.

### 36.7 What is still in the socket, in order of cost

1. `ExperimentLive`'s reap (`Reaper.sweep/0`) — one query per open run, once per
   page, after the first paint (see 35.2 for why it cannot move yet).
2. `catalog/2` rebuilt whenever the log grows — `Replay.objects/1`,
   `Replay.modules/1`, one `Replay.objects/2` per module, `Replay.series/1` and
   `Replay.best_evidence/1`, each a full walk of the log — then `Chart.many/2`
   over the window. **Measured** on a 20 000-step log: 37 ms for the series,
   26 ms for the objects, 6 ms for the modules, 15 ms for the headline, and about
   26 ms per extra module's chart — ~214 ms a step for a five-module run, four
   times a second. This is the one cost still repeated over the whole run.

   **A single-walk rewrite was tried and measured worse**, and reverted: folding
   all five answers in one pass cost 494 ms on the same log, because per-moment
   bookkeeping into nested maps (a `Map.update` per module per object per step)
   costs more than the walks it replaced, which were each a `Enum.map` over the
   moments. What that leaves is the design the numbers point at: **append, then
   transpose** — keep the per-step contributions in flat lists as the log grows
   and build the lines once per render, instead of re-deriving the whole run on
   every step. That is a real change to `Monty.Studio.Replay`'s contract and wants
   its own tests (its 37 tests in `test/monty/studio/replay_test.exs` are the
   safety net, and they cover the per-module/ensemble/nil-evidence cases the
   lines depend on).

3. `chart_marks/3` and `chart_samples/3` each thin the window on their own — two
   `group_by` + `take_every` passes per render over a list of up to a few
   thousand points. Small beside the SVG path the same render builds.
4. Nothing else: the experiment page's `assign_charts/2` redraws every module on
   one throttled tick, which is what drawing N charts of a run that just stepped
   costs, and the per-page throttle is the right granularity for it.

## 37. 2026-11-13: two micro-optimisations measured, one kept

Both were chosen from the step's own profile and both were timed against the
version they replace on the data a step hands them, three warm-up rounds then
five measured ones. One earned its place; the other did not, and is not in the
tree.

**`Geometry.mul/2` and `apply/2` — 1.33x, kept (`82afc06`).** They were written
as `transpose/1` plus a map of `dot/2` calls with a closure per element, and a
step calls `mul/2` once per hypothesis to rotate a frame and `apply/2` to carry a
vector through it. Written out, the product is nine multiplications and six
additions, and the pair measures 365.2 → 274.8 ns and 117.9 → 97.4 ns on one
rotation: 1.33x and 1.21x. The profile had the two at 3.2 % of a run, so the honest
size of this is about 1 % of a step — small, and worth having because it is nine
signed terms either way.

**`Hypotheses.take/2` — 1.01x, reverted.** Four passes per selection (three
`gather/3` comprehensions and a map over `possible`) looked like three passes too
many, so they became one walk of the indices that collects each column as an
iolist and concatenates it once. On the data a step has — 2 000 rows kept of
4 000 — it measured **173.35 µs against 171.22 µs**: nothing. The cost is copying
the rows (144 kB of poses per selection, once per object per step), which both
versions pay; the fourth walk of a 2 000-element list is not measurable beside
it. The four-pass version reads better and stayed, with the number recorded above
its body so the next reader does not try again.

Two lessons, both already in §7's note about `check_orthonormal`:

- A profile attributes time to the functions that _allocate_, which is not the
  same as the functions whose _structure_ is wasteful. Copying bytes shows up in
  whichever clause does the `binary_part`; removing an index walk does not move
  a number that is dominated by the copy.
- The strengthened tests stayed even though the rewrite did not: `take/2`'s
  "copies each field of the same hypothesis, and nothing at all when asked for
  nothing" pins the order asked for, the same index twice, and the empty
  selection — cases a stride read with the wrong width or a missing reverse would
  break, and the earlier test did not cover.

## 38. 2026-11-13: the threshold is one number, so it is asked of the bytes

`evidence_threshold_config: "all"` is what the experiments run, and what it
means is "update every hypothesis at or above the lowest" — one number out of a
column of thousands. `EvidenceGraphLM.update_evidence/4` asked for it by
decoding the whole column (`Hypotheses.evidence/1`) once per graph per step: on
`base_config_10distinctobj_dist_agent` that was **19 306 decoded floats a
step** of the 96 560 the step decoded in total, to take a minimum of them.

There is a kernel for it now, `MatcherNif.min_value/1`, next to `argmax_index/1`
whose column it reads the other end of, and `Hypotheses.min_evidence/1` is the
one place a caller asks (`nil` when every value is a NaN, which is `Enum.min/1`'s
answer for a column of `nil`s — a number sorts below an atom). The threshold
itself takes the column in either form — the numbers or the set that keeps them —
so `:mean` and `:median`, which need every value, still decode.

Measured with `scripts/probe_step_cost.exs` and `scripts/probe_step_profile.exs`
on the same experiment, tree before and after, six steps:

- decode: 96 560 → 77 254 values and 18.8 → 14.3 ms per step;
- the learning module's server: 1 717 210 → 1 628 710 reductions per step, and
  the step 3 316 399 → 3 227 109 (−2.7 %);
- wall 159 → 155 ms per step on this machine.

About 4 % of a step, honestly counted — the same order as §37's geometry win and
for the same reason: what is left is not one hot function but a long tail
(`Enum.reduce/3` and `Enum.map/2` between them are a fifth of a step, spread
over 300 000 calls; `KdTreeNif.nearest_many/3` is 8 % of it doing real work).

### 38.1 The runner-up, asked of the column too — 96x per call, invisible in the runs measured

`get_top_two_pose_hypotheses_for_graph_id/2` names the second best hypothesis by
what Monty's `argsort(evidence)[-2]` means, and it did it the expensive way: decode
the column, make a `{value, index}` tuple per hypothesis, sort all of them, read
one index off the end. On a 1 930-hypothesis column that is **490 µs a call**;
`MatcherNif.second_argmax_index/1` answers it from the bytes in **5.1 µs**, 96x.

The ordering is the sort's, ties included: the highest value wins, the higher
index sits above an equal value, and a NaN sorts above every number — which is
what `nil` does in Elixir's term order. So `[3.0, 3.0, 1.0]` answers `0`, not
`1`: the maximum occupies the last slot and the tie before it is the runner-up.
The reference (`Enum.sort_by/2` + `Enum.at(-2)`) stays in `Hypotheses` as the
path for a machine without the kernel, and `matcher_nif_test.exs` holds the
kernel to it over ties, gaps and short columns.

End to end it is not a win anywhere it was measured: the call sits behind
`focus_on_pose` in `EvidenceGoalGenerator`, and on
`base_config_10distinctobj_dist_agent` the step went 3 227 109 → 3 222 572
reductions (−0.14 %, i.e. noise) with the wall time unchanged. It is kept because
it is 96x cheaper on the call itself and removes a sort from the vote path — the
number that matters, not a step-time claim this experiment cannot show.

### 38.2 Narrowing a hypothesis space is a copy, so the copy is in the kernel

Burst sampling keeps the hypotheses its slopes still find plausible, and keeping
them is `Hypotheses.take/2`: three columns gathered row by row out of the columns
they already sit in. In a ten-object step that is thousands of rows and the rows
are wide — a pose is 72 bytes — so the gather was ~5.8 ms of a step spent copying.

`MatcherNif.gather_rows/3` copies at the width it is asked for, and `take/2`
encodes the indices once as u32 and calls it for the three columns. `rows_at/2`,
which hands the same kind of subset to the neighbour kernel, went through the
same path. The Elixir `gather/3` stays as the reference for a machine without the
kernel; `matcher_nif_test.exs` states the rule on a six-number column (order
asked for, a row asked for twice, and nothing asked for).

Measured with `scripts/probe_step_cost.exs` on
`base_config_10distinctobj_dist_agent`, six steps, tree before and after:

- the step 3 222 572 → 3 086 949 reductions (−4.2 %), garbage 47 → 46 MB;
- the learning module's server 1 623 394 → 1 487 425 (−8.4 %);
- wall unchanged within this machine's noise, which the probe's own header warns
  about — reductions are the number that does not move with the load.

The acceptance ladder is unchanged digit for digit (`6.338 (1429, 2)`,
`goals 15065`).

### 38.3 Two things found on the way, recorded rather than changed

**A hypothesis with no evidence is a hole in `get_possible_hypothesis_ids/2`.**
The column is decoded and `Enum.max/1` taken over it. In Elixir's term order a
number sorts below an atom, so a NaN — `nil` once decoded — _is_ the maximum, and
the arithmetic that follows (`max - max / 100 * x_percent_threshold`) has a `nil`
in it. numpy, which is what Monty reads, compares a NaN as `False` and simply
leaves that hypothesis out. So the two differ twice over on such a column: ours
raises where Monty narrows. Nothing in the runs measured reaches it — evidence is
finite in every episode of the ladder — which is why it is written here and not
changed under a performance commit: the fix is a decision about parity (follow
numpy: skip a NaN) and wants its own test and its own line in
`docs/monty-differences.md`.

**`threshold_possible_matches/2` can name `"patch_off_object"` as a match.**
`evidence_for_each_graph/1` answers with the sentinel `{["patch_off_object"],
[0.0]}` when memory has a graph but no hypothesis space, which is a shape a probe
with a recording sensor reaches once its percepts run out. `possible_of/4` then
keeps that id — its standard deviation is 0 and its evidence is not negative — so
`possible_matches` becomes `["patch_off_object"]`, and the next step asks
`get_possible_hypothesis_ids/2` for that object and raises `KeyError`. Reached by
`scripts/probe_step_cost.exs tutorial/dist_agent_5lm_2obj_eval 24`, not by
`mix monty.run` of the same experiment (3 episodes, 60 steps, clean), so it is the
probe's fixture rather than the studio. The sentinel should never survive into
`possible_matches`; that is a separate fix.

### 38.4 The band under the best is numpy's, and it is one pass over the bytes

`get_possible_hypothesis_ids/2` — Monty's
`np.where(evidence > max - max / 100 * x_percent_threshold)[0]`, asked once per
object per step — decoded the column, took `Enum.max/1` of the values and
filtered them again in Elixir. It is `MatcherNif.indices_within/3` now: one pass
over the bytes, one u32 answer per index, and `Hypotheses.indices_within/3` is
where a caller asks, with the Elixir expression kept as the reference.

This also closes the two edges §38.3 recorded, both toward numpy's answer rather
than Elixir's:

- a column holding a NaN has **no** best — `np.max` propagates the NaN and every
  comparison against one is false — so nothing is possible. The old code took the
  `nil` as the maximum (a number sorts below an atom) and then subtracted from
  it, which raised;
- an empty hypothesis space answers none. `Enum.max/1` raised `Enum.EmptyError`
  there.

Both are pinned in `hypotheses_test.exs` and `matcher_nif_test.exs`, the band is
strict (`np.where` with `>`, so a hypothesis exactly at the threshold is out),
and the ladder is unchanged digit for digit.

**Speed: nothing measurable on this experiment** — 3 086 949 → 3 087 690
reductions/step, which is noise. The call is on the terminal-condition path and
the config reaches it rarely; it is kept because it is the same answer in one
pass instead of three, and because the two edges above are now stated instead of
raising.

### 38.5 Three things measured this time that are _not_ worth doing

Kept so the next reader starts from them instead of re-deriving them:

- **The closure at the top of a `tprof` table is usually the profiler.** The
  time profile after §38.2 put `EvidenceSlopeTracker`'s `-update/3-fun-1-` at
  57.5 ms, a quarter of the step, at 2.23 µs per call. It is `Enum.map(ages,
&(&1 + 1))`: measured on its own it is 32 µs for 3 000 ages, and the whole
  `update/3` is 0.14 ms. Tracing a fun costs ~2 µs per call, so a function that
  calls a closure thousands of times reads as the step's worst cost. Trust the
  arithmetic in the table only for named functions; for a closure, measure the
  function it lives in.
- **Recording a run costs 2-6 %, not seconds.** The same ten steps of
  `base_config_10distinctobj_dist_agent`, recorded and `--no-record`, twice each:
  1 277 / 1 142 ms against 1 181 / 1 110 ms. What the studio adds is a step's
  data, not a step's second — a run that looks slow with a page open is slow in
  the modules, and the page's own costs are §36.7's.
- **The vote round is 0.5 ms.** `vote_evidence/3` decodes the evidence and the
  location column and ranks the votes per hypothesis, which looked like the
  biggest thing a five-module run does. A round over 780 hypotheses — the size
  the tutorial's modules hold — measured 0.51 ms, and replacing the five-element
  `Enum.sort/1` with a running top-three was _slower_ (0.68 ms). No kernel here.

The profile is now flat: no addressable item is worth more than a few per cent,
and the two remaining kinds of cost are the columns that are decoded because a
consumer needs the values (`calculate_slopes/1`, `vote_evidence/3`, the detailed
stats a configured logger asks for) and the per-pixel Elixir in the sensor
modules, which do not appear as one hot function at all.

### 38.6 Where the tail is, item by item, and why none of it is a commit

After §38.2 and §38.4 the profile is a long tail. Each item below was sized before
being attempted; none is worth its risk, and the sizes are here so the next
session does not re-measure them:

- **The depth image's per-pixel unprojection** (`place_in/5`, `place_pixel/6`) is
  8 % of a step's _words_, which made it look like the sensor side's biggest cost.
  Measured on its own at the real size — 64×128, two surfaces, world
  coordinates — `DepthTo3DLocations.call/3` is **1.28 ms** per image. The sensor
  modules' 600 k reductions are spread over the whole patch pipeline, not this
  loop, and hoisting the per-column factors out of it (which is bit-exact: same
  left-to-right order) would save a few tenths of a millisecond.
- **`calculate_slopes/1` decodes every hypothesis' slope once per step per
  graph**, and the one reader of the decoded list is
  `TheoreticalLimitLMLoggingMixin` — an experiment no config in the tree runs.
  It is a Monty-shaped computation (Monty builds the same telemetry dict every
  step), so dropping it is a _deviation_, not a speed-up, and would want its line
  in `docs/monty-differences.md`. Sized at ~2 % of a step.
- **`Hypotheses.index_bytes/1`** is this session's own overhead — `take/2`
  encodes the indices for `gather_rows/3`, 5 words a call, 2.95 % of a step's
  words and ~1 % of its time. Removing it means a kernel that takes the list
  instead of the bytes, for a per cent.
- **What is left is diffuse**: `Enum.map/2` 5.7 % over 106 557 calls, `Enum.reduce`
  4.9 %, `decode` 6.7 %, `nearest_many/3` 5.5 % doing the k-d search it is for.
  There is no function left whose shape is wrong — only many small ones that are
  correct and Elixir.

So the next step here is a design decision, not another kernel: either a kernel
that owns a whole update (the hypothesis updater's build-and-blend pass, which is
where `List.duplicate`/`Enum.concat`/`flat_map` live) or the numeric core on
EXLA, which is the standing ask and the only thing that reaches the ~50 ms target
at ten objects.

## 39. 2026-11-14: the run page's picture was six megabytes, and two ways out of full screen

What a reader asked for was one control on the plot, the same on both pages,
whose picture says what it will do, and a key that gets out of full screen at
once. What the measurements found under it is the reason it felt broken.

**The page was 6.7 MB and 26 240 nodes.** The replay chart drew one transparent
`<circle>` per decimated sample with a `<title>` inside it, so the browser could
show a native tooltip: two and a quarter megabytes of markup, twenty-five
thousand nodes, all re-laid out on every patch. Beside it was a `data-samples`
attribute of 1.28 MB holding the same points again as JSON. Leaving full screen
took ~460 ms for that re-layout alone, which is what "Escape does nothing" felt
like — the key was answered, the page could not show it.

The marks are gone: the hook reads the pointer off the samples and names the
step itself, so the circles said nothing the page did not already say. Measured
after: 6.71 → 4.48 MB, 26 240 → 1 042 nodes, expand 250 → 88 ms, Escape
460 → 7 ms with the socket offline. The polylines (1.73 MB) and the samples
attribute are the next two cuts and are still there.

**Escape has two paths, on purpose.** A hook (`EscapeReplay`, `EscapeCollapse`)
drops the full-screen layout in the browser and only then tells the server: with
the socket offline it is 7 ms. Beside it each page keeps the plain
`phx-window-keydown="…" phx-key="Escape"` binding, which answers in ~90 ms — it
is what works when the tab holds a bundle from before the hook existed, which is
exactly the state that made the key look dead to the person using it. Both
handlers were already idempotent.

**The control is one widget on both pages**: `btn btn-sm size-8 min-h-0 p-0`,
`hero-arrows-pointing-out` when the plot is a cell and `hero-arrows-pointing-in`
when it fills the screen, in the plot's top right corner, in the border colour of
the card. `.icon` from `core_components` is imported into `StudioComponents` for
it — the studio had no icons of its own and should not grow a second set.

### 39.1 Why it felt like seconds, measured

The layout was never the slow part; the round trip was, and it was slow for a
reason particular to this page: `expand` is a `handle_event` that waits behind
the run's own steps. On a stepping page the click was answered **1.7 seconds**
later, and a patch computed _before_ the click landed at **269 ms** and put the
card back where it had been — so the reader saw: nothing, nothing, a flash of
the old layout, and then the card, two seconds in. That is the "multiple
seconds" and it was not a rendering cost at all.

Both are fixed in the browser, in the same place as Escape: the click applies
the full-screen layout itself (14–40 ms), records what it asked for, and
`updated()` re-applies it if a patch that disagrees arrives — for at most four
seconds, so a real answer always wins. Measured after, on the cows surface
experiment page while it was stepping: **expand 40 ms, Escape 28 ms, no
flicker**; on the run page, expand 21 ms, Escape 18 ms, and the same numbers
with the socket cut (29 ms / 12 ms).

Also measured and fixed: `.ChartHover.read()` re-parsed the megabyte of samples
JSON on **every** patch of the box, which a playhead move triggers. It now
parses when the attribute actually changed.

**The JavaScript audit** the same message asked for: `sidebar.js` listens for
Escape on `document` (drawer) and stops nothing; `chart.js` binds pointer,
wheel and dblclick on its own element, `preventDefault`s only the wheel, and
removes its window resize listener in `destroyed`; no hook patches LiveView's
own bindings, none calls `stopPropagation`, and nothing writes to an element
LiveView owns except the two hooks above — which write only the class and
`data-expanded` they are also the ones to restore, and now hold that value
against patches on purpose rather than by luck.

### 39.2 The expanded card had three hundred pixels of nothing in it

Full screen did not make the plot bigger: the card went `fixed inset-0`, the
figure asked for `h-full`, and the plot asked for `flex-1` — and a percentage
height is only as good as the chain it resolves through. Measured on the cows
surface experiment page: card 884x554, figure 852x**510**, svg 834x**432** only
after the redraw; before it, the plot sat at its cell height (208 px) at the top
of a tall white card, which is what the screenshot of the broken state shows.

The height is now `78vh`, taken from the viewport the way the run page's plot
already takes `72vh`, and the card scrolls instead of hiding its overflow. Same
page, after: card 884x554, figure 852x510, svg 834x432, `viewBox 0 0 834 432` —
the picture redrawn for the box rather than a small picture in a large box.

**Escape also answers on `keyup`.** A bare `keyup` with no `keydown` collapses
in 142 ms (measured), which is the case a host that consumes the first event
leaves open. What no page can answer is a host that consumes the key entirely:
VS Code's Simple Browser takes Escape for the editor, which is where the "still
no Esc" reports came from — the same page in a browser tab collapses in 7 ms, and
the control itself is a click either way.

### 39.3 The key that was never arriving, and the class that fought the patcher

**The measurement that changed the answer.** Every "Escape works in N ms" before
this was wrong, and wrong in the way that wastes a day: `page.keyboard.press`
reports success whether or not the page receives anything. With a capture
listener installed first — `window.addEventListener("keydown", e =>
window.__seen.push(e.key), true)` — a trusted "a" and a trusted Escape both
arrived at `__seen === []`. A synthetic `new KeyboardEvent("keydown", …)`
dispatched inside the page collapses the panel in the same tick, which is what
the earlier numbers were seeing. So: in the environment the agent drives, no
keyboard input reaches the page at all; in the reader's window something eats
Escape and, per the reader, reloads the view — nothing in our JavaScript calls
`reload` except `phoenix_live_reload.js:84`, whose page strategy fires on a file
change.

**What a hook may write.** Expanding moved layout by assigning `class` from
JavaScript to elements LiveView renders: a second author of the same markup,
which is how a card could visibly go back to where it was. Full screen is one
attribute now — `data-fullscreen`, rendered by the server and set by the browser
— and CSS reads it: `position: fixed; inset: 0; padding; overflow: auto`, and the
plot's height (72vh on the run page, 78vh on the experiment's cards). The button
renders both heroicons and CSS picks one from the same attribute. Verified with a
synthetic key, which is the only key that reaches the page here: expand →
`data-fullscreen="true"`, `position: fixed`, plot 432 px; Escape → `"false"` in
the same tick, `position: relative`, plot 208 px.

**Still open**, in the order they cost a reader something:

1. Escape in a window whose host takes the key. Nothing in the page can answer a
   key it never receives; the control is a click, and it works.
2. The picture still comes from the server, and on a stepping page a click's
   `handle_event` waits behind the steps — measured 1.7 s, mitigated by a
   four-second hold in each hook, not solved.
3. `.ChartHover` appends its marker and label into `#replay-chart-hover`, which
   LiveView also patches. `AGENTS.md` asks for `phx-update="ignore"` on any
   element whose DOM a hook owns; these two nodes belong in the parent instead.
4. The run page is 4.5 MB: 1.73 MB of polylines and a 1.28 MB `data-samples`
   attribute the server re-encodes on every render.

---

## 35. 2026-11-11: "in parallel" divided the work, and every part has a card

The user's report: _"run in parallel starts a stupid copy of each experiment as a
job. This is absolutely NOT what run in parallel should be doing! We should have
the problem partitioned and thus sped up!"_ — and it was exactly that. The page's
`in parallel N` queued `N` runs and every one of them ran **the whole episode
list**: the record's `episode` field (0…N-1) was written and never read, so a
hundred and forty-episode config at four in parallel was four copies of the same
hundred and forty episodes.

Monty's own answer is `frameworks/run_parallel.py`, and that is what is adopted
(`docs/monty-differences.md` §2.22 has the detail):

- **`Monty.Studio.Partition`** turns an experiment into `n` parts. Evaluation is
  divided by episode (contiguous stretches of the list); training is divided by
  object, with that object's rotations kept together and in order. A part is a
  list of the experiment's _own_ episode numbers — `0, 2, 4` for the second of
  two training objects — because the number is what decides the object, the
  rotation and the draws. `MontyExperiment.run_epochs/2` grew an `{:indices, …}`
  clause for it, and `run_epoch` now walks `{episode, object}` pairs rather than
  a taken prefix of the object list. **A bug this caught**: `planned/2` had to
  clamp the count to the object list's length, or a phase with a budget of nine
  and two objects ran nine episodes.
- **A part is a run**: its own record and its own Oban job, so the queue's limit
  is the parallelism, and Stop, the log and the Replay stay per part. The batch
  id lives in the record's `inputs`, and `RunHistory.parts/1` /
  `parts_progress/1` read it back.
- **A config that trains and then evaluates** gets two waves. `Jobs.Merge` snoozes
  until every training part is `finished`, merges their memories
  (`Monty.Studio.Memories`, per module, Monty's `load_state_dict_from_parallel`),
  writes the merged library and starts the evaluation parts pointed at it. Monty's
  own runner does not do this hand-off (it generates the eval configs from the
  original config), so a partitioned run here evaluates what it trained where
  Monty's would not; §2.22 says so.
- **A training part does not write the library tree**
  (`Learned.keep(..., library: false)`): the library is the merge's to write, or
  the last part to finish would overwrite the merged memory with its own share.
- **The pages** show the parts, which is the pyview dashboard's multi-publisher
  view: `Monty.Studio.Parts` reads each part's cards (label, stretch, status,
  strongest evidence, last pictures, chart) off `RunStream` while it runs and off
  its record once it has settled, and `ExTbpMontyWeb.RunParts` draws them one
  after the other on both the experiment and the run page. A part's card chart is
  one line picture from the strongest module, not one chart per module: a page
  with a chart per module per part would be twenty charts for a five-module
  heterarchy.

**Measured**: `mix test` on the studio, web and MCP suites is 1 097 tests green.
Two traps worth keeping:

- `MIX_ENV=test mix run` writes to the **test database outside the sandbox**, and
  the Reaper settles those runs. Five probe rows of
  `base_config_10distinctobj_dist_agent` left behind by a debug script made three
  page tests fail with "6 runs where 1 was expected" — nothing in the code.
- `Parts.refresh/2` must keep what it has already read (`taken` for the stream,
  `read` for the record): the page polls twice a second, and re-reading four
  transcripts would cost more than the run.

**Still open**: the run page's parts do not follow other parts' broadcasts (they
update on the two-second poll); a batch's merged memory lives in
`Artifacts.dir(batch)/memory`, which deleting the parts does not remove; and
`configs` that name `num_parallel` still have their own Monty-side meaning that
nothing here reads.

## 40. 2026-11-13: a second node, and the things one node's page cannot say

Studio clustering, additive and behind the environment: with `MONTY_CLUSTER=1` (or
a `MONTY_SEEDS` list) a named node starts libcluster, a `Horde.Registry` and a
`Horde.DynamicSupervisor` (`ExTbpMonty.Cluster`), keeps its own folder
(`Monty.Paths.node_root/0` — database, runs, Monty's own output; `data/` and
`models/` stay shared), polls the others every three seconds
(`Cluster.Nodes`, one `:rpc` per peer carrying version, capability tags and the
address a browser can open), and every page follows the list without a reload.
**`docs/cluster.md` is the operator page** — variables, folders, tags, and what is
not spread; this note is only the method and the traps.

The visible parts beyond the chrome: `studio_runs.node` says whose run a row is
(written once, in `RunHistory.start/1`, from the same setting that chose the
folder; `nil` on a node that runs alone, and the runs list shows the column only
when clustering is on); `/runs` has a read-only "On other nodes" panel
(`Cluster.Peers` asks each peer for the runs it has last dealt with, settled or
not, `ClusterWeb.ClusterPeerRuns` draws them, every row links to the
peer's own page for it); and `monty_cluster_nodes` answers an MCP client with the
nodes, their builds and `by_capability`.

**A run goes where its tags say it may.** `ExTbpMonty.Cluster.Placement` turns a
record into needs — `monty`, `world:<its world>` when that world is not the port's
own scene, and anything it pinned in `inputs.capabilities` — and the worker asks
it before it opens a world: perform here if this node offers them; `{:snooze, 15}`
if only a live peer does; perform here anyway if nobody does, which is why a lone
node is untouched by any of it. `Oban.Lifeline` is configured only when clustering
is on, with a **day** as its window: it is time-based, and a `max_attempts: 1`
worker means a job it catches is discarded rather than re-run — so a shorter window
would discard a live long run's job and take its Stop button away, while the record
is settled by the reaper either way.
`studio_runs.node` follows the claim rather than the asking: with one runs table
the two differ, and the node a reader has to open for a run's steps and files is
the node that performed it.

**Four traps, all found by a test or a browser, all now pinned:**

- `use Phoenix.LiveView, on_mount: [Mod]` runs _nothing_. `before_compile` builds
  `[on_mount: attr_list] ++ opts` and `__live__/0` reads the first match, so the
  accumulated attribute list shadows the option. Use the `on_mount {Mod, :arg}`
  macro — one line in `ex_tbp_monty_web.ex`, and no page has to know.
- A `LiveComponent` has no `handle_info/2` (its own docs say the parent must
  receive and `send_update/3`), and `Layouts.app` only sees what a page passes it,
  so a footer cannot read a page assign. Hence the one mount hook handing the
  broadcast to `cluster-badge` and `cluster-nodes` by id; `send_update` for a
  component a page does not render is a no-op, which is why one hook serves both.
- **Phoenix's pubsub is the distributed one.** `"studio_runs"` reached every node,
  so a peer's run appeared in this node's list (with Stop and Delete beside it) and
  the experiment page started following a run whose steps it never receives. The
  guard is a fact, not a policy: `RunHistory.exists?(id)` — true with a file per
  node and true if the cluster ever shares one runs table.
- `Nodes.snapshot/0` answered by `GenServer.call`ing the poller, which is inside
  an `:rpc` to a peer while it polls: a page waits behind the slowest peer, and a
  big enough cluster puts that past the call's timeout, which is a crash for
  reading a list. It reads the last poll from `:persistent_term` instead.

**Measured**: `mix test` 2 980 tests green (67 properties), `scripts/quality.sh`
green, and two nodes on one machine (4211/4212) checked in a browser: both footers
said "2 nodes", both settings pages listed both nodes with their own tags and both
tag groups, the peer's name was a link to the address it advertised, and stopping
one node moved the footer **and** the list to one node with no reload to the page
that was open. CI run `43344779545` completed success, Windows desktop job
included.

**Still open, and both are a decision rather than a fix**: (1) one runs table for
the whole cluster (`DATABASE_URL` at one Postgres — the pages already behave) or a
merged view over each node's file. **The one-table half was measured**
(2026-11-13, nodes on 4231/4232 over a scratch database, since dropped): with only
node2 declaring `world:mujoco`, a MuJoCo run asked for through node1's MCP
endpoint was answered `{:wait, 15}` by node1, taken by node2 (`attempted_by
node2@127.0.0.1`, still on attempt 1) and finished with `node =
node2_127.0.0.1`; with node2 stopped, node1 performed the same run itself. Both
nodes' `/runs` showed one list with the `node` column, and node1's "On other
nodes" panel listed node2's finished run. So the queue spreads **by capability**
today; what is left of (1) is only the node that keeps a file per node and still
wants the others' runs in one list — the merged view. (2) A part writes its files
and publishes its steps into the memory of the node performing it, so a part on
another node needs either a filesystem the owner can read or an explicit transfer
of what it produced; that is the next change. The one gap that was named — a run
waiting for another node looking like any run that is simply queued — is closed:
the run's page draws `waits for <node>` beside its state
(`Cluster.Placement.awaiting/2` answers it, `StudioComponents.waiting_for/1`
draws it, and a node that runs alone draws nothing).

One loose end from the same day, unrelated to the cluster: `RecordingEpisodeTest`
failed once in eight full runs (21 steps against a recording of 27, the port
concluding early), passes alone, and is written up in MemPalace under
`suspected-issues` — the candidate is an unseeded RNG where the episode's own
stream should be used.

**Two candidates measured and killed (2026-11-13, `a3cf660`+).** The vote round
was the better guess than the RNG: `Barrier.run/2` _drops_ a vote that misses its
deadline, so a loaded machine would decide the answer. It is not, for this case:
five runs against eight busy cores reached 27 every time, and so did a run with
the deadline set to one millisecond, where every vote is dropped — the episode has
one learning module and no cross-module voting (`lm_to_lm_vote: %{module_id =>
[]}`), so its votes cannot change it. The RNG candidate is still unmeasured. What
did land is the faithfulness half: Python's vote round has no deadline at all, so
this case now runs with `vote_timeout: :infinity` and its parity claim no longer
has a machine in it.

## 41. 2026-11-13: split runs, and what is left of them

This session was the division of a run across nodes, taken from "the row exists"
to "a reader can tell what happened, and a stop reaches every part". It was
driven by the user reading the running application and the assistant's own
reports, in this order: _a run on two nodes must be distinguishable by part,
and a cancellation must reach every node involved_; _now that we have plugins,
can we RPC them properly, and do not build self-reinforcing message loops_;
_how ready are we for two-node clustered experiments_; _the run page repeats
itself and its division line is unreadable_.

Every claim below is either a commit, a file and line, or a number produced by
running the thing. Where it is a design that has not been built, it says so.

### 41.1 What landed

Two pairs of hands worked in this tree. The division, the stop and the run page
were mine; the plugin policy and the cluster view were the other agent's. Both
sets are listed, because the tree is the state, not my half of it.

| Commits                                                                     | What it made true                                                                                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `60551a4`                                                                   | a run can be told to be split: parts recorded per node, a stop asked of the whole cluster                                                                                                                                                                                                                                                         |
| `859320c`                                                                   | `studio_run_parts` — the row that says which node has which part, and what became of it                                                                                                                                                                                                                                                           |
| `ba13518`                                                                   | the dialyzer errors the part rows had introduced                                                                                                                                                                                                                                                                                                  |
| `c3500bd`                                                                   | deleting a run deletes its parts (SQLite cannot add the foreign key, so the cascade is written by hand)                                                                                                                                                                                                                                           |
| `4190ee7`                                                                   | a node whose database is behind says so at boot instead of failing on the first query                                                                                                                                                                                                                                                             |
| `04ce380`, `3c88340`, `26a96dc`                                             | the stop that did not reach the parts (41.2), and the reaper that closes a division nobody will close                                                                                                                                                                                                                                             |
| `b035d70`                                                                   | the MCP report carries the division, so an assistant can answer "which node had part 2"                                                                                                                                                                                                                                                           |
| `7246005`, `e792631`, `e18f5be`, `0d8168d`, `9521023`                       | the run page: six part states documented, the title says the steps, the parts read as a sentence, Inputs stops repeating Configuration                                                                                                                                                                                                            |
| `b40dc3d`                                                                   | a plugin is called only on a node whose capabilities satisfy its `needs`                                                                                                                                                                                                                                                                          |
| `eb2a9b1`, `c1edce0`                                                        | `MONTY_STUDIO_CONCURRENCY` — how many runs a node may perform at once — and the assistant told what the deployment can do                                                                                                                                                                                                                         |
| `d343995`                                                                   | a step reads no setting (41.4)                                                                                                                                                                                                                                                                                                                    |
| `8607ce2`                                                                   | a failed part keeps the steps it took, and says how many in its sentence                                                                                                                                                                                                                                                                          |
| `bdf681d`, `7107243`                                                        | a node says where it writes a run's files; an older peer is still an entry                                                                                                                                                                                                                                                                        |
| `13d0d6b`, `4f979a7`, `e0845f4`, `6b98cbe`, `69c16b6`, `0a5b46e`, `720655b` | the other agent: a node is a server whose plugins are pieces, a capability names the modules that provide it, a run's motor policy can be another node's plugin, the sample plugins named under the host that owns them, a plugin-defined experiment a node can start, a policy that moves, and a policy per run so two episodes cannot share one |
| `1545a45`, `21ab5bc`                                                        | an episode's line stays inside its own band, and the zooming case that still named the old axis (41.1)                                                                                                                                                                                                                                            |

`1545a45` came in after `9521023` and left `main` red on one case — CI's `test`
job failed on it, which is the second, independent confirmation that the case
was the broken thing and not the chart; `21ab5bc` is the repair. The chart now
gives every episode one x unit of its own so two episodes cannot share a column,
which makes two episodes of two steps _four_ columns — and the run page's
zooming case still named the old extent in three assertions (`steps 0–2`, `of
2`). The chart was right and the assertions were incidental numbers that had
quietly become false, so they now say `steps 0–3` and `steps 1–2 of 3`, with the
commit that moved the axis named in the comment. **A number a test asserts on a
drawing is a specification of the drawing; when the drawing changes on purpose,
the number is what moves.**

### 41.2 The stop that never reached the parts

The bug the user suspected twice, and it was real both times. A divided run
performs its parts in `Task.async_stream` (`lib/monty/studio/jobs/run.ex`), so a
part runs in a task the job did not spawn as a child — and `Run.stop/1` sent its
`:stop` only to the pid registered under `{:studio_run, run_id}`, which is the
job. The job was blocked awaiting the tasks that the stop was meant to interrupt,
so the message sat unread in the job's mailbox and the run finished as if nothing
had been asked.

Two things fixed it, and the second is the one that matters:

1. `stop/1` messages **every** worker: the job, plus `working_on/1`, which reads
   the part tasks out of the record and messages each pid once.
2. `run_wave/4` refuses to start a part when `stop_requested?/0` is already true,
   so a part that was waiting its turn is never started after the stop arrived.

Measured, not inferred: a two-part run on one node, stopped eight seconds in,
ended `run=stopped` with **both** parts `stopped`, each at 30 steps. Before the
fix the same script produced `run=finished` with two `finished` parts.

The part states are now six — `queued running finished failed stopped skipped` —
and `Monty.Studio.RunHistory.Part.ended?/1` names the closed ones so no caller
has to keep the list in its head. Who closes each one is in `docs/cluster.md`.
The reaper settles the rest: `abandon/1` calls `RunHistory.settle_parts/1`
before `RunHistory.finish/3`, so a node that dies mid-division leaves
`skipped`/`failed` rows rather than `running` ones forever.

### 41.3 A plugin is called only where it can be served

`RemotePolicy.among/3` asks each host in turn, and now also asks whether the
host's capabilities satisfy the plugin's own `needs`
(`lacking/2` → `Capabilities.offers?/2`), and refuses with one plain sentence
when they do not. The refusal used to come back nested in a tuple, so the caller
that compared it with `=~` raised instead of reporting. One sentence, one layer.

`needs` itself is still advisory _in the package_: `ex_monty_plugin` does not
enforce it, one caller here does. That is written in `docs/plugins.md` item 3
rather than left as a pleasant assumption.

### 41.4 What a reader sees now, and what made it slow

The run page's Inputs panel repeated the Configuration panel: `eval_epochs`,
`learning_modules`, `sensors` and `train_epochs` are names the configuration
panel already gives in words. `inputs/1` now rejects those
(`@stated_in_configuration`) and anything blank, and the run I opened in the
browser drew seven rows — `defined_by`, `episodes`, `motor_policy`, `parallel`,
`parts`, `seed`, `world` — none of which the configuration states. The division
reads as one sentence there too: "2 parts, 70 episodes (eval) each", instead of a
map printed by `inspect`.

That last line was `stream=ad68fe99-…` and `parts index=0 of=2 phase=eval
phases=eval=0, 1, 2` in the user's own words, and he was right: it was the
input map, not the division.

Getting there turned up a real defect. `assign_replay/2` read
`Settings.get("run_refresh_ms")` on **every step** under a comment saying it was
read once, which is one database query per step of every replay. CI caught it as
a single failing case ("a step costs the database nothing") that passed in the
suite and failed three times alone. The way through was a temporary test that
attached telemetry to the repo's query events and printed **which process** made
each one: the view made `studio_settings` (a step) and `oban_jobs` (its own 2 s
poll). `Map.get_lazy` fixed the first; the test now drives the poll itself. A
`show_poll_ms` setting was added to test the second hypothesis, disproved, and
reverted — the record of that is here so it is not tried again.

The lesson is not "the setting was slow". It is that a case which passes in the
suite and fails alone is _information_: something in the suite was hiding a
query, and the case was right.

### 41.5 What is left, in the order I would take it

**Parts across nodes — the one big remaining piece.** Everything needed to
_decide_ is in place and nothing dispatches. A part is still performed by the
node that owns the run.

- Prerequisite, done: `Cluster.Nodes.identity/0` carries `artifacts:` and
  `shares_run_files?/2` (`lib/ex_tbp_monty/cluster/nodes.ex`) is true only when
  two entries name the same binary directory. A peer that writes its files
  somewhere the owner cannot read is not a candidate, and now can be told apart.
- Choose peers with `Nodes.snapshot()`, keep those with
  `shares_run_files?(here, entry) and entry.alive`, and assign parts round-robin.
  No qualifying peer means the run is performed by the owner alone — a fallback,
  not an error, because that is what happens today.
- The entry point is `Run.perform_part(run_id, part_index)`, called over `:rpc`,
  reusing `opened_for/1` so a peer never opens the world itself.
- **The decision still open** is how a part's steps come back. Two shapes:
  (a) the `:rpc` reply carries them — simple, and buffers a few megabytes per
  wave; (b) the peer writes `runs/<run_id>/parts/<index>.log` into the shared
  directory and the owner reads them in part order — bounded memory, survives a
  restart, and needs a format. I would build (b) and exercise it on **one node
  first**, with the owner writing its own parts that way too, so the reader is
  tested before any `:rpc` exists. The tests that specify it, in that order:
  parts stay on the owner when no peer shares the directory; a part handled by a
  peer is recorded with that peer's name in `studio_run_parts.node`; the run's
  transcript is the parts' transcripts in part order whichever node wrote them;
  a peer that dies mid-part fails that part and only that part.
- Then: stop propagation to a peer (the same `Run.stop/1` message over `:rpc`),
  refusing a peer on a different `version`, and the run page showing which node
  is still to answer.

**The run list across per-node databases.** `Peers.runs_on/3` exists and the list
does not use it, so a divided run's parts are visible only from the node that
owns the run's row. This is the cluster view's area — coordinate before touching
`cluster_nodes.ex`, `cluster_peer_runs.ex` or `settings_live.ex`.

**`route/4` in `ex_monty_plugin`.** Enforcement of placement `:owner_only`,
answer discipline and timeouts, and routing learning modules, not only episode
steps, through a `:pg` scope. It publishes a version, so it wants the user's
nod before it is written.

**Two wirings nothing tests.** `collect/2`'s error branch that passes a part's
step count into `part_failed/3` — no experiment can be made to fail on purpose,
so the case waits for an injected failure. And `config/runtime.exs`'s parse of
`MONTY_STUDIO_CONCURRENCY`, which no test loads: verified by booting three ways
(unset → `[studio: 2]`, `=3` → `[studio: 3]`, `=zero` → raises naming the
variable). The parse is guarded by `Application.get_env(:ex_tbp_monty, Oban,
[])[:queues]` because otherwise it overrode `queues: false` in the test
environment and failed two cases of `ExTbpMonty.Mcp.StudioTest`.

**One loose end from before this session**, unchanged: `RecordingEpisodeTest`
failed once in eight full runs (21 steps against a recording of 27), passes
alone, written up in MemPalace under `suspected-issues`; the candidate is an
unseeded RNG where the episode's own stream belongs.

### 41.6 Loops, since the user asked twice

PubSub here is the cluster-wide adapter and has no de-duplication key, so a relay
that forwards everything it receives forwards its own forwarding, and it is
unbounded rather than merely wasteful. `docs/plugins.md` has the five rules under
"The loop rules", each with what breaks if it is broken: a node answers a peer
from its own state and never asks another node while answering; one publisher per
fact, and a subscriber re-renders without re-publishing; an answer is data and
nothing in a reply may be read as a request; no retry without a deadline and none
at all of a call that changes state; nothing reaps on an event it publishes. Read
them before adding a topic or a call that crosses nodes.

### 41.7 Working agreements for the next pair of hands

- **This tree is shared.** Another agent commits in it. Never `git add -A`;
  stage your own files. When a file is both of yours, take your hunks with
  `git diff -U3`, write them to a patch and `git apply --cached` — I did exactly
  that for `run_history_live.ex` while the other agent's changes sat unstaged in
  it.
- **A tree that does not compile may be someone mid-save.** Twice this session a
  file was broken by work that existed nowhere else (`run_partitioned`'s
  three-tuple return left a two-tuple clause unmatched; a comment swallowed a
  `defp`). Diagnose it, write the diagnosis down, and do not `git checkout --`
  another agent's uncommitted file.
- **Re-run a failure before believing it.** A `--seed 7` run showed eight
  phantom `ExperimentLiveTest` failures because the tree was being compiled while
  it was written; the re-run gave 353 passed.
- **CI on `main` does not cancel a running run.** `concurrency` in
  `.github/workflows/ci.yml` sets `cancel-in-progress` to the expression
  `github.ref != 'refs/heads/main'`, so on main a _pending_ run is replaced
  (reported `cancelled`) and a _running_ one finishes — 40–60 minutes once the
  desktop leg is in it, with `timeout-minutes: 60`. Pushing often on main queues
  behind that tail; `gh run cancel <id>` when you only need the fast jobs.
- **The Windows desktop leg is the unreliable one**: no failing step on
  `720655b`, and two hangs earlier the same day. A green `test`/`quality` job on
  the same commit is the signal to look at; a lone desktop failure is not.
- **Never kill a BEAM that was not started here.** The user runs the app from
  `process-compose`; a `mix phx.server` on the same port is not yours to stop.

### 41.8 Verify it

```
./scripts/reformat.sh                    # mix format, then prettier over md/js
./scripts/quality.sh                     # what CI runs: lint, workflows, cover, complexity
MIX_ENV=test mix dialyzer                # the separate types job; ~5 s, not in quality.sh
```

Measured at this hand-over: 3 088 passing (67 properties, 3 021 cases), worst CRAP 29.85,
dialyzer 0 errors, CI success on `9521023`.

## 42. 2026-11-13: a run's duration is its work, and the number of runs a node takes is now a test's

Two items §41.5 left in the list below the division — one a defect the
optimisation hand-over had recorded and nobody had fixed, one a wiring nothing
tested. Both are small, and both were statements the application made that were
not true.

### 42.1 `started_at` was the moment somebody asked

`RunHistory.start/1` stamped `started_at: DateTime.utc_now()` when a run was
**asked for**, and `finish/3` took the duration as `finished_at − started_at`.
So every run's duration included its wait in the queue, and `mark_running/1` —
the worker's own word that it has the run in hand — wrote the status and the node
and left the clock alone. Measured in the dev database: `started_at` was 13–26 ms
**before** `inserted_at` on every row, which is the row being written after the
clock was read.

The shape `optimisation-handover.md` named is the one that is there now:

- `start/1` stamps nothing. The row's own `inserted_at` is when it was asked, and
  that is also the clock a queued run's wait is counted from.
- `mark_running/1` writes `started_at` — the claim is the start, and the clause
  that answers a second claim unchanged therefore keeps the first instant.
- `finish/3` is untouched: the number it keeps is now the work.
- `Duration.of_run/1` and `elapsed_us/1` answer two clocks: a `queued` run gets
  the wait measured from `inserted_at`, a `running` one the elapsed time from
  `started_at`, a closed one `duration_us`.
- The run page says **"waiting for 40s since 23:33:19"** for a run no worker has
  claimed. It used to say "started 23:33:19, 40s", which is the page saying a
  worker is on a run that is still waiting for one.
- `mix monty.run --record` claims its own record (`RunHistory.mark_running/1`)
  before it steps. The task works in its own process, so there is no queue
  between asking and working — and a headless run left saying `queued` for six
  minutes was the record disagreeing with the run it was writing.

Cases: `run_history_test` "keeps the duration of its work, not of the wait in the
queue" (asks for a run, backdates `inserted_at` an hour, claims it, closes it —
the hour must not be in the duration) and the amended "says running only when a
worker claims it" (no start while queued, a start after the claim, none on the
second claim); `duration_test` "is the wait of a run nobody has claimed yet" and
"is a dash for a queued run with no asked-at clock"; the run page's "a run nobody
has claimed yet says how long it has been waiting"; the experiment page's
"a run that is still going says how long it has been going" now sets the status
as well as the clock, because a `queued` row no longer has one.

### 42.2 `MONTY_STUDIO_CONCURRENCY` is parsed by something a test can call

The parse lived inline in `config/runtime.exs`, so its three answers — a count,
the default, and a refusal — were verified by booting three ways and by nothing
else. It is `Monty.Studio.Jobs.studio_concurrency/1` now: unset or empty is two,
a whole number of at least one is itself, and anything else raises a message that
names the variable and the value it read. `runtime.exs` keeps the guard that
matters more than the parse — "only where a queue runs", so the suite's
`queues: false` cannot be undone by a lever — and one line calls the function.

### 42.3 Two traps, both about believing a run

- **A duration written against the wall clock in a test is a flake.** The first
  case asserted `of_run(queued) == "40s"` for a run asked for forty seconds
  earlier; the full-suite run read `40.6s`, because constructing the instant and
  reaching the assertion took 600 ms. The quantity is what the behaviour is
  (`elapsed_us` within five seconds of forty million), and the string is
  `humanize/1`'s business, which has its own cases.
- **A full gate run in this tree reports failures that are not there**, because
  another agent is writing in it. Two attempts were needed. The suite came back
  `3101/3102` twice; both times the red case was the other agent's newest one
  (`run_history_live_test.exs`, written and committed while the suite compiled),
  and re-running that file gave **102 passed**. The complexity step failed with
  `worst 20.00, 0 function(s) above 20` — which is not a threshold failure at all:
  `ExCrap.Report.failing?/2` is true for a row whose `status` is `{:error, _}`, so
  a module the export no longer matched was _unscorable_, not high. Re-ranking the
  export kept from the completed run gives **exit 0 for all three trees** (worst
  20.00 `lib/monty`, 20.00 `lib/ex_tbp_monty`, 29.85 `lib/ex_tbp_monty_web`, the
  same 29.85 §41.8 recorded). `mix crap --coverdata /tmp/<copy>.coverdata` is how
  to keep a ranking from being deleted by the other run between the two steps.

### 42.4 What is left

Unchanged from §41.5, in its order: **parts across nodes** (the decision still
open is how a part's steps come back; (b), a file per part in the run's own
directory, is the one to build first and to exercise on one node); the run list
across per-node databases (the cluster view's area — coordinate first); `route/4`
in `ex_monty_plugin` (wants the user's nod); and the `RecordingEpisodeTest` flake,
still the same candidate (an unseeded RNG where the episode's stream belongs).
Of the two untested wirings §41.5 named, `MONTY_STUDIO_CONCURRENCY` is closed
above; **`collect/2`'s error branch still waits for an injected failure**.

### 42.5 The gate

`./scripts/quality.sh --fast` green; `mix cover` **3 101 of 3 102** with the one
red case re-run alone to 102 passed (42.3); the three CRAP trees exit 0 against
the export that run left; `MIX_ENV=test mix dialyzer` 0 errors.

## 43. 2026-11-13: a part of a run is performed by the node that can be given it

§41.5's "one big remaining piece", taken as far as it goes without a second
machine in CI: a divided run's parts are now placed on the nodes that can be given
one, each part's steps come back through the run's own directory, and a stop
reaches a part a peer is stepping.

### 43.1 What landed

| Where                                                  | What it made true                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Monty.Studio.Partition.hosts/3`                       | the decision: alive, offering the run's tags (`Placement.candidates/2`), writing the run's files where this node reads them (`Nodes.shares_run_files?/2`), running this build — then round robin, this node first. No qualifying node means every part here, which is a run performed as one node has always performed it. |
| `Artifacts.part_path/3`, `store_part/5`, `read_part/3` | one part's steps as a file in the run's directory — `<run>/parts/<phase>-<index>.jsonl`, one step a line as `[entry, moment]`.                                                                                                                                                                                             |
| `Jobs.Run.keep_steps/2`, `store_parts/2`               | every part writes that file when it ends, and the run's transcript is read from those files in part order (`part_transcript/2` falls back to the stream for a part this node performed whose file could not be written).                                                                                                   |
| `Jobs.Run.perform_part/3`, `run_part_there/4`          | the part on a peer: `:rpc.call(host.node, __MODULE__, :perform_part, [record, part, memory], :infinity)`. The record travels because a peer has no row for a run it does not own.                                                                                                                                          |
| `RunHistory.part_started/3` from the owner             | the part row names the node that performs it, written where the row lives.                                                                                                                                                                                                                                                 |
| `Jobs.Run.stop_part/1`, `stop_parts_there/1`           | a stop cast to the node each part was given to; a node without that part answers `:not_found`, which is why it is a cast.                                                                                                                                                                                                  |
| `Artifacts.root/0`, `Nodes.identity/0`                 | one answer for "where do a run's files go": `:studio_artifacts_dir`, else `MONTY_ARTIFACTS_DIR`, else `priv/studio_runs` — and the identity reports _that_, so the sharing question is about the directory the files are actually written to.                                                                              |
| `step_wave/4` (repair)                                 | a part that failed ended the wave with a `CaseClauseError` — the error branch still matched the three-tuple the results had before they carried a step count. The run now fails with `part 1 of 2 stopped: …` and the part's row says how many steps it took.                                                              |

### 43.2 Verified on two nodes, not inferred

Two VMs (`probe@127.0.0.1` and a `:peer` as `node2`), one `MONTY_ARTIFACTS_DIR`,
each with its own database, the run asked for from the first.

- `Partition.hosts` answered `[{0, "probe_127.0.0.1"}, {1, "node2_dam2.fritz.box"}]`.
- The run finished with **8 steps** — four from each node — and its transcript is
  part 0's episodes then part 1's, in order: `{0,0,0}, {0,0,1}, {0,1,0}, {0,1,1},
{1,2,0}, …`. Both part rows read `finished`, with the performing node's name and
  `4` steps.
- A second run of eight episodes, stopped 600 ms in: `stop answered :ok`,
  `run=stopped`, and **both** parts `stopped` at eight steps — the peer's part
  included. That is `stop_part/1` reaching a process in another VM's registry.
- The same tree with nothing shared refuses the peer: hosts answered both parts
  for this node, which is the fallback working rather than the fallback being
  reached by accident.

### 43.3 Traps this found

- **A 3-tuple where a 4-tuple now travels is a crash, not a test failure** — see
  the `step_wave/4` row above. It was found by the two-node check (a peer that
  could not start), which is the only way to make a part fail on purpose today:
  there is still no `collect/2` test for that branch, but the branch is now known
  to work, and the failure it produces is a sentence with the part's number.
- **Two levers, one fact.** `:studio_artifacts_dir` (a release sets it, a test
  points it somewhere temporary) and `MONTY_ARTIFACTS_DIR` (the deployment's)
  named different directories in dev, while `Nodes.identity/0` reported the second
  and the files went to the first. `Artifacts.root/0` is now the single answer and
  the identity reports it.
- **Probe plumbing, for the next pair of hands** (each cost a run):
  - an anonymous function compiled into a `mix run` script cannot be sent to a
    peer — it exists on one node. Use an MFA, or
    `Code.eval_string` on the peer.
  - a `start_link` made _through_ `:rpc` dies with the call that made it; start it
    inside `Code.eval_string` and `Process.unlink/1` it.
  - a peer VM has no Mix, and `phoenix_live_reload`, `esbuild` and `tailwind` are
    Mix plugins: a peer running the dev tree must be given the runtime children
    it needs (`Phoenix.PubSub`, `ExTbpMonty.Core.Supervisor`, `RunStream`,
    `RunStream.Pictures`, `RunWriter`) rather than the whole application.
  - `:peer.start_link(%{longnames: true})` names the node after the machine
    (`node2@dam2.fritz.box`), not `127.0.0.1`; take the name from the return
    value instead of guessing it.
  - a peer mid-boot answers `version: "unknown"` — `alive` is `is_binary(version)`,
    so it looks alive — and `Partition.hosts/3` correctly refuses it until it has
    the real version. A check that waits for "two alive nodes" waits for the wrong
    thing.

### 43.4 What is left

In the order I would take it, none of it started:

- **The run list across per-node databases** — the cluster view's area
  (`cluster_nodes.ex`, `cluster_peer_runs.ex`, `settings_live.ex`); coordinate
  before touching them. `Peers.runs_on/3` exists and the list does not use it.
- **A part's live steps do not cross** (`docs/cluster.md`): a page on the owner
  sees a peer's part when the part ends and its file is read; PubSub already
  carries the events, and what would need an `:rpc` is a late page's catch-up read.
- **`route/4` in `ex_monty_plugin`** — placement `:owner_only`, answer discipline
  and timeouts, learning modules through a `:pg` scope. It publishes a version, so
  it wants the user's nod.
- **`collect/2`'s error branch has no test.** It has now been _run_ (43.2, by a
  peer that could not start), and a test still wants an injected failure.
- The `RecordingEpisodeTest` flake, unchanged: the vote deadline and the RNG are
  both still unexplained (the deadline is measured out — see §40), and the case
  now takes the deadline out of its own fidelity claim.

### 43.5 The gate

`./scripts/quality.sh --fast` green; the touched suites 96 cases (artifacts,
partition, run, cluster nodes); full `mix cover` and dialyzer run below — the
numbers are the ones in the summary of this section when it was pushed.

## 44. 2026-11-13: a part of a run is an owner — claimed, leased, fenced

A reader of the clustering direction asked the question this section answers, in
the TBP forum:

> "…making ownership explicit and recoverable: use a distributed registry such as
> Horde with consistent hashing for assignment, persist each experiment's
> checkpoint before handoff, and have nodes advertise protocol/version
> capabilities. That way a node loss can reassign partitions without silently
> duplicating runs, and networked sensor, motor or learning processes can reject
> incompatible peers. Are you treating partitions as stateless workers or as
> resumable experiment owners?"

### 44.1 What changed

| the ask                   | the answer in this tree                                                                                                                                              |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ownership explicit        | `studio_run_parts.claim` / `.claimed_until` / `.node`, written by `RunHistory.claim_part/3` before the first step                                                    |
| recoverable               | the lease lapses (`Monty.Studio.Claim`), `lapsed_parts/1` lists what a lost node left, and `run_part/5` gives it to the next candidate                               |
| no silent duplication     | the claim is a compare-and-set: a second node is refused with `{:held, node, until}`, an ended part with `{:settled, status}`                                        |
| fenced writes             | `RunHistory.release_part/3` and `abandon_part/1` match the token; a holder that lost its part gets `{:error, :not_owner}`                                            |
| capabilities and protocol | `ExTbpMonty.Cluster.Protocol` (`monty-cluster/1`) is advertised in `Nodes.identity/0`, required by `Partition.hosts/3`, and enforced at the door of `perform_part/4` |

Horde with consistent hashing was **not** taken literally, and `docs/cluster.md`
says why: Horde's ring re-maps on membership change, which is the one moment a
part being performed must not move. Its registry and supervisor remain in the
tree for named processes, and `:pg` for the plugin registry.

### 44.2 The traps, which cost the most time

- **A claim cannot be renewed by a node that is blocked.** The first shape of this
  had the owner call `:rpc.call(..., :infinity)` and renew "around" it — which is
  not a thing. `Jobs.Run.await/3` runs the part in a `Task` and yields at a third
  of the lease, renewing between yields; that wait is also where a lost lease stops
  the work.
- **A nil claim has to be a first-class case.** A run of one part has no division
  and so no row to claim, and every claim function is `nil`-tolerant
  (`renew/1`, `release/3`, `forget/1`). The compiler is strict about this: it told
  me `claim_node(nil)` was unreachable, because a nil claim can neither lapse nor
  be refused.
- **A released part keeps no token.** `release_part/3` clears `claim` as well as
  `claimed_until`: a stale holder then matches nothing at all, and "a settled part
  is nobody's" is one field rather than a status the fence has to remember.
- **`coalesce` may not be written in one `update_all/3`.** `started_at` has to keep
  the first instant a part was held; `fragment("coalesce(started_at, ?)", ^moment)`
  does not compile there, so the claim writes it in a second statement guarded by
  `is_nil(started_at)`.
- **`Partition.hosts/3` now answers a list per part**, not one node. Everything
  that destructured `{part, host}` had to change: `step_wave/4`, `hosts_for/2` and
  `stop_parts_there/1`. The stop path failing as a `BadMapError` under test is what
  found the third one.

### 44.3 What a part does now, and where it stops

**A part writes as it goes** (`7922172`). At every episode boundary `keep/2`
appends what it took to `<run>/parts/<phase>-<index>.jsonl` and one line to
`<phase>-<index>.progress`; `Artifacts.progress/3` counts the second and
`remaining/2` drops that many episodes from the front of what the part was given.
So a part given to a second node after its first went silent **picks up at its
first unfinished episode** — the transcript keeps the steps of both attempts in
order, and the episodes that finished are not taken twice.

Two boundaries on that, both deliberate:

- **training parts restart.** A part's episodes build on each other — the graph
  one made is the graph the next extends — and the model that took them did not
  travel with the part. Resuming a training part needs a model checkpoint, which
  is a different piece of work and is not claimed here.
- **the marker is per episode, not per step.** One append an episode is cheap; a
  step is not the unit anyone can resume at, because an episode's beliefs are the
  model's, not the transcript's.

### 44.4 What is left

- **A model checkpoint, for a training part** (above): the one kind of part that
  still starts its stretch again.
- ~~A sweep for the recovery path~~ — **done, §46**: the boot sweep re-queues a
  run whose division has something done and something left.
- ~~`flyverse_plugin` in CI~~ — **done, `207a355`**: `Mix.Tasks.FlyversePlugin.Engine`
  builds the crate from `mix compile` (an artefact that is absent or older than
  the crate is rebuilt), and the `example` job's matrix now runs both examples.
  Its cache grew `priv/native` and the crate's `target/` under a `nif-1` key,
  because a restored `_build` that believes it is current while the ignored `.so`
  is missing is the state in which every call raises "not available".
- The examples are not decrapped, and the reason is measured rather than assumed
  (2026-11-13): `mix test --cover` in each of them already carries a **90%**
  threshold and neither reaches it — `example_plugin` **84.78%**, `flyverse_plugin`
  **74.37%**. A CRAP ranking over either would therefore be a report about missing
  coverage rather than about shape, so the prerequisite is coverage; the ranking
  needs `ex_crap` beside the export in each example and a threshold this estate has
  not picked yet.
- The run list across per-node databases, a part's live steps not crossing, and
  `route/4` — unchanged from §43.4.

### 44.5 The gate

`mix compile --warnings-as-errors` clean, `mix lint` exit 0 (now including
`examples/*/lib` and `examples/*/test`), `mix credo --strict` no issues over 539
files; the touched suites green — claim 9, run_history 68, partition 17, run 44
(the recovery cases and the two resume cases), indices and pages 67, artifacts 27.
CI's own answer, from the runs of these commits: `lint`, `types`, `test 2/4`,
`test 3/4`, `test 4/4` and the `example_plugin` leg all green; the only reds were
a facet list this change made stale (fixed in the next commit) and
`flyverse_plugin`'s crate, which is §44.4's first item. Dialyzer runs in CI's
types job.

## 45. 2026-11-13: a run is told why in words, and the CAD scene's gate

### 45.1 The leak, which is the part worth reading

A run against `flyverse_plugin`'s policy failed, and the reason its page showed
was:

```
run failed at step 166 after 1094 step(s): the policy
flyverse_plugin.lif_steering on flyverse_plugin@127.0.0.1 stopped answering:
{:noproc, {GenServer, :call, [#PID<26785.216.0>, {:call,
%{__struct__: FlyversePlugin.Policy, sensor_id: nil, agent_id: "agent_id_0", …
```

`GenServer.call` exits with **the message it was sending**, and for a policy that
message holds the policy and the observations it was deciding on. `RemotePolicy`
built four of these sentences with `inspect(reason)`, `PluginExperiment` a fifth,
and each one travelled — unchanged — through `Failure.explain/1` (which strips
the `** (ArgumentError)` banner and keeps the message) into the run's `reason`,
its own log, and the page. `Monty.Studio.Failure`'s whole mandate is that a
record never answers "why did this stop" with a dump; the sentences were written
before anyone asked it.

What landed (`80a78ec`):

- `Failure.lost/1` — an exit reason as a sentence: a process that is gone, a node
  that left, a node still thinking, an exception's own message. Everything the
  reason carried is dropped with it, and an unknown shape still gets a sentence
  ("it stopped without saying why") rather than a term.
- `Failure.reply/1` — an unexpected reply by its tags: `ok, a FlyversePlugin.Policy`
  says which message went unanswered without pasting a camera image.
- `RemotePolicy`'s four `catch :exit` sites and its three `answered …` sites, and
  `PluginExperiment`'s pair, all use them.
- `Jobs.Run`'s part log line pasted the _pair_ `Failure.crashed/3` keeps — the
  sentence **and** the traceback that the page folds out under "technical
  details". `said/1` now takes the sentence and leaves the trace where it is
  kept; a division's own tags (`{:unclaimable, {:held, node, until}}` and
  friends) are still inspected, because they are a node and a time, not a
  payload.

**That last clause was wrong, and it took a test to say so.** A node and a time
inside a term is still a term: a part another node is performing wrote
`part 1 of 2 failed after 0 step(s): {:unclaimable, {:held, "peer@10.0.0.7",
~U[2026-11-13 22:10:59Z]}}` four times over — in the log line, in the part's
recorded failure, and twice in the run's closing sentence. `Failure.part/1` is the
answer: one clause per thing that can befall a part, each in words ("it is in
peer@10.0.0.7's hands until 22:10", "no node could take part 3", "peer@10.0.0.7
stopped performing it: its node left the cluster"), and `Failure.unclaimable/1`
was reworded to a phrase that composes ("in …'s hands until …", "already ended
(finished)") rather than a sentence with its own subject. `said/1` is gone: one
vocabulary, in `Failure`, and a log line asks it. The case that would have caught
this is now in the suite — a divided run whose first part a peer holds, asserting
whose hands the log names and that the log holds no `{:held` and no `~U[`.

Three cases state it, and the first fails on the old code: the message holds no
`GenServer`, no `#PID` and no struct; `start/1` answers the same sentence; and a
reply carrying a policy is named by its tag.

**And the pages had the same hole in six places** — found by grepping `inspect(`
across `lib/ex_tbp_monty_web` rather than by a report, which is the lesson: the
rule was enforced where the run's record is written, and every page that flashes
"…: why" built its own sentence from a term. "That world will not open:
`{:error, :no_python}`", "The runs could not all be deleted:
`{%RuntimeError{…}, {Task, :await, …}}`", "Could not start: `{:cannot_create, …}`"
— a person reading those has been handed the internals and nothing to act on.
`Failure.sentence/1` is the one answer: a reason a record wrote stays the sentence
it is, text that is a dump is said plainly with the text kept beside it, and
anything that is not text at all goes through `lost/1`. The six sites —
`experiment_live`'s run-failed push, its world-open pair and its unqueueable run,
`run_history_live`'s failed delete, `prerequisites_live`'s failed start — all ask
it now. Two exceptions were left alone on purpose: the config page's
`<code>{inspect(@error)}</code>` is the technical fold, and the page's own closing
line is a log written for whoever debugs the page.

**Two more doors, found by the same grep.** A run's own log wrote
`the run's steps could not be written: {:error, :enospc}`,
`statistics could not be written: …` and — worst of the three —
`could not close the record: [steps: {"is invalid", [type: :integer]}]`; and the
MCP answers pasted terms too, one of them (`Mcp.Experiments`) returning
`inspect(reason)` as the _entire_ error message. So `Failure` gained two more
phrases: `file/1`, which asks OTP for the words it already keeps
(`:file.format_error(:enospc)` is "no space left on device") and describes a shape
that is not an error at all, and `complaints/1`, which turns a changeset's keyword
into "steps is invalid; state can't be blank". Six call sites now ask them, and the
MCP error cases assert their answer holds no `{` and no `~U[`.

The lesson to keep: the rule was enforced where the record is written and nowhere
else, and one `grep 'inspect('` over the doors a person reads found eleven more
places. Do that grep when the rule is restated.

**The rule for the next pair of hands**: nothing that reaches a record, a run log
line, or a page may be built with `inspect/1`. `technical` is the only place a
traceback belongs, and `Failure` is where "why" is turned into words — however
tempting the term looks, a name and a timestamp included.

### 45.2 The CAD scene was the only red in the CRAP gate

`open_cad_scene/1` asked two questions in one nested `case`, which is one
decision too many for the ranking; this suite carries no `ex_monty_cad`, so no
test can reach either branch and the function scored 30.00 against a 20.00
threshold (a `with`/`else` had scored exactly 20.00 before the world-rule
commit). It is now `cad_part_path!/0` (the path, or raises with the reason) and
`open_cad_scene/1` (opens it, or says the scene would not) — 12.00 each at no
coverage (`b5a3b4c`).

### 45.3 How the state was read, without a database

The user's rule, stated twice in one minute: **do not read a run through the
database.** Clustered nodes own their own store — SQLite is the per-node case —
so `psql` sees one node's truth at best and nothing at worst. What worked:

- `logs/<node>.log` — the dev cluster's JSONL of each node's stdout
  (`process-compose.yaml` writes one per process). The crash, the page-open
  events and the `{:shutdown, :closed}` of a tab are all there.
- `priv/studio_runs/<id>/run.log` — a run's own transcript, which is what its
  page shows and where the leaked sentence above was read from.
- A hidden node, when a node has to be asked something:
  `elixir --name probe@127.0.0.1 --hidden --cookie "$(cat ~/.erlang.cookie)" /tmp/ask.exs`
  with `:rpc.call(:"node1@127.0.0.1", Monty.Studio.RunHistory, :list, [[limit: 5]])`
  — the query runs on the node that owns the rows. `--hidden` keeps it out of
  every `Node.list/0` the pages draw.

## 46. 2026-11-13: a run continues the division its dead worker left

The forum's question — _are partitions stateless workers or resumable experiment
owners?_ — was answered "stateless work" in §44.3, with the part-lost case as the
only exception. It is answered "owners" now, at both levels: a part given away
resumes its evaluation episodes, and a **run** whose worker died is put back in the
queue and continues its division instead of being closed.

### 46.1 What landed

- `d0bc2a0` — the division survives an attempt. `run_partitioned/3` keeps the rows
  and the part files it finds (`plan_parts/2` and `Artifacts.clear_parts/1` were
  erasing both on every execution), `RunHistory.ended_parts/1` says which parts an
  earlier attempt ended, and `step_wave/6` does not perform those again. The run's
  log names them, one line each, before the first step.
- `3738467` — `Reaper.recover/0` at boot, before `sweep/0`: every run of this
  node's whose division has **something done and something left** goes back in the
  queue; everything else is still closed. `RunHistory.requeue/1` writes the true
  word, `queued`.
- The numbers survive too: `RunHistory.checkpoint_summary/2` writes the total at
  the training wave's boundary, and `Summary.restore/1` reads it back.
- `7787329` — not the feature, but it was red at HEAD and would have failed CI's
  lint: sobelow 0.19's new `DOS.Tar`/`DOS.Zip`/`DOS.Decompression` checks (five
  findings in files nobody had touched), and `Stops.start_link/1`'s `@impl true`,
  which is not a callback and breaks `mix compile --warnings-as-errors`.

### 46.2 The traps, which are the part worth keeping

- **`plan_parts/2` deletes what it replaces, and `Artifacts.clear_parts/1` deletes
  the files.** Both are right for a second _attempt_ at one experiment and fatal for
  the same attempt continuing: a resume that calls either has already lost the
  checkpoint. The division's presence is what decides which branch runs.
- **`Summary` has two spellings.** A record keeps `"match"`; the live fold counts
  `:match`. Restoring without converting makes `merge_tally/2` keep both, and a page
  shows one module twice — a wrong number that looks like two modules that each
  concluded. `restore/1` converts the three places ids and states are stored.
- **An ended part is not a part in hand.** `ended_parts/1` counts `finished`,
  `failed` and `stopped`; a `running` row whose lease has not expired is somebody's
  live work, and skipping it would be skipping work, not saving it.
- **The bound for recovery is the boot, not a counter.** `sweep/0` runs on every
  tick of every open page. A recovering sweep would put a crash-looping run back in
  the queue once a tick; a boot puts it back once, and says so in the run's log
  where whoever wonders why it ran twice will look.
- **Queue first, status second.** `Run.enqueue_run/1` before
  `RunHistory.requeue/1`: a run that could not be queued must not say `queued` —
  the failure returns `false` and the sweep closes it.
- **A part in a peer's hands is not this node's silence** (`c1e976c`). The first
  version of `recover/0` decided "nobody is working on this run" from this node's
  registry, which a cluster contradicts: after a reboot part 3 can still be a
  peer's, and re-queueing makes the new worker ask for it, the claim refuse it
  (`{:held, node, until}`), and the recovery fail the run at its first wave.
  `RunHistory.claimed_parts/1` is the answer — a live claim on a node that has just
  booted can only be a peer's — and `recover/0` asks it.
- **…but the sweep must not.** The same guard on `sweep/0` would have left a
  _cancelled_ run saying `running` for ever, because a dead worker's claim outlives
  its job by a lease; "closes the division with it" caught that. Closing a
  cancelled run is the operator's intent, and the reaper's moduledoc now says which
  of the two asks the claims.

### 46.3 What is still not resumed

- A **training** part interrupted mid-episode starts that episode again. The model
  that took the earlier episodes did not travel with the part, and a checkpoint is
  the only thing that would change that.
- A worker that dies **inside** a wave loses that wave's numbers: the checkpoint is
  at wave boundaries, because until a wave ends its numbers exist only in the
  process. The steps are not lost — each part keeps its own — so the transcript is
  whole and the tally is short of that wave.
- The run list across per-node stores stays a per-node list with a peer panel
  (`ExTbpMonty.Cluster.Peers`) instead of one merged list: a merged row would offer
  Stop and Delete for a run the page cannot see.

### 46.4 The gate

`mix lint` 0 (compile `--warnings-as-errors`, format, credo 5606 mods/funs with no
issues, sobelow); the full suite **3188 passed** — twice, because the first run
lost `recording_episode_test.exs`' fidelity case to the machine being loaded (21
steps against 27); that case passes alone and on the second full run. The three
CRAP paths 20.00/20, 20.00/20, 29.85/30 over a fresh `mix cover` export; dialyzer
0 errors. CI: `80a78ec`, `afcb43f`, `d0bc2a0` and `3738467` **success** on every
job, the three desktop legs and the image index included. The correction's own
gate: lint 0, full suite **3191 passed**, the three CRAP paths, dialyzer 0.

**A pending run is cancelled by the next push on main, even with
`cancel-in-progress: false`** (measured here): `c1e976c`'s run never started —
`fa06d9e` queued behind it and GitHub keeps one pending run per group. The setting
protects a _running_ run, not a queued one, so the only run that is guaranteed to
be verified is the last pushed — which is why every push here carries its own
local gate rather than waiting for the previous one to be confirmed.
