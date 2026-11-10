# Speed

What a step costs, what has been measured, and what is left. Everything here is
a measurement from this machine, quoted with the experiment it came from — not a
target.

The reference is Monty's own dashboard: `base_config_10distinctobj_dist_agent`,
10 objects, 14 epochs, **~39 ms a step** (5 122 eval steps in 3:18). One run of
this port reached 140/140 episodes at 0.61 s a step, so the _episode_ is right
and the _step_ is what is open.

## How to measure, and what lies

| what                             | how                                                                                                                                                                         |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| work and garbage per step        | `MIX_ENV=test mix run scripts/probe_step_cost.exs [experiment] [steps]`                                                                                                     |
| where in a step it is            | `MIX_ENV=test mix run scripts/probe_step_phases.exs [experiment] [steps]` — the world against the model, and reductions per process, a processed step and a plain one apart |
| who did the work                 | the same script — it prints reductions per process, labelled by callback module                                                                                             |
| allocation per function          | `MIX_ENV=test mix run scripts/probe_step_profile.exs` (tprof over one `Model.step`)                                                                                         |
| the whole run, as a user sees it | `mix monty.run <experiment> --episodes 1 --steps 8 --no-record` — the acceptance ladder                                                                                     |

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

## Measured 2026-11-09: the cost is spread, not concentrated

`MIX_ENV=test mix run scripts/probe_step_profile.exs` — `tprof`, `rootset: :all`,
one processed step, 497 ms as the step timed itself.

**Read the allocation column, not the time one.** `tprof`'s `call_time` is entry
to exit, so a blocking `GenServer.call` carries the callee's whole run: the same
second appears again under everything the callee called. The proof is in the same
report — `gen:do_call/4` shows 314 ms there and **9 821 words allocated, 0.04 %**
here. It measures the wait, not the work. Wall clock is for the step's own figure
(`duration_us`), on a quiet box.

Self-allocated words, one step — what is actually built:

| function                                                                       | calls   | words     | share      |
| ------------------------------------------------------------------------------ | ------- | --------- | ---------- |
| reading a kernel's answer back (`MatcherNif.decode_one/1` + its comprehension) | 164 126 | 1 248 498 | **5.66 %** |
| `Geometry.dot/2` + `transpose/1` + `mul/2`                                     | 90 160  | 883 648   | **4.00 %** |
| `EvidenceSlopeTracker.write_slot/5`                                            | 19 306  | 463 224   | 2.10 %     |
| `Enum.map`'s closure                                                           | 254 588 | 457 154   | 2.07 %     |
| `Hypotheses.gather/3`'s closure                                                | 64 320  | 424 512   | 1.92 %     |
| `Enum.with_index_list/2`                                                       | 83 676  | 418 080   | 1.89 %     |
| `Enum.take_list/2`                                                             | 161 272 | 289 936   | 1.31 %     |

(`gen_server:loop/5`'s 71.5 % is a process's whole life, its children included —
a root, not a function.)

What this settles:

- **There is no hot spot to kernel.** The largest single item is 5.7 %, and it is
  _our own_ readback: a kernel answers in a binary and the port boxes each value
  one at a time. `Geometry` together is 4 %, `transpose/1` costing 22 words for a
  3x3 — and `batch_rotate_pose_vectors/2`, which this file named as the next
  kernel, **has no production caller at all**, only its test. Measured, not
  assumed; that claim was wrong.
