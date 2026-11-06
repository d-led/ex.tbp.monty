# Hand-over — 2026-11-06

What is open, what is already known, and where the evidence is. Written for
whoever picks this up next; every claim below was measured or read, and the
file and line that settles each one is named.

State at hand-over: CI is **green in every job** (`42178863188` on `6bd0bfe`, so
section 1 is closed). A step of `base_config_10distinctobj_dist_agent` costs
**6.85 M reductions** and the whole experiment finishes: **140/140 episodes,
every one ending in a recognition, 4 789 steps in 203 s, exit 0, 42.5 ms a step**
on a quiet machine (Monty's dashboard: ~39 ms).

What is left, in order: the desktop sidecar's failed stdout write on every line
(6), the performance work (7), and one known gap in the same family as the crash
that was just fixed — `mix monty.run` does not catch a raise, so a headless run's
record is closed by the Reaper instead of by the run (3).

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
ran to **28 recognitions with no undo-jump raise**, where the old code died at 10. (It was stopped there rather than carried to 140/140: the box was swapping,
and the point was the crash, not the episode count.) The acceptance ladder is
unchanged digit for digit: `0.746 (192, 6)` … `6.338 (1429, 2)`, `goals 15065`
under `MIX_ENV=test`, and `0.908 (802, 4)` … `11.712 (2342, 1)` in dev.

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

## 10. The port's own computational gaps, and where they are written down

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

1. **Nothing can be trained.** `Setup.phase_findings/1` refuses any phase that
   trains (`:training_not_implemented`), so the port runs _evaluation_ against
   pretrained graphs only. Every config whose phase is `train` is refused
   rather than faked — that is the fix of `7cba014`, which removed the stand-in
   experiments: an unported class or phase is now an error, not an `:info`
   finding beside a run that quietly stepped something else. 84 of 210
   experiments were affected. If you are asked "why can't I run this config",
   this is usually the answer, and making it faker would undo that commit.
2. **Unported classes are refused, not stubbed.** `@shell_classes` in
   `lib/monty/studio/setup.ex` names the two that exist as shells (`Monty`,
   `MontyForGraphMatching`); anything else in a config's `model_class` is a
   finding that says so.
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
