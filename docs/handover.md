# Hand-over — 2026-11-06

What is open, what is already known, and where the evidence is. Written for
whoever picks this up next; every claim below was measured or read, and the
file and line that settles each one is named.

State at hand-over: `main` is green except CI's macOS leg (`6bd0bfe`, fix
pushed, run `42178863188` queued — see 1). A step of
`base_config_10distinctobj_dist_agent` costs **6.85 M reductions** and the whole
experiment finishes: **140/140 episodes, every one ending in a recognition,
4 789 steps in 203 s, exit 0, 42.5 ms a step** on a quiet machine (Monty's
dashboard: ~39 ms). Suite 2 269 green, lint clean, CRAP within its thresholds.

---

## 1. CI: the macOS leg was a runner label, not an entitlement (needs a verdict)

**Open only until a run finishes.** `6bd0bfe` changes the desktop matrix's
`os: macos-14` to `os: macos-latest` in `.github/workflows/ci.yml:648`. Every
earlier run had `desktop (ex-tbp-monty-osx-arm64): cancelled` a second after
queueing, annotated `The configuration 'macos-14-arm64-us-default' is not
supported` — which was first written down (in `docs/desktop.md` and a commit
message) as an account entitlement. It is not: the sibling repo
`~/src/confluence_phx_mirror` builds the same platform from `macos-latest` on
the same account. `docs/desktop.md` has been corrected; the wrong diagnosis is
still in the history of commit `93397d4`.

- **Next**: check `gh run view <run> --json jobs` for
  `desktop (ex-tbp-monty-osx-arm64)`. Green means closed; a fresh annotation
  means the label was not the whole story.
- **Known consequence while it was cancelled**: the run's overall conclusion is
  `cancelled`, and `desktop release` (`ci.yml:1027`, `if: refs/tags/v*`) is
  skipped with it. Everything else — lint, 4 test partitions, types, coverage /
  CRAP / parity, both images, the image index, Linux and Windows bundles —
  succeeds.

## 2. No tagged release exists, so "latest binary" means the nightly artifact

`gh release list` is empty and `desktop release` only runs on `v*` tags. The
README's three download links and `scripts/run-desktop.sh` / `run-desktop.ps1`
all go through `nightly.link/.../workflows/ci/main/<asset>.zip`, which serves
the newest `ci` artifacts from `main`; all three returned **HTTP 200** when
checked (osx-arm64, linux-x64, win-x64). Nothing is broken — but a versioned
"latest release" page does not exist. A `v*` tag is what creates it.

## 3. A crashed step leaves no sentence on the run — **the biggest open defect**

Symptom: the run page says _"This run did not finish. It stopped without saying
why."_ `Monty.Studio.Failure.explain(nil)` (`failure.ex:51`) — the record has no
`reason` at all.

The console log shows what actually happened, on
`base_10simobj_surf_agent` after nine objects were recognised:

```
[error] GenServer {Monty.Runtime.Registry, {:step, "studio-1507"}} terminating
** (RuntimeError) an undo jump left the agent turned away from where it started
    informed_policy.ex:369  assert_undo_jump_was_successful/2   (raise)
    informed_policy.ex:211  jump_outcome/3
    informed_policy.ex:194  goal_driven_actions/4
    surface_policy.ex:201   surface_step/6
    step.ex:222             Step.handle_call/3
```

The machinery to record this already exists and is good:
`Monty.Studio.Jobs.Run.died/2` (`jobs/run.ex:475`) writes `Failure.crashed/3`'s
sentence under `reason`, the traceback under `technical`, finishes the record as
`"failed"` and broadcasts. **But it is only reachable from a `rescue`/`catch`
inside the Oban job worker** (`jobs/run.ex:118–124`). The crash was in the step
GenServer, a different process: if the worker was blocked in a `call` to it the
exit is caught; between calls — or for a studio-started run with no job worker —
nobody is watching, which is exactly what happened.

**The change, and the reasons for its shape:**

1. `lib/monty/runtime/step.ex`, `handle_call({:step, …})` (~line 200): wrap the
   body in `try`, and on `rescue error` build
   `Monty.Studio.Failure.crashed(:error, error, __STACKTRACE__)`, write it with
   the same `RunHistory.finish(record, Map.merge(record.summary || %{}, recorded), "failed")`
   that `died/2` uses (the run id is `state.model_id` — the key the step is
   registered under, `{:step, "studio-1507"}`), say "the run died: …" in the
   run's own log, then `{:stop, :step_failed, {:error, recorded}, state}`.
2. `catch` the `:throw`/`:exit` kinds too, so a killed step says so rather than
   "no reason" (`Failure.crashed/3` takes the kind; `@killed`/`@exited`
   sentences already exist in `failure.ex`).
3. Test in the shape of the existing `jobs/run_test.exs` ones: a raising step
   leaves a run whose failure explains it, traceback under `technical`, status
   `"failed"`; and a killed step says it was killed.

**Do not** `try` around the step's arithmetic and keep stepping, and do not
rescue in `Failure`/`Inspect` to blanket-hide unknown shapes. A raised
invariant means the policy's belief and the world disagree; the run must stop
and keep the traceback.

## 4. Then judge the raise itself (unresolved question)

`InformedPolicy.assert_undo_jump_was_successful/2` (`informed_policy.ex:369`)
raising on `base_10simobj_surf_agent` is either a real bug (an undo jump does
not land where the policy believes) or an assertion too strict for this
configuration. Not knowable until it is recorded properly (point 3) — do not
"fix" the motor policy before the sentence exists.

## 5. The experiment page shows no runs below the definition

The section is still there — `experiment_live.ex:442`, `#experiment-runs`,
`@runs_shown 5` — but it is fed by
`RunHistory.search(state: "all", text: name, per_page: 25)` in
`recent_runs/1` (`experiment_live.ex:137`). Two candidate causes, to be told
apart by one query against the same DB, not by argument:

1. **Name mismatch**: the run stores the string it was started from; a run
   started from a draft stores the draft's name, and `text: name` misses it.
2. **`search/1` changed shape under it**: the newest commit on that file is
   `4d0fe23` ("A row without its pictures is for the callers that only ask
   whether the run is there"), which moved callers onto `@without_pictures`
   rows. If the text search reads a column the light row no longer selects,
   the filter matches nothing — silting up as "no runs" with no error.

Fix direction: filter by the run's experiment identity rather than a substring
of a name.

## 6. The desktop sidecar fails every log write before succeeding

Every line in the desktop window's console is preceded by
`Failed to write log message to stdout, trying stderr`. The sidecar has no
console, so each message pays a failed write first, doubling the log volume and
burying real lines. Related, already fixed elsewhere: `println!` panics without
a console, which is why the window writes its complaints to a file
(`docs/desktop.md`). Worth making stdout logging conditional or writing to the
file directly.

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
- **Next target**: `SpatialArithmetics.check_orthonormal/1`
  (`spatial_arithmetics.ex:182`) doing a per-hypothesis `mᵀ·m` against
  `Geometry.identity()` — 12 976 `Geometry.transpose/1` calls and 5 129
  `Geometry.mul/2` closures in one step. Same shape of waste as `node_poses`:
  a small fixed-size computation in a hot loop. Measure with
  `MIX_ENV=test mix run scripts/probe_step_cost.exs`, then the ladder
  (`mix monty.run base_config_10distinctobj_dist_agent --episodes 1 --steps 8
--no-record`) which must stay digit for digit: `0.746 (192, 6)` …
  `6.338 (1429, 2)`, `goals 15065`.

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