- **The readback is ten decodes of one column.** `decode_one/1` runs 80 420 times
  a step and the hypothesis count is 6 432: the same evidence column is decoded
  at about ten callers per step, each wanting a different statistic (max, second
  argmax, sum, a zip with indices, the logger's copy). Keeping the column as
  bytes is right for the kernels; the waste is decoding it afresh at each reader.
- **Everything else is list plumbing** — `map`, `with_index`, `take`, `gather` —
  a couple of per cent each, and dozens of passes.

So the remaining cost has the shape the section above already names: a step is
~500 ms of many small passes over the hypothesis set, not one expensive function.
The change that matters carries a whole phase across once and hands back the
columns the module keeps.

**Done so far: the slope mask (`d59827f`).** `select_hypotheses/2` asked for the
slope column, paired it with the ages and walked the pairs — a decode of one
float per hypothesis and three list passes over the set — to decide one bit per
hypothesis. `MatcherNif.keep_mask/7` decides it inside the kernel, which already
has the slopes, so the column never becomes Elixir terms: `decode_one` fell from
80 420 values a step to 67 556 (the two per-graph slope columns), and the
`zip`/`map`/`removable` passes are gone. The Elixir path stays as the reference
behind `native_kernels?: false` and two parity tests compare the masks exactly;
the acceptance ladder is unchanged digit for digit.

**Then the tracker's write (`26a8f73`'s neighbour).** `EvidenceSlopeTracker.update/3`
wrote one column into every window with a three-part iolist per hypothesis and a
flatten over all of them — 24 words a hypothesis, 19 306 calls a step.
`MatcherNif.write_slot/4` is a copy with a column replaced, the Elixir walk stays
as the reference, and a parity test compares the window bytes at every step of a
ten-update wrap. `write_slot` is gone from the profile (463 224 words a step).

The same shape is what the rest needs: `MatcherNif.decode/1` still runs 3 286
times a step at ~24 values each, and
`HypothesesSelection.ids_to_retain/1`/`ids_to_remove/1` still walk the mask with
`with_index`, `filter` and `map` — a kernel that answers the indices directly
would remove both.

## Measured 2026-11-09: a run gets slower as it learns, and it is not the episodes

The question was whether episodes accumulate. They do not — and the run still
gets slower. From the record of `7339fa92-…` (140 episodes, 42 401 steps,
`priv/studio_runs/<id>/run.log` has every step's own `duration_us`):

| quarter of the run | steps  | unprocessed step | processed step | hyps at a processed step | max   |
| ------------------ | ------ | ---------------- | -------------- | ------------------------ | ----- |
| 1–35               | 10 147 | 4.32 ms          | 278.6 ms       | 892                      | 8 880 |
| 36–70              | 8 532  | 4.80 ms          | 373.8 ms       | 1 279                    | 8 887 |
| 71–105             | 11 698 | 5.01 ms          | 352.1 ms       | 761                      | 8 880 |
| 106–140            | 10 966 | 5.68 ms          | 382.9 ms       | 984                      | 8 936 |

- **The transient state does reset.** In a fresh three-episode run every episode
  starts at the same hypothesis count (712) and the per-step mean _falls_
  (38.0 → 36.7 → 30.9 ms). Nothing accumulates per episode.
- **Hypotheses are not the cause.** The count at a processed step has no trend
  across the run and the maximum is flat at ~8 900.
- **What grows is the shared long-term memory.** Every step reads the graphs, so
  the _unprocessed_ step slows by the same third as the processed one — a step
  that does no matching still pays for what the run has learned. Episodes are
  independent in what they hold, not in what they read; that is the experiment's
  design, and Monty's.
- Cost of a step therefore rises with nodes per graph, not with the episode
  index. **The mechanism is not yet proved** — the next measurement is nodes per
  graph at the start and the end of a run, and which per-step path is linear in
  it. Two candidates already visible: `GraphObjectModel.num_nodes/1` is
  `length(positions)` (O(nodes)) and `GraphMemory.get_graph_node_ids/3` builds
  `0..n-1` as a list, so any per-step caller of either gets slower as the graph
  grows.

## The step's road to the page is one way (2026-11-09)

A step's transcript is the experiment's record, not its work. The step takes its
snapshot and hands it over; nothing a page draws is _made_ on the step, and
nothing a page has is _asked for_ from the step.

```
worker (Jobs.Run)                    presenter (RunStream)          reader
  step/1
    ── beliefs snapshot ─┐
    ── world's own obs ──┼── one cast ──→ entry, line, PNGs, ETS, ──→ pub-sub
    ── centre view ──────┤                 log file (in order)         → page
    ── report ───────────┘
```

The rule is one cast and no call back. Three things can only be taken by the
step and are therefore snapshotted there — the beliefs (a later read is a later
state), the world's own observation (the world has stepped again by the time a
presenter runs) and the centre view's geometry. Everything else is derived on
the far side.

