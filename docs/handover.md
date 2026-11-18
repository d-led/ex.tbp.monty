# Hand-off — 2026-11-18

A snapshot for whoever picks this up. **`docs/roadmap.md` is the living
document** — phases, what each is waiting for, and what "done" means. This file
does not restate it; it says where the work is stuck right now, what was learned
that the roadmap cannot show, and where to look for each answer.

State: the v0.1 studio is built and the port runs experiments; the counts are
the commands' to print (`mix monty.readiness`, `mix monty.module_map.verify`,
`MIX_ENV=test mix run --no-start scripts/loop_map.exs`, `mix monty.data.check`).
Do not quote counts from prose, including from this file.

---

## The three things blocking real progress

### 1. Phase 2 — the action stream parts company at step 28

The port reproduces Monty's episode action for action for the **first twenty-seven
steps**, digit for digit. Step 28 is a `move_tangentially` whose _distance_ is
his (0.004) and whose _direction_ is not; everything after it is a `move_forward`
off by 1.5e-5 to 1.5e-3, which is one different tangential step propagating
through the depth the next step reads.

What is already ruled out, by measurement rather than reasoning
(`scripts/probe_action_stream.exs` now prints the agent's rotation beside each
step):

- **Not the frame.** Rotating our own local heading by our rotation reproduces
  our recorded direction exactly. Rotating _his_ recorded direction back by the
  same rotation gives a local heading of `3.001720189` against our `2.894124581`
  — a tenth of a radian apart, which with `alpha` at 0.1 is a target a whole
  radian apart.
- **Not the branch.** Both sides take the momentum branch at step 28 (the two
  before it answered from curvature; this one is back on momentum with the
  counter at its first step of twelve), and the flag that chooses it reads the
  same on both sides from the same rule (`|k1 − k2| >= pc1_is_pc2_threshold`,
  ten by default, not overridden by this config).

**Next**: a recording of the same episode from the **current** checkout. The
fixture was recorded at an older Monty that answered this step differently — its
own run answers step 48 with a rotation and direction that are ours to the last
digit — so some of the remaining difference may be the fixture's age rather than
the port's arithmetic. Until that is settled, hunting the policy by hand is
guessing.

### 2. Phase 3 — `base_77obj_dist_agent` cannot start

Killed while its model is being built, before step 0, when a process passes the
4 GB ceiling (at a 3 GB ceiling of its own it dies at `Total Heap Size:
459 908 514` words, ≈ 3.7 GB). The library is 213 MB of heap; the module holds
that library rather than copying it, so the gigabytes are the library **copied
between processes** — a term sent as a message is copied, and this one is maps
and lists rather than off-heap binaries.

Unblocking, in the roadmap's order and for its reasons:

1. **Count the hand-overs.** Grow `scripts/measure_step_memory.exs` a mode that
   starts the run above the need and prints every registered process with the
   heap it holds, so the copies are named rather than inferred.
2. **Hold the library once.** `Monty.Studio.Memory` already caches it in
   `:persistent_term`, but `Setup.model_spec/3` hands the term itself to
   `Monty.Runtime.Model`, whose init hands it to each module. Pass the cache key
   plus the shape a module needs and let the module read the library where it
   stands — the move `Memory.built/2` already makes for the loader.
3. Only then measure the step, which is where the remaining time goes.

The first wrong reading and its correction are in
`docs/validation.md#where-the-77-object-benchmark-stops-2026-11-16` — read that
before re-measuring, it will save the same detour.

### 3. Phase 4 — training is the next real feature

Epochs and training episodes over the ported pipeline, supervised LM ids, and
memory save/load as graph files with metadata in Postgres. `Monty.Prerequisites`
becomes load-bearing here: a run that needs a model says so before it starts.
Done when a training experiment trains, saves, and a later run loads it — from
the page and from `mix monty.run`. Training runs have been attempted against the
dogs and CAD worlds; treat the roadmap as the authority on what is finished.

## Decisions still owed (not bugs, and not to be settled in passing)

- **Two epoch brackets have no counterpart here.** Monty's `pre_epoch`/
  `post_epoch` choose the interface per mode and write `model.pt`,
  `exp_state_dict.pt` and `config.pt` per epoch; this port chooses once per
  phase and keeps the memory once per run. Whether a run should write a memory
  release per epoch is a decision about what a run leaves behind —
  `docs/monty-differences.md#225-two-epoch-brackets-have-no-counterpart-here`.
- **A multi-view sensor layout** (four sides and one above) is this port's own
  experiment, not Monty's: it belongs in `monty-differences.md` with its numbers,
  never quietly in `conf/`.
- **Habitat** is refused as a world this build does not have. That is a
  decision, not a gap: `Monty.Simulators.Port` and the peer script are tested in
  both directions for the day it is wanted.
- **Clustering is additive**: with `MONTY_CLUSTER` unset nothing starts and
  nothing changes (`docs/cluster.md`, `docs/container.md`).

## Small things that will otherwise cost somebody an afternoon

- **`tprof`'s time column is not a measurement** — it is inflated ~16× by its own
  tracing (`scripts/probe_tprof_overhead.exs`: 24.6 ms by the clock vs 402.7 ms
  reported for the same loop). Its `callers` report does not exist in tools
  4.2.3. Read call counts and words allocated; measure changes with a
  microbenchmark.
- **Never compare wall clock across machines or loads.** A "823 ms/step, 21×
  Monty" figure in this project's history was a box at load average 10.6–14.7;
  the same steps run at 12–170 ms idle. The correction is in `docs/speed.md`.
- **The acceptance ladder** is
  `mix monty.run base_config_10distinctobj_dist_agent --episodes 1 --steps 8 --no-record`
  and must stay digit for digit (`0.746 (192, 6)` … `6.338 (1429, 2)`,
  `goals 15065`) after any change to the model.
- **`scripts/quality.sh`** is what CI runs (lint, suite with coverage, CRAP);
  `mix dialyzer` is the separate types job; `scripts/reformat.sh` formats. A run
  in flight forbids editing `lib/` — `scripts/run_in_flight.sh` answers whether
  one is (`MIX_ENV=test` is another build and is safe).
- **Dependabot's `glib` alert is dismissed, deliberately** and with the reason
  recorded: `tauri 2.12.5` pins `gtk = "^0.18"`, `gtk 0.18.2` needs
  `glib = "^0.18"`, so `cargo update -p glib --precise 0.20.0 --dry-run`
  refuses. Linux-target only; it clears when tauri adopts gtk 0.19+.

## How this port is held to account

Module for module (`Monty.A.B.C` from `a/b.py::C`, enforced by
`mix monty.module_map.verify`), function for function inside the loop classes
(`scripts/loop_map.exs` prints the misses; a rename is a defect), functional core
and actor shell (`Monty.Runtime.*` owns processes and routing only), configs read
from Monty's Hydra YAML rather than reinvented, and determinism — one RNG stream
per episode, threaded in Python's order.

Tests are translations: a ported module's tests come from Monty's own
`tests/unit/**/test_*.py`, one case for one case, each naming the case it
translates; a hand-written behaviour test states intent and is never counted as
parity. A case that cannot be translated is listed, never dropped silently.
