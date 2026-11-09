# Speed

What a step costs, what has been measured, and what is left. Everything here is
a measurement from this machine, quoted with the experiment it came from — not a
target.

The reference is Monty's own dashboard: `base_config_10distinctobj_dist_agent`,
10 objects, 14 epochs, **~39 ms a step** (5 122 eval steps in 3:18). One run of
this port reached 140/140 episodes at 0.61 s a step, so the _episode_ is right
and the _step_ is what is open.

## How to measure, and what lies

| what                             | how                                                                                     |
| -------------------------------- | --------------------------------------------------------------------------------------- |
| work and garbage per step        | `MIX_ENV=test mix run scripts/probe_step_cost.exs [experiment] [steps]`                 |
| who did the work                 | the same script — it prints reductions per process, labelled by callback module         |
| allocation per function          | `MIX_ENV=test mix run scripts/probe_step_profile.exs` (tprof over one `Model.step`)     |
| the whole run, as a user sees it | `mix monty.run <experiment> --episodes 1 --steps 8 --no-record` — the acceptance ladder |

- **Wall clock is not usable here.** The same step measured 0.6 s, 1.6 s and
  3.2 s in one afternoon depending on what else the machine was doing; a
  12.7 GB-of-13.3 GB swap reading made a 3.2 MB copy take a second. Reductions
  (`:erlang.statistics(:reductions)`) and reclaimed words
  (`:erlang.statistics(:garbage_collection)`, MB = words / 125 000) do not move
  with load. Check `sysctl vm.swapusage` before believing any timing.
- **One run cannot resolve a few percent.** The same probe reads 10.0–10.9 M
  reductions and 78–90 MB between runs. Quote pairs measured in one run, or do
  not quote at all.
- **The two probes drive different steps.** `probe_step_profile.exs` calls
  `Model.step` with a recording sensor — no MuJoCo, no studio. `probe_step_cost.exs`
  calls `Studio.Run.step`. Their totals are not comparable.
- `:tprof` needs `rootset: :all` and OTP 29's `:profile/2` takes a _map_:
  `:tprof.profile(fun, %{type: :call_memory, rootset: :all, report: {:total, {:measurement, :descending}}})`.
  There is no `analyse/2`; without `rootset: :all` the table is one
  `gen:do_call/4` row. `:eprof` prints an empty table for a step whose work
  happens in other processes, and `:fprof` writes hundreds of megabytes.

## Where a step's work goes (2026-11-03, ten objects, six steps, dev)

9.0 M reductions and 82 MB of garbage a step, split by the process that did it
(three runs agreed to within 1 %):

| who                                      | reductions/step | share |
| ---------------------------------------- | --------------: | ----: |
| `Monty.Runtime.LearningModuleServer`     |           5.2 M |   57% |
| the two `SensorModuleServer`s            |           1.4 M |   15% |
| the caller's own process (orchestration) |           1.2 M |   13% |
| `Monty.Simulators.Mujoco.Host`           |           0.5 M |    5% |
| `Monty.Random.Stream`                    |           0.1 M |    1% |

Inside a _model_ step, allocation by module: `Enum` **34.2%**, `Monty.Geometry`
13.1%, `Hypotheses` 9.0%, `:erlang` 9.0%, `:lists` 8.4%, `MatcherNif.decode`
6.4%, `Stream.Reducers` 5.8%, `EvidenceSlopeTracker` 4.3%, `HypothesesDisplacer`
3.4%, the learning module itself 1.7%.

Two conclusions follow, and both are arithmetic rather than opinion:

1. **65% of a step is generic plumbing** — `Enum`, `lists`, `erlang` — and about
   19% is the algorithm. A kernel that makes arithmetic faster has almost
   nothing left to speed up; the passes themselves are the cost.
2. **Deleting the learning module entirely would be 2.3×.** The 10–30× therefore
   cannot come from one more narrow kernel, however well written.

## What a step is made of now, and where the copying is (2026-11-07)