`scripts/probe_step_ledger.exs` puts a number on each term
(`base_10simobj_surf_agent`, 15 steps):

| term                           | on the step, before | on the step, now |
| ------------------------------ | ------------------- | ---------------- |
| beliefs read (snapshot)        | 612 µs              | 531 µs           |
| the record's entry             | 509 µs              | —                |
| the log line                   | 117 µs              | —                |
| centre view                    | 57 µs               | 161 µs           |
| the cast (what the copy costs) | 541 µs              | 543 µs           |

The presenter now builds the entry and the line from the report in **90 µs**.
The centre's and the beliefs' figures move by ±100 µs between runs — they are
allocated right after the cast's copy, so they carry its collection — and on a
step of 76 ms none of this is a speed win. What the split buys is a boundary
that cannot grow: the message used to carry the beliefs twice, as the structs a
page draws and as the string-keyed copy a row keeps, and a step that formatted
its own text had a second definition of what a step looks like.

## Measured 2026-11-10: a processed step is the learning module, a plain one is the sensor module

The step has been measured as a whole until now. Split in two, with the world run
outside the timer and only `Model.step` inside it — `MIX_ENV=test mix run
scripts/probe_step_phases.exs base_10simobj_surf_agent 40`:

- **processed step**: world 14 ms, model 288–1 049 ms of wall, and of that a
  processor's own time (`:erlang.statistics(:scheduler_wall_time_all)`, µs summed
  over the schedulers, after `:erlang.system_flag(:scheduler_wall_time, true)`)
  is the same order as the wall — the step is heavy, not starved.
- **plain step**: world 23 ms, model 7–15 ms.

The model's own step is therefore almost all of a processed step, and the
renderer and transforms that the sections above chased are a few per cent of it.

Then per process, in reductions, which do not move with the load:

| step          | learning module | coordinator | patch sensor module |
| ------------- | --------------- | ----------- | ------------------- |
| processed (1) | 3 292 083       | 1 005 689   | 665 695             |
| plain (39)    | 378             | 13 723      | 637 878             |

Two things follow, and both change what to optimise next.

1. **In a processed step the tight loop is the learning module**, at 66 % of the
   step's reductions. The coordinator is second at 20 %: it is not just a router
   — the vote round and the motor system cost it a fifth of a processed step,
   against 2 % of a plain one. The sensor module is 13 %.
2. **A plain step costs about a sixth of a processed one**, and nearly all of it
   is the sensor module (637 878 of ~652 000 reductions); the learning module is
   a rounding error in it. How often a processed step comes is the episode's
   business — one in 40 in this window, one in six in a window of 60 — so quote
   per-step means and never a total over a mixed window.

Neither "the learning module" nor "the periphery" is the whole answer: a
processed step is the learning module and the round around it (fix the
per-hypothesis loop), and a plain step is the sensor module (fix the per-pixel
and per-point loops).

### Instruments, and what each cannot show

- `:tprof.profile(fun, %{rootset: [pid], …})` does **not** narrow the report to
  that process — the caller's own rendering still appears in it. To profile one
  phase, run the other first and replay its inputs: the observations are a
  function of the seed, and a second run of the same seed reproduces the same
  processed steps (checked — processed at 0, 14, 26 and 38 in both passes).
- `:eprof.profile([pid], fun)` counts correctly but puts a process's **idle**
  time into `gen_server:decode_msg/4` (80 calls at 7.07 ms each over 14 steps).
  Only compare busy functions within one such table.
