# Hand-over — 2026-11-06 (evening), continued 2026-11-07

The newest section is 16. Sections 1–15 are the previous evening and are still
right where they name a file, a commit or a measurement.

What is open, what is already known, and where the evidence is. Written for
whoever picks this up next; every claim below was measured or read, and the
file and line that settles each one is named.

State at hand-over: **`scripts/quality.sh` is green** on the tree this file is
in — lint clean, 2 318 tests (19 properties), CRAP worst 29.85 against a
threshold of 20. CI's
last completed run (`42254886887`, on `4d92066`) was **red in two jobs**, both
fixed by `e5ad552`: `lint` (one unformatted test file) and `types` (a real bug
dialyzer found — the generator's "map unchanged" guard compared a binary with a
`File.read/1` result, so it never fired and every `mix test` rewrote the map).
Check CI on the commit after this one before believing anything in section 10.

What is left, in order:

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

`6bd0bfe` changed the desktop matrix's `os: macos-14` to `os: macos-latest` in
`.github/workflows/ci.yml:648`, and run `42178863188` came back **green in every
job**, `desktop (ex-tbp-monty-osx-arm64): success` included. So the annotation
`The configuration 'macos-14-arm64-us-default' is not supported` was the label
and nothing else; the earlier "account entitlement" reading (in `docs/desktop.md`
and commit `93397d4`) was wrong and `3f94618` has the correction.

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
`episodes_done: 22` and a summary of every number **but** a reason.

The crash itself, reproduced headlessly on `base_10simobj_surf_agent` — same
stack trace as the studio run that reported it:

```
** (RuntimeError) an undo jump left the agent turned away from where it started
    informed_policy.ex:369  assert_undo_jump_was_successful/2   (raise)
    informed_policy.ex:211  jump_outcome/3
    informed_policy.ex:194  goal_driven_actions/4
    surface_policy.ex:201   surface_step/6
    step.ex:222             Step.handle_call/3
```

**The earlier reading of this was wrong, and the wrong part is worth keeping.**
This section used to say the crash happened "between calls" with nobody watching,
and that the step coordinator should therefore write to `RunHistory` itself. It
does not: a coordinator computes only during a call, and the caller — the Oban
worker — was inside `GenServer.call`, so it was handed the exit, `step_once`'s
`catch` turned it into `{:crashed, step, reason}`, and
`Monty.Frameworks.Experiments.MontyExperiment` carried it up. The reason _was_
known. `close/6` then finished the record with `RunLog.summary/1`, which returns
the numbers and has no field for a reason — so the one thing the run knew was the
one thing the record did not keep.

**The change** (in the order it happens):

1. `Monty.Runtime.Model.step/4` unwraps a coordinator's death: what
   `GenServer.call` raises is `{{exception, traceback}, {GenServer, :call, _}}`,
   and that is re-raised as the exception with the step's own traceback — the
   frame that actually failed. A model that is not running stays an exit.
2. `Monty.Studio.Jobs.Run.step_once/3` builds `Failure.crashed(kind, reason,
__STACKTRACE__)` in its `catch`, **where the traceback still exists** — a
   reason formatted later from a bare term has none.
3. `Monty.Studio.Failure.stopped/1` is what a crash becomes however it arrives: a
   pair already built, an exception, a sentence, or a term (which is the detail,
   never the answer). `{:target_not_visible, id}` gets its own sentence.
4. `RunLog.summary/2` merges that pair into the summary, and `close/6` passes it
   whenever the outcome is `{:crashed, …}`. A record that says `failed` now says
   why, in the same row a page reads.

**Not done, on purpose**: no `RunHistory` call was added under `lib/monty/runtime/`.
The coordinator owns processes and routing; the studio owns records. A crash
reaches the database through the caller, which is the only process that knows
which run it was stepping.

**Still open in the same family** — recorded so it is not mistaken for fixed:
`mix monty.run` has its own episode loop and no `catch`, so a raise there leaves
the record `running` until a page reaps it, with the Reaper's truthful but
uninformative "it stopped before it finished — nothing was working on it any
more". The task does exit 1 (reproduced), so a script sees the failure.

## 4. The raise itself: the assertion was too strict here — **closed**

> `InformedPolicy.assert_undo_jump_was_successful/2` raising on
> `base_10simobj_surf_agent` is either a real bug or an assertion too strict.