Re-measured on the same config with the same instruments, after the studio
stopped writing a transcript to Postgres per step: **7.1 M reductions and 188 MB
of garbage a step**, 339 ms of wall clock on a machine carrying a Python run and
12 GB of swap (wall clock is quoted only to show it was loaded; the two counts
are the measurement).

| who                                      | reductions/step | share |
| ---------------------------------------- | --------------: | ----: |
| `Monty.Runtime.LearningModuleServer`     |           3.6 M |   51% |
| the caller's own process (orchestration) |           1.9 M |   26% |
| the two `SensorModuleServer`s            |           1.3 M |   19% |
| `Monty.Random.Stream`                    |           0.1 M |    2% |
| `Monty.Runtime.Step`                     |           0.1 M |    1% |

Allocation, largest first: **`gen_server:loop/5` 71.5%**, `MatcherNif.decode_one`
3.8%, `Geometry.dot` 2.6% (57 888 calls a step), `EvidenceSlopeTracker.write_slot`
2.1%, `Enum.map` 2.1%, `Hypotheses.gather` 1.9%, `MatcherNif.decode` 1.9%,
`Enum.with_index` 1.9%, `Enum.take` 1.3%, `Geometry.transpose` 1.3%.

**`gen_server:loop/5` is where a term crossing a process boundary is copied onto
the receiver's heap.** The step's replies are `:ok`, so the weight is in what the
step sends. One step's observations, as they are handed to the sensor modules:

| key                 |                  per sensor | why it is that size                    |
| ------------------- | --------------------------: | -------------------------------------- |
| `semantic_3d`       |                      512 kB | one row per pixel, as a list of floats |
| `sensor_frame_data` |                      512 kB | the same points in the sensor's frame  |
| `rgba`              |                      257 kB | pixels, as lists of floats             |
| `depth`             |                      129 kB | pixels, as lists of floats             |
| `semantic`          |                       65 kB | one id per pixel                       |
| the whole step      | **2.9 MB** over two sensors |                                        |

A float in a list costs four words on the heap, so each of those arrays is four
times its payload before it is copied, and it is copied into the process that
reads it.

**That copy is not worth optimising, measured rather than argued**
(`scripts/probe_copy_cost.exs`, 2026-11-07): one step's observations cost
**1 582–1 748 µs to hand to a process as nested lists, and 1 µs as flat
binaries** — 369 439 words against 325, because a binary over 64 bytes is
reference-counted and shared rather than copied. Against a step of ~275 ms it is
**under 1 %**, and even if it happened twice per step a full rewrite of the
worlds, the transform and the sensor modules to carry binaries would buy about
1 %. The 71.5 % of _allocated words_ under `gen_server:loop/5` is therefore not
this payload: tprof's word column counts allocation inside the frame, not the
size of the terms, and it must not be read as "the messages are the cost".

Two things that are _not_ worth doing, measured rather than assumed:

- **Copying a learning module's state.** It is 55.5 MB on the wire and
  `Model.state/1` costs 176 ms — but it is called **once per episode**, by
  `Logging.report/3`, not per step: every per-step call (`:step`, votes, goals,
  terminal state) answers `:ok` or a number, which is why `Model.status/1` is
  2 µs. A mutable state behind a NIF would optimise a cost the step does not pay.
- **Deleting `sensor_frame_data`.** It is 512 kB a sensor a step and nothing this
  port runs reads it — Monty reads it in `point_cloud_features`, and this port
  computes normals and curvatures from `semantic_3d` instead. But Monty's
  `DepthTo3DLocations` produces it, and `depth_to_3d_locations_test.exs` asserts
  that it does, so removing it is a parity break dressed as an optimisation.

## Where a step's time actually goes, by function (2026-11-07)

`eprof` over one step with every process profiled — the totals are inflated and
must not be quoted, but the ranking holds, and it is the ranking that decides
what to write:

| function                                           |  share | calls/step |
| -------------------------------------------------- | -----: | ---------: |
| `Enum`'s map internals                             | 10.8 % |    474 097 |
| `gen_server:decode_msg/4` — a message is copied in | 10.5 % |         17 |
| `Enum`'s reduce fold                               |  3.6 % |    248 226 |
| `KdTreeNif.nearest_many/3`                         |  3.3 % |         10 |
| `Enum.take_list/2`                                 |  3.0 % |    215 328 |
| `MatcherNif.decode`'s list comprehension           |  2.4 % |    107 996 |
| `Enum.with_index_list/2`                           |  2.1 % |    137 859 |
| `Stream.Reducers.zip_list_heads_tails/3`           |  2.1 % |    173 565 |
| `Enum.filter_list/2`                               |  2.0 % |    109 430 |
| `Enum.drop_list/2`                                 |  1.9 % |    274 717 |
| `Stream.Reducers.zip_list/4`                       |  1.7 % |     55 035 |
| `Hypotheses`'s `gather/3` fun                      |  1.3 % |    125 120 |
| `MatcherNif.decode_one/1`                          |  1.2 % |    107 154 |
| `Enum.count/2`, both frames                        |  2.1 % |     69 636 |
| `lists:reverse/1`                                  |  1.0 % |    113 250 |
| `Monty.Geometry.dot/2`                             |  1.1 % |     80 886 |

**About 30 % of a step is generic `Enum`/`lists`/`Stream` machinery, and every
one of those rows is a pass over the hypothesis arrays.** The primitives those
passes call are cheap — `Geometry.dot/2` is 6 reductions a call and
`Geometry.transpose/1` is 6, measured by `scripts/probe_hypothesis_cost.exs`, and
together they are 2 % of a step. What costs is the walking: 474 097 maps, 274 717
drops and 215 328 takes a step, each building an intermediate list.

So the change worth writing is **one packed pass over the hypothesis set**
(evidence, locations, poses and possibility, as the binaries `pose_bytes`,
`location_bytes`, `values_bytes` already carry), replacing the four or five
separate walks with one. That is a batched kernel, not a faster `dot`.

**Checked before writing it, and it is partly there already.** The columns are
already binaries (`Hypotheses.evidence_bytes/1`, `locations`, `poses`),
`take/2` and `rows_at/2` select with `binary_part/3` rather than walking lists,
and the displacement — the biggest per-hypothesis arithmetic — is
`MatcherNif.displaced_locations/3` when the kernel is loaded, with a list-based
`reference_moved/2` kept for parity.