- `Process.info(pid, :current_stacktrace)` sampling reported 84.5 % "waiting" for
  the learning module while its step was running, because every barrier leaves
  each module waiting on the others. A sample answers "who is not running",
  never "who is not the cost".
- `probe_step_cost.exs` drives `Studio.Run.step`, so its figure includes the
  world and the first steps of a fresh graph; it is a whole-step number, not a
  model number.

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

### The episode boundary is the experiment, not the port (2026-11-09)

The 1.8 s between two episodes is not a write any more. What `Run.start/2` pays
for an episode, measured one episode at a time:

| piece                                                                                              |          ms |
| -------------------------------------------------------------------------------------------------- | ----------: |
| `Setup.world/3` (the scene, as a value)                                                            |           6 |
| `Run.start/2` — the scene constructed, the agent positioned, the episode's model processes started | 1 206–1 251 |
| `Run.conclusion/1` — what the modules said, read out of their processes                            |         277 |
| `Run.next_memories/3` (eval; a training phase reads its graph here)                                |           0 |
| `Run.stop/1`                                                                                       |           8 |

Monty pays it too, and the same size: its own run of the same config took
**32.6 s** of process wall for **19.4 s** of episode step time over ten episodes —
**1 325 ms an episode** outside the steps, for the same reason (a MuJoCo scene is
built and the agent moved into view).

So the boundary is not where the port loses to Python, and making it asynchronous
would be a structural change — episode N+1's scene built while N still steps, two
worlds alive at once — not an offload of I/O. It is worth doing when the model step
is fast, because then 1.8 s an episode becomes the largest item left: at today's
numbers it is 250 s of a 4 400 s run (6 %); after a 6× faster learning module it
would be ~19 %. `Setup.world(setup, episode, opts)` is a function of the episode
index and the seed, so a prefetched scene is the same scene; what has to be proved
is that no drawn number moves.

### What a processed step calls (2026-11-09, `cprof`, one step at 8 376 hypotheses)

`cprof` counts calls, which is the one thing tprof's time column cannot be
trusted for. One step of `base_10simobj_surf_agent` that the module was given:

| module                             |   calls | largest single item                                                |
| ---------------------------------- | ------: | ------------------------------------------------------------------ |
| `Monty.Geometry`                   | 266 577 | `dot/2` 99 966, the `mul/2` closures 100 512, `transpose/1` 16 753 |
| `...Transforms.DepthTo3DLocations` | 140 263 | ten full-image passes of 8 192 (2 × 4 096 pixels)                  |
| `Monty.Simulators.Mujoco.Answer`   |  66 561 | decoding the world's arrays                                        |
| `...Utils.SensorProcessing`        |  45 395 | `cloud_bytes` 16 384, `plane_normal` 11 313                        |
| `...EvidenceMatching.Hypotheses`   |  42 242 | `pose_bytes`/`location_bytes` 8 376 each                           |