It is the second, and the number settles it. Monty compares the quaternions it
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
`type: :standard_error`, a `Logger.info/1` line lands on stderr and not on
stdout, and "Failed to write log message" appears nowhere. (The window's own
console was not opened for this; the stream is the property that changed.)

## 7. Performance: what is left, and how to measure it here

Current: **6.85 M reductions/step**, 79 MB of garbage, ~42.5 ms/step on a quiet
box, 140/140 episodes. Two changes this session: decode as 32-bit halves
(`e00e058`, −3 %) and `node_poses/4` reading pose vectors by shape instead of
`Enum.take` + `Enum.slice` (`fc0a063`, −10.5 %). Both ladder-identical.

- **Read the profile for call counts and words allocated only.** `tprof`'s time
  column is inflated ~16× by its own tracing (`scripts/probe_tprof_overhead.exs`:
  24.6 ms by the clock vs 402.7 ms reported for the same loop). Its `callers`
  report does not exist in tools 4.2.3 (`:tprof.inspect/3` has no clause), so a
  `pattern`-filtered profile gives counts but no call graph.
- **Never compare wall clock across machines or loads.** An earlier "823 ms/step,
  21× Monty" was measured at load average 10.6–14.7 and is withdrawn in
  `docs/speed.md`; the same steps run at 12–170 ms on an idle box.
- **What the counts say now**: 26 015 `Enum.map/2` calls averaging ~12 elements
  (306 k iterations), 9 681 `Enum.take/2` before `fc0a063`, per-hypothesis
  closures (`spread_against`, `gather`, `keep_where`) about 2× per hypothesis.
  `Hypotheses.gather/3`, `poses`/`locations`, and the displacer's hot path are
  **already** binaries and kernels — do not "optimise" them again.
- **The "next target" this note used to name was a phantom.** It said
  `SpatialArithmetics.check_orthonormal/1` (`spatial_arithmetics.ex:182`) does a
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
- Kernel changes keep the Elixir reference path and a parity test; the ladder's
  eight evidence lines are the acceptance.
- Tests specify behaviour, no `Process.sleep/1`, no casting an interface to a
  concrete type to reach test helpers.

## 9. Closed this session (so nobody re-opens them)

- **Dependabot #1, `glib` (Rust, medium)**: dismissed as a tolerable risk with
  the verified chain — `tauri 2.12.5` pins `gtk = "^0.18"`, `gtk 0.18.2` needs
  `glib = "^0.18"`, and `cargo update -p glib --precise 0.20.0 --dry-run`
  refuses with exactly that. Linux-target only; clears when tauri adopts
  gtk 0.19+ (needs glib ^0.22). Editing a dismissed alert needs a reopen first
  (`409` otherwise).
- **The README's download links**: they exist (three platforms, via
  `nightly.link`), and all three resolve.
- **The two screenshots** the README shows were never committed; they are now
  (`9e4b296`).
- **The full experiment completing** — twice, with identical step and goal
  counts (4 789 steps, 4 558 928 goals), once at load 10.6–14.7 and once quiet.

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

### 10.2 The module map is tooling now, not a document

`lib/monty/module_map/data.ex` is generated and the generator keeps it true:
`mix test` runs `monty.module_map.gen --best-effort` first, so a machine with the
checkouts beside it refreshes the map before the suite, and a machine without
them — CI has neither — keeps the committed map and says so. A package with no
checkout keeps its entries _and_ its recorded commit; an unchanged map is not
rewritten (mtime is what makes Mix recompile it); the write goes beside the file
and is renamed onto it, because `mix test --partitions 4` can start four at once.

Two facts are now in the map that a page cannot invent: `stand_in:` and `file:`.
The first is written down once, in `Monty.ModuleMap.StandIns` — the two shells
(`Monty`, `MontyForGraphMatching` → `Monty.Runtime.Model` + `Monty.Runtime.Step`)
and the 17 MuJoCo classes the carried world in `priv/monty_py/world.py`
implements — and `verify` fails if a declared stand-in names a module that is not
there. The second is asked of the compiled module's own `compile_info`, because
the port does not keep one module per file (`sensor_modules/camera_sm.ex` holds
`CameraSM`).

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
  them "a Monty test fixture, not an experiment", or keep refusing them?
- Is Habitat-Sim a permanent refusal, with the stand-in scene offered as the
  shape-only option? Nothing has changed here; the refusal is honest today.

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
referees them, how many of Monty's own cases are translated (22 of 652), and the
order in which the rest should be done.