**And a call graph says where the walks are** (`fprof`, one step, the learning
module's process only: 2 539 575 calls, 4 357 own units). By accumulated time
inside that process:

| what                                                   |      accumulated | own |                                calls a step |
| ------------------------------------------------------ | ---------------: | --: | ------------------------------------------: |
| `Enum.map/2` and its internals                         | **1 958 (45 %)** | 893 |                                  **25 957** |
| `MatcherNif.decode/1` → `decode_one/1`                 |       440 (10 %) | 441 |                      862 (≈127 values each) |
| `Enum.slice/3` → `slice_forward` → `slice_list`        |       420 (10 %) |  32 |                                  **16 293** |
| `Enum.reduce/3` fold                                   |        399 (9 %) | 399 |                                     199 813 |
| `Enum.take_list/2`                                     |        306 (7 %) | 306 | 161 250 (144 957 of them its own recursion) |
| `Enum.filter_list/2`                                   |        257 (6 %) | 257 |                                     102 746 |
| `Enum.with_index_list/2`                               |        257 (6 %) | 257 |                                     128 370 |
| `Hypotheses.gather/3` fun                              |        128 (3 %) | 128 |                                     128 320 |
| `EvidenceSlopeTracker`'s `indices_where`, `remove_hyp` |           51, 51 |     |                             102 656, 25 664 |

So it is **not one hot loop**: it is **~26 000 small `Enum.map`s a step**, each
over a hypothesis list of about a dozen rows, plus 16 293 `Enum.slice`s that walk
a list to select from it. Collapsing _one_ of them would be lost in the noise;
what is worth writing is one pass that answers the questions those 26 000 maps
are asked — and the `slice`s disappear on their own if selection goes through
`Hypotheses.take/2`'s `binary_part` instead of list slicing, which is already
written and used elsewhere.

Two numbers keep the earlier suspicions out of the way: the payload copy is
**10.5 %** (`gen_server:decode_msg` — the 2.9 MB of observations measured at
1.6 ms above), and the hypothesis primitives are **2 %**.

## What the native kernels have bought

22 M reductions and 212 MB a step before them; 9 M and 85 MB now — from the
probe, whole VM, 2026-11-04. Seven kernels
in two Rustler crates (`native/kd_tree_nif`, `native/matcher_nif`): feature
evidence, neighbour evidence, principal curvatures, displaced locations, window
slopes, spread of one channel's evidence over the whole set, plus the graph's
flattened arrays and the k-d index. Each has an Elixir reference that stays
runnable and a parity test that compares the answers **exactly**, because the
kernel performs the reference's arithmetic in the reference's order.

The hypothesis set's own columns are the same idea without a kernel: `locations`
(`n*3` f64) and `poses` (`n*9` f64) are held as bytes and read through
`Hypotheses.locations/1`, `location/2`, `poses/1`, `pose/2`, so a step no longer
builds three and nine boxed floats per hypothesis to hand to a kernel.

`EvidenceSlopeTracker` is the same idea applied to a _state_: its windows are a
ring of `hypotheses * window` f64 with one shared cursor, because every window
slides by one slot on the same update. Recording a step writes one value per
hypothesis and moves the cursor, and `window_slopes` reads the ring in order;
sliding ten-slot lists a step was the single largest thing the module allocated.
That change alone: **10.8 M → 9.1 M reductions a step** (−16 %), the learning
module 6.1 M → 5.2 M, ladder unchanged digit for digit.
`spread_add` closes the same gap one function further down the step: the
neighbour kernel's answer used to be decoded into boxed floats and then walked
once per hypothesis per channel to be spread over the whole set, with a map
lookup per hypothesis. It now stays bytes from the kernel to the column it adds
to: **9.1 M → 8.9 M a step**. Smaller than the tracker's win, and honestly
stated as such — the three runs after it (8.83, 8.87, 8.92 M) all sit below the
three before (9.08, 9.09, 9.14 M), which is what makes it a result rather than
noise, but only just.

The evidence column itself is the last of the four, and it is the one that
teaches the lesson. Holding it as bytes was **worse** than holding it as a list
until every read that needs no per-value work had a kernel of its own: the
displacer's threshold test, the blend of past and present evidence, and the
argmax that says where the past was largest. Written in that order the change
goes **+39 %, not −4 %** — 11.6 M to 16.1 M call-memory words a step, 372 k
decodes of a column nobody was going to read value by value. With
`indices_at_least`, `blend_evidence` and `argmax_index` in place and the readers
decoding one row instead of the column, the same probe reads 11.1 M.

Measured the way the acceptance section asks, interleaved against the tree
before it — three pairs, alternating, so the machine's load is shared:

| pair | before                    | after                    |
| ---- | ------------------------- | ------------------------ |
| 1    | 11.25 M reductions, 87 MB | 9.60 M reductions, 85 MB |
| 2    | 9.58 M, 87 MB             | 8.91 M, 85 MB            |
| 3    | 10.21 M, 87 MB            | 9.03 M, 85 MB            |

The megabytes do not move between runs; the reductions move with the load, which
is why three pairs beat one number. −2.3 % of a step's garbage for a column that
used to be decoded 108 679 times a step, and −1 % to −12 % of its reductions,
read as a range rather than a figure.

## The next change: one crossing

A matching burst walks the hypothesis set about **47 times with an index** and
about **91 times through `Enum.map`**, per hypothesis. Merging any two of those
converts 6 M reductions into 5.9 M. The change that matters is one call that
carries a burst's whole non-RNG path — displace → neighbour evidence → spread
over every hypothesis → blend with the past → slope windows → possible mask →
argmax — and hands back the columns the module keeps.

It has to stay separable, because the sampling half draws from the RNG stream and
must keep doing so in Monty's order: the burst's _shape_ (where new hypotheses
go) stays in Elixir; what they earn, and every pass over what already exists,
crosses once.

Two vehicles, both keeping the Elixir reference and its parity tests:

- **Extend `native/matcher_nif`.** No new dependency, rides the crate that is
  already built and tested in CI, and the rows are scalar loops that need no
  compiler. Costs: hand-written Rust for each stage, and the RNG must stay on the
  Elixir side by construction.
- **Add `nx` + `exla`.** The standing ask on record, and the array ops are what
  Nx is for. Costs: a compiler dependency, a large addition to the release, an
  EXLA build in CI, and a `defn` boundary per stage.

**This is an open decision.** It is written down here rather than half-made in
the code.

## Acceptance for any speed change

1. `mix monty.run base_config_10distinctobj_dist_agent --episodes 1 --steps 8 --no-record`
   prints the same eight lines, digit for digit: `0.908 (802, 4)`, `2.55 (1604, 5)`,
   `4.086 (2406, 2)`, `5.675 (3208, 1)`, `7.032 (4010, 1)`, `8.639 (3509, 1)`,
   `10.15 (2899, 1)`, `11.712 (2342, 1)`.
2. A parity test compares the new path with the reference **exactly** (`==`), not
   approximately, and the reference stays callable behind
   `config :ex_tbp_monty, native_kernels?: false`.
3. Quote a pair of measurements from one run; never a single wall-clock number.
4. `scripts/quality.sh` prints `quality: ok`, and formatting is bare
   `mix format` — `mix format <dir>` does not reach files nested below it, and a
   subset `--export-coverage` poisons the `mix complexity` gate (it then reports
   ~200 functions "above CRAP 20" that are simply 0% covered).

## Tried and rejected

- **`Geometry.mul/2` and `Geometry.apply/2` written out as 3×3 formulas.**
  13 k and 19 k calls a step, arithmetic identical — and no measurable change
  (10.81 → 10.88 M reductions, 81 → 78 MB). Reverted: below the noise floor, so
  the code stays the simple version.
- **Nesting binary concatenation to rewrite one column of a ring.** The first cut
  of the slope tracker wrote each row with `<<skipped, value, rest::binary>>`,
  which copies the remaining tail at every row — quadratic in the hypotheses. It
  cost more than the list shifting it replaced (11.6 M and 5 168 GCs a step
  against 10.8 M and 500) until the pieces were gathered and joined once with
  `IO.iodata_to_binary/1`, which is when the win appeared (9.1 M).
- **A full sort of the graph to take a few hundred nodes** (`top_indices/2`) is
  still there. A bounded selection returns the same indices and is worth trying
  when it can be measured on its own.
- **Caching the graph's arrays twice over** — done, and it is where most of the
  earlier win came from; nothing else in the cache family has measured flat.

## Half a step was a process spawn (2026-11-06)

`tprof` on a real step put **50.6 % of the time in `erlang:spawn_opt/4`** (7 calls,
372 ms) with `call_timeout: :infinity`, while the biggest algorithm entry was
`Enum.map` at 6.5 %. A reduction count could not see it: `spawn_opt` is a BIF, and
the step's reductions stayed at ~7.9 M before and after the change that removed it.

**What it was.** `Monty.Runtime.Barrier` starts a process per request so a round's
deadline can kill it, and `spawn_monitor` copies the request's closure into that
process — and a sensor request _is_ the payload, closing over the observations
(394 202 words ≈ 3.2 MB a step). Measured directly: seven spawns carrying 400 000
words cost **83 ms**, seven carrying nothing cost **32 µs**.

**The change.** A round of _one_ request with no deadline has nothing to kill and
no concurrency to lose, so it runs where it was called. Rounds of several requests
keep a process each, deadline or none — they start together, and serialising them
would trade a constant for a factor of the module count. `missing?/1` decides "no
answer" for both paths, so failure semantics are one definition, not two.

**Measured.** Acceptance ladder unchanged digit for digit (`0.908 (802, 4)` …
`11.712 (2342, 1)`); the same steps on the same machine went from 1.1-1.4 s to
**84-477 ms** (cold step 827 ms). The five-LM config takes the untouched
multi-request path (4.4 s/step, 31.5 M reductions) — its cost is the
per-hypothesis pipeline, not the round.

**Next, in the profile's order**: observations as immutable flat binaries (a refc
binary crosses a process boundary as a pointer — within a node only; across nodes
everything is copied), then `MatcherNif.decode`/`decode_one` (18 % of allocation),
then the per-hypothesis plumbing (`gather`, `with_index`, `take` — ~18 % — and a
batched `Geometry.dot`, 9 %). `nearest_many` is 2 % of the step, so more k-d work
is not where the time is.