About 560 000 calls for a step that takes ~420 ms, i.e. **~0.75 µs a call**: the
cost is the per-call allocation of small lists (a 3-element dot allocates a
3-element list; a 3×3 `mul/2` nine of them), not any single arithmetic hot spot.
That closes the question the 2026-11-02 note left open ("~130 µs per hypothesis
is unexplained") — it is ~66 calls a hypothesis at Elixir-term prices.

Two consequences, and they are the work:

1. **The learning module wants one call per pass, not one per hypothesis.** The
   kernel already exists in this shape (`MatcherNif.displaced_locations/3`,
   `MatcherNif.neighbour_evidence/10`); what is left per hypothesis is pose
   evidence, feature evidence and the slope bookkeeping. Batching them changes no
   number — the parity fixtures are the referee (`evidence_*_native_parity_test.exs`).
2. **The transform chain wants the same treatment** — `DepthTo3DLocations` makes
   ten passes over the depth image per step, which is 6.4 ms a step and 270 s of a
   full run, and is a Nx expression rather than ten closures.

Neither is a cache and neither is a one-line change; both are the "one crossing"
this document has been pointing at since 2026-11-02, now with the call counts that
say which passes to cross.

## A step copied a module's memory into the module (2026-11-10) — 285 ms → 108 ms

`Monty.Runtime.Step.read_conclusions/1` asks each module what it concluded, and it
built that request as `fn -> LearningModuleServer.query(server, &lm.module.conclusion(&1)) end`
— a closure over `lm`, the module's _spec_. A spec carries `:state`, and a module
reading a pretrained memory keeps tens of megabytes there, so the closure carried
the memory with it: a `GenServer.call` copies its request into the receiving
process, so every processed step copied the module's own memory into the module and
threw it away again.

Measured on one recorded step of `base_config_10distinctobj_dist_agent`
(`scripts/probe_step_profile.exs`, `tprof` `call_memory`): the top row was
`gen_server:loop/5` at **75.7 % of the step's allocations**, attributable to no
Elixir function — that copy. Timed at the phase seam (a temporary `:timer.tc`,
since removed), `advance/1` was 150–230 ms of a 285 ms step, and inside it
`read_conclusions/1` was 178–230 ms while the projection it asked for answered in
**0 ms**.

Closing over the module's _name_ instead: **one step 285 → 108 ms** on the same
probe, and the acceptance ladder digit for digit (the test-env lines `0.746 (192,
6)` … `6.338 (1429, 2)`, `goals 15065`). `probe_step_phases.exs` agrees — a
processed step of `base_10simobj_surf_agent` read 711 ms of model time before the
fix.

The trap to keep: **a closure sent to another process is copied with its whole
environment.** The coordinator deliberately holds a module's _wiring_ rather than
its memory, but `Monty.Runtime.Step.State`'s `module_spec` still carries `:state`,
so nothing handed to a module may close over a spec.

## A surface normal was nine walks over the patch (2026-11-10) — 641 k → 261 k

`sensor_processing.ex`'s `plane_normal/1` built the scatter matrix `Xᵀ X` one cell
at a time: nine cells, each its own `Enum.sum(for point <- points, do: …)`, and
each of those passes reached into a point with `Enum.at(point, row)` and
`Enum.at(point, column)`. `Enum.at/3` on a list is a slice — it walks the row to
pick a coordinate out of it — so one surface normal cost two index walks per
point per cell. A surface agent's neighbourhood is ~1 250 points, which is **22 814
`Enum.at/3` calls, 45 632 `Enum.take` and 51 930 `Enum.drop` per step**, and they
are on every step of every run.

All nine sums are now accumulated in one `Enum.reduce` over the points, in the
points' own order, so each cell adds the same numbers in the same order as its own
walk did and the answer is unchanged bit for bit. Sensor module reductions on a
location-only step of `base_10simobj_surf_agent`: **641 240 → 261 321**; the
acceptance ladder is digit for digit.

Two lessons worth keeping:

- **`Enum.at/2` on a list inside a loop over that list is the expensive shape**, and
  a `for row <- 0..2, column <- 0..2` around it hides it well. If a pass needs
  several coordinates of the same point, destructure the point once.
- **GC is not this port's wall, whatever `:eprof` says.** For the same steps eprof
  put `erlang:garbage_collect/0` at 73 % of a processed step's time; `:msacc` over
  six steps says the scheduler spends **1.11 %** of its time in `gc` against 27.9 %
  in `emu`, and the step's own processes make no collections at all. eprof traces
  every call, and building a trace message per call inflates the heap until GC
  dominates the table it prints. Quote `:msacc` or reductions for GC, never eprof.

## What the world really costs, and the crossing that does not have to be spent (2026-11-10)

Every probe in this document runs in `MIX_ENV=test`, and `config/test.exs` sets
`world_simulator: :synthetic` — this port's stand-in scene, one sphere, ray-cast in
Elixir. A run in the studio or in production steps `:mujoco` (`config/config.exs`,
and Monty's own snapshot names `tbp.monty.simulators.mujoco.MuJoCoSimulator` for
`base_10simobj_surf_agent`). So a "world" figure from a test-env probe is the
stand-in's, not the run's, and no ray caster is on the path of a real step: MuJoCo
renders in C and we only talk to it.

Measured with the same probe against the MuJoCo world (`world_simulator: :mujoco`
forced before `Studio.open/1`), per steady-state step of `base_10simobj_surf_agent`:

| stage         |                            cost | what it is                                                                                                                              |
| ------------- | ------------------------------: | --------------------------------------------------------------------------------------------------------------------------------------- |
| Python        |                         7–10 ms | MuJoCo steps the scene and renders each camera                                                                                          |
| the crossing  |                           ~0 ms | `Pythonx.decode` of one **132 KB** binary; the arrays already cross as bytes (`world.py::_answer`: a JSON header, a newline, the bytes) |
| answer decode |                          1–4 ms | `Monty.Simulators.Mujoco.Answer` — every array's bytes become boxed floats in nested lists                                              |
| transforms    | 5–7 ms, **~611 000 reductions** | `MissingToMaxDepth` and `DepthTo3DLocations` walking those lists                                                                        |

So roughly half of the world phase is our own materialisation and walking, not the
scene. Monty spends none of it: its world hands back numpy arrays that are views
of MuJoCo's buffers, and `DepthTo3DLocations` is numpy arithmetic over them — no
number is ever unpacked into a Python float, let alone a boxed one. That is the
shape of the remaining win here: keep the arrays as the bytes they arrived as until
a kernel consumes them, and make the transform chain one pass over those bytes.
The lists survive only where a reader needs a shape (the page's frames), and are
built there.

Two steps taken, and what each was worth:

- `get_surface_from_depth/3` read the clipped depth image three times — built it as
  an image, walked it row by row to ask "is nothing nearer than a metre", then
  flattened it for the histogram — to answer two questions about it. It reads flat
  once now: **~644 500 → ~611 400 reductions** a step.
- **The pixel walk.** `transform_observation/5` built four lists a pixel: the
  sensor frame's point, the world's (a second `Enum.map` over the first), the
  mask's image and the tagged row that joins them. One walk now answers, for each
  pixel, where it is and whether it is on the surface: **~611 400 → ~472 900
  reductions** a step, and three of those four lists are gone. The mask itself is
  no longer materialised for this path at all; the public
  `get_surface_from_depth/3` still answers the image, from the same decision.

- **The frame, destructured once.** The walk then applied the camera's 3×3 to a
  point and added the offset per pixel — `Geometry.apply/2` and `Geometry.add/2`,
  two more lists a pixel. The frame's three rows and its offset are read once for
  the image now, and a pixel's row is built at its final width: **~472 900 →
  ~290 000 reductions** a step, so **~644 500 → ~290 000 (−55 %)** for the chain.

What is left is one small list a pixel — the tagged row itself — and that goes when
the walk moves behind the NIF boundary and answers `semantic_3d` as the bytes the
sensor module wants anyway.

## The rotations a burst samples from, kept once

A matching step of the ten-object distant agent, by process, before and after
this change (`probe_process_split.exs`, model reductions):

| step | learning module, before |     after | view finder |   patch |
| ---- | ----------------------: | --------: | ----------: | ------: |
| 2    |               2 032 340 | 1 476 179 |     750 656 | 217 236 |
| 3    |               2 318 196 | 1 705 736 |     746 574 | 209 529 |
| 4    |               3 041 859 | 2 225 588 |     672 073 | 214 494 |

`GraphMemory.get_rotation_features_at_nodes/4` is what burst sampling asks for
the frames of the nodes it draws from, and it answered by walking the graph's
whole `x` — one `Enum.slice` per node — then building a tuple of every node's
rows to read a few hundred of them. Ten graphs of a ten-object library, every
step: `get_rotation_features_at_all_nodes/3` **21 883 µs**, the subset it
actually reads **9 455 µs**, per step (`probe_graph_reads.exs`, `:timer.tc` on
the live graphs).

The frames do not change while a graph is being matched: a graph is written at
most once an episode, and `forget_rows/2,3` already drops everything derived from
it at that moment. So the rotations are now built where the feature rows are —
`build_rows_if_missing/3` — and read by node id out of a tuple: the same two
questions answer in **82 µs** and **105 µs**, and the read is 90–270× cheaper.
A graph that grows still answers with the new node's frame, which is what
`graph_memory_test.exs` pins.

## A view's on-object pixels, taken in one walk

The view finder of the distant agent costs 0.67–1.15 M reductions a step, and
`fprof` on the sensor module alone put **38 %** of it in `Enum.drop_list/2`:
6 540 calls, each walking to its row and then to its column — that is
`OnObjectObservation.from/2` reading `location_map[row][column]` and
`salience_map[row][column]` once per on-object pixel, which is how the same
reshape reads in numpy (`location_map[on_object_map]`, a gather) but not what a
list of lists charges for. A thousand on-object pixels in a 64×64 view asked the
grid for their place twice each, walking the image to answer.

The masks, the locations and the salience are now zipped row by row and taken in
the same walk that decides which pixels are on the object, so nothing is looked
up by index: the view finder answers a step in **429 912** reductions where it
answered 750 656 (step 2), and 441 752 where it answered 746 574 (step 3).
The reshape itself is unchanged, which the recorded-view parity test
(`monty_on_object_observation.json`) and the ordering tests pin.

## The alignment a burst is made of, written out

`SpatialArithmetics.align_orthonormal_vectors_as_matrix/2` is `transpose(m1) · m2`,
and burst sampling asks for it once per node per sensed direction: **6 416
alignments a matching step** in the ten-object distant agent. Through
`Geometry.mul/2` each one built a transpose, nine row/column zips and nine sums —
three dozen small lists to add nine numbers — and `fprof` put 156 744 `Enum.map`
applications a step in that path.

The nine entries are now written as arithmetic, summed in the order `Geometry.dot/2`
summed them, so every product is the same float: the ladder stays digit-exact
(`ev 6.338 (1429, 2)`, `goals 15065`) and the exactness test on a stored frame that
is only nearly orthonormal still holds. Learning module per step, before and after
model reductions:

| step |    before |     after |
| ---- | --------: | --------: |
| 2    | 1 504 035 |   979 678 |
| 3    | 1 701 700 | 1 238 544 |
| 4    | 2 227 304 | 1 749 794 |

The eight-step ladder went from 1 695 300 µs to 1 031 952 µs, and the surf agent's
first step of an episode from 1.03 M to 0.62 M reductions (plain steps unchanged at
223–237 k, so nothing degrades as episodes accumulate).

## The node block a burst repeats, copied rather than encoded

`Hypotheses.new/1` was asked for one hypothesis per (pose, node) with the nodes
repeated pose by pose — `List.duplicate(locations, per_node) |> Enum.concat()`
and the same for evidence — so a graph's few hundred chosen nodes were encoded
once for every sensed direction: eight rounds at ten graphs, tens of thousands of
rows of the same values every step. `Hypotheses.per_pose/1` encodes the node
block once and copies it (`:binary.copy/2`), and takes the pose count from the
matrices themselves.

Learning module per step, model reductions: **979 678 → 935 989** (step 2),
**1 238 544 → 1 187 725** (step 3), **1 749 794 → 1 697 697** (step 4). The
ladder is still digit-exact (`ev 6.338 (1429, 2)`, `goals 15065`), and the
burst's own tests — whole pose sets, one per pose on every node — pass unchanged.