---

## 12. The tests themselves: 22 of Monty's 652 cases are translated — and each translation has been paying

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

It said **11** at the start of the session and **22** at the end: every one of them
a case in `burst_sampling_test.py`, which is now 22 of its 24. Everything else in
`tests/unit` — 630 case names — has no counterpart yet.

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
  Monty does. Twenty-two cases are translated; the rest of our suite is not.
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

### 15.5 The two commands that catch most regressions in a minute

    mix test test/monty/pretrained_replay_test.exs   # Monty's own recording
    mix monty.run base_config_10distinctobj_dist_agent --episodes 1 --steps 8

The first replays a recorded episode and measures the hypothesis space object by
object; the second must print the eight evidence lines beginning `0.908` and
ending `11.712`. If either moves, the change under test is the cause.

---

## 16. 2026-11-07: the transcript left the database, the chart stopped lying, and the speed work found its target

**State at `ff42f52`.** `./scripts/quality.sh` green (2 438 tests, 19 properties,
lint, coverage/CRAP/parity, complexity worst 29.85) and `MIX_ENV=test mix
dialyzer` at 0 errors. CI: `5682859` and `1079af6` were watched to green in every
job — `types`, `lint`, all four shards, coverage, both images, all three desktop
builds. `3c43031` and `ff42f52` are documentation-only and were **not** watched;
check `gh run list --limit 1` before believing this section's gate.