## The profiler's time column is not a measurement (2026-11-06)

`tprof` charges what it costs to be profiled. Mapping 6 432 elements 200 times
costs **24.6 ms by the clock**; the same loop inside the profiler reports
**402.7 ms** — sixteen times — of which 288.7 ms is `Enum.map`'s own loop and
112.6 ms the closure it calls. `scripts/probe_tprof_overhead.exs` is that
comparison and nothing else.

So the step profile is read for two things only: **call counts**, which are real,
and **words allocated**, which are real. Its time and per-call columns are a
distribution weighted by call count, and they exaggerate the most-called
functions worst: `Enum.map`, 306 050 iterations in a step, was credited 29 % of
it. The honest currency is reductions, garbage and wall clock — plus a
microbenchmark of the candidate change, as in `scripts/probe_decode.exs`.

**What the counts say.** With 6 432 hypotheses, one step runs 306 050 `Enum.map`
iterations, 33 127 `Enum.reduce`, 29 897 `take_list`, 22 856 `with_index_list`,
17 477 `filter_list` and 10 881 `Geometry.dot` — some sixty passes over the
hypothesis lists. `Geometry.dot` spends ten words a call and `transpose` 22,
which is the arithmetic itself, and after `decode` there is no longer a single
wasteful allocator. The remaining cost is the number of crossings, not the price
of one.

