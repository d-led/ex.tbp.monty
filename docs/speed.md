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

10.8 M reductions and 81 MB of garbage a step, split by the process that did it:

| who                                      | reductions/step | share |
| ---------------------------------------- | --------------: | ----: |
| `Monty.Runtime.LearningModuleServer`     |           6.0 M |   56% |
| the two `SensorModuleServer`s            |           1.4 M |   13% |
| the caller's own process (orchestration) |           1.2 M |   11% |
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

## What the native kernels have bought

22 M reductions and 212 MB a step before them; 10.8 M and 81 MB now. Six kernels
in two Rustler crates (`native/kd_tree_nif`, `native/matcher_nif`): feature
evidence, neighbour evidence, principal curvatures, displaced locations, plus the
graph's flattened arrays and the k-d index. Each has an Elixir reference that
stays runnable and a parity test that compares the answers **exactly**, because
the kernel performs the reference's arithmetic in the reference's order.

The hypothesis set's own columns are the same idea without a kernel: `locations`
(`n*3` f64) and `poses` (`n*9` f64) are held as bytes and read through
`Hypotheses.locations/1`, `location/2`, `poses/1`, `pose/2`, so a step no longer
builds three and nine boxed floats per hypothesis to hand to a kernel.

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
- **A full sort of the graph to take a few hundred nodes** (`top_indices/2`) is
  still there. A bounded selection returns the same indices and is worth trying
  when it can be measured on its own.
- **Caching the graph's arrays twice over** — done, and it is where most of the
  earlier win came from; nothing else in the cache family has measured flat.