Rocky start, worth reading before the next push: `de96fe7` went out **red** on
`types` because `scripts/quality.sh` does **not** run dialyzer — CI's `types` job
does. The first repair (use `update_all`'s bare count) then broke **94 tests** at
runtime, because Postgres answers `{1, nil}`. The fix asks `Repo.exists?/1` and
discards the answer, which satisfies both. **Run the gate and dialyzer before
every push.**

### 16.1 What landed

| Commit                                                | What it does                                                                                                                                  | How it is known                                                                                                                                        |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `de96fe7`                                             | a run's steps stream from memory through `Monty.Studio.RunStream`; the row is written at every episode boundary and once when the run settles | the row was being rewritten whole per step: 13 MB/step at the tail of an 887-step run, its last hundred steps at 5 s each against 157 ms for its first |
| `de96fe7`                                             | a run ended out of band keeps its steps: whoever closes it writes what memory holds                                                           | the ended run had recorded `0 steps` while its page drew 55                                                                                            |
| `de96fe7`                                             | the chart's value axis always spans zero; the axis column's height is rendered with a unit                                                    | in the browser: labels `0, 20, 40`, and the column is 150 px instead of none — the unit-less `height: 150` was why labels piled on one spot            |
| `5682859`                                             | the write path asks whether the run exists instead of reading `update_all`'s answer                                                           | dialyzer 0 errors and the 94 tests green together                                                                                                      |
| `4c5e22c`                                             | the chart's view (series, window, step) belongs to the run it was chosen for                                                                  | a series picked for one run no longer follows the reader to the next; a test patches between runs to prove it                                          |
| `4cd0a5b`, `8d49404`, `1079af6`, `3c43031`, `ff42f52` | `docs/speed.md` carries today's numbers; two instruments added                                                                                | below                                                                                                                                                  |

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
   `depth_to_3d_locations_test.exs` asserts that, so removing it is a parity
   break.

### 16.3 Where the time actually is, and the one query still owed

`eprof` over one step, every process: `Enum` map internals 10.8 %, message copy
10.5 %, reduce 3.6 %, kd-tree 3.3 %, `take_list` 3.0 %, `MatcherNif.decode`
3.6 %, `with_index` 2.1 %, `filter` 2.0 %, `drop` 1.9 % — about **30 % in generic
`Enum`/`lists`/`Stream` passes over the hypothesis arrays**.

`fprof` on the learning module's process for one step (2 539 575 calls) turns
that into callers:

| what                                            |      accumulated |                        calls a step |
| ----------------------------------------------- | ---------------: | ----------------------------------: |
| `Enum.map/2`                                    | **1 778 (41 %)** |                          **25 987** |
| `MatcherNif.decode/1` → `decode_one/1`          |       440 (10 %) |              862 (≈127 values each) |
| `Enum.slice/3` → `slice_forward` → `slice_list` |       420 (10 %) |                          **16 083** |
| `Enum.reduce/3` fold                            |        399 (9 %) |                             199 813 |
| `Enum.take_list/2`                              |        306 (7 %) | 161 250 (144 957 its own recursion) |
| `Hypotheses.gather/3` fun                       |        128 (3 %) |                             128 320 |

So there is **no single hot loop**: ~26 000 small maps a step over hypothesis
lists of a dozen rows, plus 16 000 list slices used for selection. **The query
still owed** is the direct caller of `Enum.slice/3` — its caller block was
deleted with the 660 MB trace before it was read. One re-trace answers it, and
then the change is mechanical: select through `Hypotheses.take/2`'s
`binary_part/3` (already written, used elsewhere) instead of list slicing for the
10 %, and fuse the maps for the 41 %.

The hypothesis columns are **already packed** — evidence, locations and poses are
binaries, `take/2` and `rows_at/2` select with `binary_part/3`, and displacement
is `MatcherNif.displaced_locations/3`. Do not "pack the hypotheses" again.

### 16.4 The yardstick

Monty runs `unsupervised_inference_distinctobj_dist_agent` to completion in
**0:38:10 — 49 617 eval steps, 99 episodes, 10 epochs, seed 42: 46 ms a step**.
Its dashboard draws all ten objects on one axis, legend included, evidence
restarting at each episode boundary. That is what this port is measured against,
and the chart now opens that way by default (16.1).

### 16.5 What not to trust, added today

- **`scripts/quality.sh` as the whole gate.** It does not run dialyzer. CI's
  `types` job is separate.
- **A profiler's word column as the size of a message.** See 16.2(2).
- **A microbenchmark that sizes its result.** `:erts_debug.size` costs about
  twenty reductions — more than `Geometry.dot/2` — and the first version of
  `probe_hypothesis_cost.exs` measured the harness.
- **A profile's call counts as one step's.** `probe_step_profile.exs` profiles
  three steps; divide by three.
- **A measurement taken while another `MIX_ENV=test` process runs.** A stray
  probe sharing `_build` and the database sandbox made two gate runs look like a
  94-test regression. Check `ps` before believing a red gate.

---

## 17. 2026-11-07 (later): `tutorial/first_experiment` runs, and its graph is Monty's

The hand-over's open item 1 was `GraphLM` + `DisplacementGraphLM` (10.6). Both
were half-written: the classes existed, the module map called them
`:implemented`, `Setup` had no entry for either, and `Setup.learning_module_spec`
silently fell back to `EvidenceGraphLM` or to the synthetic stand-in. The
tutorial config was refused by its experiment class, so nothing exercised the
hole. It does now.

### 17.1 What landed

| Commit   | What it does                                                                                                                                                                             | How it is known                                                                                       |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| this one | `DisplacementGraphLM` answers every `LearningModule` callback, built by `from_config/2`; `GraphLM` joins it and refuses itself (`:no_matching_scheme`)                                   | a test asks the behaviour for its callback list and asserts nothing is missing                        |
| this one | `MontySupervisedObjectPretrainingExperiment` ported: exploring when every module is supervised, the answer stated at `post_episode`, before memory is written                            | the tutorial builds a graph named `mug` in one episode (test + real run)                              |
| this one | supervision crosses the process boundary: `Run.supervise/1` → `Model` → `Step` → `LearningModuleServer` → `GraphLM.supervise/3` / `clear_hypotheses/1`                                   | `docs/monty-differences.md` §2.20                                                                     |
| this one | an unbuildable learning module is a **finding**, not a stand-in (`:learning_module_not_buildable`); a supervised experiment on the stand-in scene is refused (`:no_target_to_supervise`) | `setup_test.exs`: `graph_1lm` is refused, `feature_pred_off_object` is refused, the tutorial is valid |
| this one | the samplers carry `quat_rotation` and `priv/monty_py/world.py` keeps `euler_rotation`/`quat_rotation` in `primary_target`                                                               | Monty's own target is `{"object": …, "semantic_id": …, **object_params}`; ours had no turn to state   |
| this one | `mix monty.run` begins and ends an episode through the config's **experiment class**, as the queued runner already did                                                                   | before this, a pretraining config ran under this task with no supervision at all                      |

### 17.2 The parity number that matters

Monty's own run of the same config (`uv run python run.py
experiment=tutorial/first_experiment`, this machine, seed 42) and ours, same
config, same seed:

|                         | Monty                          | this port                      |
| ----------------------- | ------------------------------ | ------------------------------ |
| steps                   | 3                              | 3                              |
| of which matching       | 0                              | 0                              |
| policy                  | `is_done`, `time_out_lms`      | done at step 3                 |
| graphs                  | `mug` / `patch`                | `mug` / `patch`                |
| nodes                   | 3                              | 3                              |
| edges                   | 6                              | 6                              |
| stored features         | 13                             | the same 13 names              |
| first node, world frame | `[6.50e-05, 1.49994, 0.03907]` | `[2.56e-04, 1.49974, 0.03900]` |

The node and edge counts and the feature set are identical; the first node
differs at the fourth decimal — sub-millimetre, and it is where the agent's
sensor ended up, not what the module did with it. That difference is the
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

| commit | what it does                                                                                                      | how it is known                                                                                       |
| ------ | ----------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| this   | `Monty.Studio.Readiness` — one experiment's answer, the counts, and the classes ranked by what they alone unblock | pure where it can be: `classify/1` and `summarise/1` are tested on a fixture; `catalog/1` is the edge |
| this   | `mix monty.readiness [--world] [--all] [--json]`                                                                  | 210 experiments in ~2 s, or 0.06 s from the cache                                                     |
| this   | `/experiments` grows a **Runs here?** facet, so the page opens on the answer                                      | the pill counts respect the other facets, like every other one                                        |
| this   | `Setup.modules/1` and `Setup.blocking/1` — the classification `module_findings/1` used to keep private            | one home: the refusal text and the survey count the same list                                         |
| this   | **a bug the facet surfaced**: the list rendered a page of unfiltered rows under every filtered link               | 30 stale rows under `?agent=surf`; now exactly the filtered ones                                      |

That last one is worth its own line: `mount/3` streamed the first page and
`handle_params/3` then streamed the filtered rows with `reset: true`. In a
browser the reset replaces the children, but the first paint already carried the
wrong list, and in the test the merged DOM kept both. Rows are streamed in
`handle_params/3` alone now, which is where the filters arrive.

### 18.2 The numbers (MuJoCo, the default world)

210 experiments: **87 run here, 123 refused, 0 do not compose**. In the stand-in
scene it is 122 and 88 — a sphere needs no pretrained memory and cannot be
refused for showing no target.

`docs/readiness.md` has the full table. The three rows that matter:

- **87 are refused for the world** (`Habitat-Sim`, §10.7's open decision).
- **53 for a class nothing stands in for**, and the ranking by what each one
  alone unblocks is `FeatureGraphLM` 10 (21 naming), `MontyBase` 3 (6),
  `DisplacementGraphLM` 2 (4), `GraphLM` 1, `TwoDSensorModule` 1 (17),
  `DefaultAttentionSystem` 0 (9), the Saccade and Omniglot environment/interface
  pairs 0 each.
- **19 for a missing pretrained library**, which is `/prerequisites`'s job and
  not a port at all, and **7 for `${constants.rotations_all_count}`**, which is
  §11's open point 4 and is still true.

### 18.3 The order this suggests, and why it changed

The old order was `GraphLM` → `DisplacementGraphLM` → `FeatureGraphLM` → …,
written when both of the first two were missing. Both are written now (§17), so
what is left of them is a **capability inside a class that exists**:

1. `DisplacementGraphLM` refuses `match_attribute: PPF` in its own words —
   "matching on PPF is not ported, only displacement is". Two MuJoCo experiments
   and two behind Habitat; a branch to translate, not a module.
2. `FeatureGraphLM` — ten MuJoCo experiments, the largest single win.
3. `TwoDSensorModule` + `DefaultAttentionSystem` together, since the Saccade and
   Omniglot families need both and only one config is blocked by the sensor
   alone.
4. `MontyBase` last, because all three of its experiments are Monty's own pytest
   fixtures and §10.7 has not decided what those are.

### 18.4 What not to trust

- **A count of unported classes as a count of blocked experiments.** One class
  can block twenty-one experiments (`FeatureGraphLM`) or none
  (`SaccadeOnImageInterface` is always accompanied by something else).
- **`blocked_by` as "classes to write".** It now also names a written class that
  refuses a config — `DisplacementGraphLM`, `GraphLM` — because that is the work
  too, and the mix task's `learning_module_not_buildable` row is where those
  show.
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