**What that means for the order of work.** Reading a column's floats as halves
cost 20 % of the decode and moved a step by 3 %, because decode was 8.7 % of the
step. Shaving one pass is worth a few percent; removing sixty of them is the
factor that is missing. That is the conclusion of the round above, arrived at
from the other side: the work has to cross once, not once per hypothesis.

**Measured, this change.** One 6 432-value column: 941 µs → 753 µs, 11.8 → 7.7
words per value. A step of `base_config_10distinctobj_dist_agent`: 7.87 M → 7.65
M reductions, 81 MB → 78 MB of garbage, and the suite green at 2 269 tests
including the seven that now describe `decode/1` itself.

## The whole experiment runs to its end (2026-11-06)

`mix monty.run base_config_10distinctobj_dist_agent`, left alone: **140 of 140
eval episodes, every one ending in a recognition** — `learning_module_0: match`,
the object named at a position and rotation — in 4 789 steps and 3 942 s: 823 ms
a step on a machine at load 10.6, exit 0.

The steps are the experiment's own. Monty's dashboard runs 140 episodes in 5 122
eval steps and 3:18, which is ~39 ms a step, so what is left between us is
per-step cost — 21 times — and not the shape of the run. Earlier attempts were
stopped by hand around episode 90; this is the first that reached the last one,
which is what the acceptance asked for.

**The 823 ms was the machine, not the code.** That run was measured at load
average 10.6-14.7 — another build was using the box throughout. The same
experiment, on the same code path after `fc0a063`, ran at load 3.7-5.9 and
finished in **4 789 steps in 203 s: 42.5 ms a step**, exit 0, **140 of 140
episodes each ending in a recognition** — against Monty's ~39 ms. The step count
and the goal total (4 558 928) are identical to the loaded run, so the two runs
are the same run, one of them slower for reasons outside the program. Reductions
are the only per-step figure worth comparing across machines (7.65 M → 6.85 M),
and the acceptance target of ~50 ms a step at ten objects is met on a quiet
machine — the earlier "21 times" was a loaded-box artefact and is withdrawn.

## A per-episode copy is not free, and a training phase would pay it (2026-11-06)

Measured on `base_config_10distinctobj_dist_agent` (ten objects, pretrained memory,
`MIX_ENV=test`), while wiring a training phase to carry its memory between
episodes:

| what                                                      | cost                                                           |
| --------------------------------------------------------- | -------------------------------------------------------------- |
| `Run.start/2`, pretrained memory                          | 1.9 s, 35 M reductions (world + positioning, as Monty pays it) |
| `Run.memories/1` — the memory read back out of the module | **177 ms, 203 k reductions**                                   |
| a step, after the first                                   | 5.7–6.1 M reductions, 23–84 ms                                 |

177 ms is two to four steps of work for one copy, because `LearningModuleServer.state/1`
sends the module's whole state across to the caller and the graph memory of a
ten-object model is tens of megabytes. That is the cost `detailed/2` was written
to avoid for the page's per-step reads, and the loop had walked into it once per
episode.

It is now read only where it can have changed: **an evaluation episode writes
nothing into long-term memory, so it neither writes nor reads the memory back**,
and the phase keeps the value it started with. `memories` is a value, so passing
the same one to the next run is also cheaper than re-loading it (`Setup.memories/1`
→ `Memory.load/2`, about twenty milliseconds a call).

**The erlang-shaped fix, when a training phase is actually offered**: keep one
model for the phase and reset the episode on it (`Model.reset_episode/1`, which
Monty calls as `model.reset()`) instead of starting a model per episode. Then the
memory never crosses a process boundary at all, and the flattened arrays the
native kernels read (`node_arrays`, `feature_rows`) stay in the process that
built them. Measured here, a fresh model's first step is _not_ noticeably more
expensive than a later one (5.1 M reductions / 23 ms against 5.7 M / 81 ms), so
this is worth doing for the copies rather than for the arrays — it is a tidier
shape, not a large win on this config.

**Where the scaling win actually is**: a step's cost is per hypothesis, and the
hypotheses of one graph are independent of another graph's. Barriering modules
across a step already exists; sharding _a module's_ graphs across schedulers, one
task per graph, is the thing the BEAM does that a GIL-bound Python cannot. That is
the work to do before claiming a speed advantage over Monty at seventy-seven
objects, and it should be measured the same way — reductions and wall clock, run
paired against the serial version in one session.

### Runs scale across cores, and that is measured (2026-11-06)

`MIX_ENV=test`, `base_config_10distinctobj_dist_agent`, five steps each:

|                                | wall                          |
| ------------------------------ | ----------------------------- |
| one run (start, 5 steps, stop) | 2 548 ms                      |
| two runs, started together     | 2 619 ms — **1 310 ms a run** |

Two runs cost 1.03 times the wall time of one, so throughput nearly doubles with
the run count: each run is its own set of processes and the schedulers spread
them. That is what the experiment page's "runs side by side" setting and the
queue's `studio: 2` already use.

It is worth being precise about what this does and does not say. Monty can run
two experiments side by side too — as two Python processes — so run-level
parallelism is not by itself an advantage; what the BEAM adds is that it happens
_inside one node_, one scheduler pool, one set of immutable binaries shared by
reference instead of copied, and one queue that knows what is running. The
advantage that a GIL-bound Python cannot take at all is the next one: sharding a
single step's per-graph work across schedulers, described above and **still
unmeasured**.

## The run of 1:42 h, and what it was paying for (2026-11-09)

Setup: the user's own run of `base_10simobj_surf_agent` on this machine,
`7339fa92…` — 140 episodes, **42 401 steps, 6 130 s of wall clock**. Its own
step reports account for 2 720 s of that; the rest was paid outside the steps.

The reference is Monty's Python, run on the same machine on the same config
(`monty-orig/.venv`, `experiment=base_10simobj_surf_agent`, one epoch), read from
its own `eval_stats.csv`:

|                            | Monty (Python)              | this port              |
| -------------------------- | --------------------------- | ---------------------- |
| steps in the sample        | 1 774 (177 an episode)      | 1 072 (107 an episode) |
| steps the module was given | 260 — **15 % of the steps** | 6 of 40 — **15 %**     |
| wall                       | **16.8 s — 9.4 ms a step**  | 104 ms a step          |
| wall per matching step     | **64 ms**                   | ~420 ms                |

The shape agrees — one matching step in seven, the same evidence scale — so the
gap is cost, not behaviour.

### Where our 6 130 s went

| what                                        | measured                                 |
| ------------------------------------------- | ---------------------------------------- |
| the model step, as the run reported it      | 2 720 s (44 %)                           |
| between two episodes (139 boundaries)       | **869 s (14 %)**, growing 1.8 s → 9 s    |
| the fixed cost of a step, outside the model | ~33 ms × 42 401 ≈ 1 400 s (23 %)         |
| the rest of the tail                        | the page's poll and the writes it fought |

The boundary cost grew with the row, which is the signature of a write that
rewrites what it appends to: `jsonb || jsonb` is one statement, but Postgres
still writes the whole value. Measured on that row, appending an **empty** array
took **14.7 s**. The transcript is 122 B a step and the pictures 10.4 kB, and
both were appended at every boundary.

The page's poll was the other half: `reconcile/1` read the **whole row twice a
second** (`RunHistory.get/1`) — 252 MB by the end of that run, per request, while
the run was trying to step.

### What changed, and what it cost before

| change                                                                      | before                                       |
| --------------------------------------------------------------------------- | -------------------------------------------- |
| the page polls the row's scalars (`RunHistory.progress/1`)                  | 252 MB twice a second                        |
| the transcript is the stream's, not the record's (`RunStream.steps_from/2`) | `log ++ [entry]` per step — O(n²) in the run |
| a boundary writes the transcript; the settle writes the pictures once       | 14.7 s an append by the end of a run         |
| beliefs are read only when a module was fed                                 | 5.7 ms on 83 % of the steps                  |
| a step's pictures are encoded once, in the stream                           | two PNGs a sensor encoded twice              |

The boundary is now the same 1.8 s at episode 1 and at episode 10 (measured: 10
episodes, 1 072 steps, 114 s wall, 68 ms of model a step), and the row is written
in one statement as the run settles.

### The actor shell is not the gap

One step's observations are **435 189 words — 3.5 MB** of heap (863 kB on the
wire). One cross-process copy of them is **0.53 ms**, and a processed step makes
about twenty `gen:do_call`s. So the messages a step pays are ~2–3 ms of 104 ms:
**about 3 %**. The shell is the studio, the stop button and the replay, and it is
not what separates us from Python.

### Where the other 97 % is, per step

| phase                                           | a step the module was given | a step it was not |
| ----------------------------------------------- | --------------------------: | ----------------: |
| the world (MuJoCo, in the embedded interpreter) |                     10.2 ms |           10.6 ms |
| the transform chain (depth → 3-D points)        |                      6.4 ms |            6.4 ms |
| the model step                                  |                      416 ms |             20 ms |

Monty's _whole_ step is 9.4 ms. Two things follow, both arithmetic:

1. **The floor is 37 ms**, of which 17 ms is world and transforms — work Python
   does with numpy in under a millisecond. The transform chain is six passes of
   Elixir closures over 4 096 pixels (`DepthTo3DLocations`, 32 768 `count/4`
   closure calls a step).
2. **A processed step is 6× Monty's whole step.** The profile of one: 267 834
   `Enum.map` iterations, 255 648 `take_list`, 99 966 `Geometry.dot`, 188 MB of
   garbage — ~60 passes over a hypothesis list of a few thousand. Monty does a
   handful of numpy ops over an (H, ·) array.

So the order for the next session is: the per-hypothesis passes (an order of
magnitude is available, and it is the one thing that would put us ahead of
Python), then the transform chain and the sensor patch maths as kernels or Nx,
then whatever the profile says about the world.

One thing deliberately left: the run's own page (`/runs/:id`) still reads
`head/1` — the transcript without the pictures — every two seconds while its run
is in flight, because it appends the lines it has not shown and redraws the
replay from them. That is 3 MB at 24 329 steps and about a fortieth of what the
experiment page was reading, but a transcript that a page re-decodes twice a
second wants a child table (one row a step, or one an episode) rather than one
`jsonb` array in one row. Nothing reads the pictures that way: `sensors_at/2`
asks for the step the slider is on.
