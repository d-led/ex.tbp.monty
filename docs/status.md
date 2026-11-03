# Status

Where the port stands, what to measure next, and what is open. Written
2026-11-03, at the end of a day in which the machine sat at a load average of 60
to 90, so the numbers below are the ones that survive load — reductions and
reclaimed words — plus the run shapes CI has now checked.

The order that matters: **benchmark against Monty first, on a quiet machine,
before changing anything else.** Everything else in this file is a list, not a
queue.

## Green right now

`main` is `578ba03`. CI on it is **green in every job**: `lint`, `types`, all four
test partitions, `coverage, CRAP and parity`, and `image, scan, non-root,
publish` (30m9s, both architectures).

The one annotation on that run is not ours: `xref: [exclude: …]` is deprecated in
Elixir 1.20 in favour of `elixirc_options: [no_warn_undefined: …]`, and the two
`mix.exs` files it names are `deps/phoenix_ecto` and `deps/postgrex`. It goes
away when those two release; nothing here to change.

What is _not_ usable as a local signal: the whole suite on a loaded machine. A
full run today ended with ten failures, **every one of them
`ExUnit.TimeoutError`**, including a plain `WelcomeLiveTest` case — at a load
average of 88 on 8 cores that is the machine, not the code, and CI (an idle
runner) passes the same tests. The heavy ones are
`test/monty/recording_episode_test.exs` (300 s limit), the MuJoCo
`test/monty/simulators/mujoco/host_test.exs` (60 s), and
`WelcomeLiveTest`/`walkthrough` (60 s). Run those alone, or take CI's word.

## The benchmark to run tomorrow

Two things are being compared: the **run** (does it reach the same conclusions
Monty reaches) and the **step** (does it cost what Monty's costs). Do them in
this order, on the same config and seed, and check the machine first:

```bash
uptime                 # want load < 8 on 8 cores
sysctl vm.swapusage    # want the swap figure near its baseline
```

Anything that holds several busy processes — other VS Code windows, a test run,
a build — is enough to make wall clock meaningless. `docs/speed.md` has the long
version of why.

### 1. Our run, end to end

```bash
mix monty.run base_config_10distinctobj_dist_agent
```

14 epochs, 10 objects, ~140 episodes. Record: wall clock, steps, episodes,
ms/step, and the per-episode conclusion of each episode. The reference to beat
is Monty's own dashboard: **5 122 eval steps in 3:18, ~39 ms a step** at this
config (`docs/speed.md`). The last full run of this port reached 140/140
episodes at **0.61 s a step**, so the episode is right and the step is the open
number.

### 2. Monty's run, the same config

```bash
cd ~/src/tbp.monty/contrib/liveview_experiment
scripts/run.sh base_config_10distinctobj_dist_agent      # then http://localhost:8000/
```

It shows eval steps, eval episodes, current epoch, elapsed, last update, and
"Max Evidence: <object> (<number>)". That page — not a document — is the
reference for "does our port run the same experiment": same config, same seed,
same per-episode conclusions.

### 3. A step's cost, not a run's

```bash
MIX_ENV=test mix run scripts/probe_step_cost.exs base_config_10distinctobj_dist_agent 6
```

Run it three times and quote the range, never one figure. Today it read
**9.2 / 9.6 / 10.1 M reductions and 85 MB** of reclaimed words per step, against
**11.25 / 9.58 / 10.21 M and 87 MB** for the tree before the last change (three
interleaved pairs — see `docs/speed.md`). The per-process split comes from the
same run; the learning module's server is the one to watch.

### 4. The ladder, which must not move

```bash
mix monty.run base_config_10distinctobj_dist_agent --episodes 1 --steps 8 --no-record
```

Eight lines, digit for digit: `0.908 (802, 4)`, `2.55 (1604, 5)`,
`4.086 (2406, 2)`, `5.675 (3208, 1)`, `7.032 (4010, 1)`, `8.639 (3509, 1)`,
`10.15 (2899, 1)`, `11.712 (2342, 1)`. Any speed change that moves these is not
a speed change.

### What "good" looks like

Same per-episode conclusions as Monty's dashboard, and **≤ ~50 ms a step** at
ten objects — about 1.3× Monty's 39 ms. Today we are at 0.61 s, so the gap is
roughly 12× on the step, and `docs/speed.md` explains why the remaining cost is
not in the arithmetic: 65 % of a step is generic plumbing (`Enum`, `lists`,
`erlang`) and about 19 % is the algorithm, so one more narrow kernel cannot close
it. The open decision there — extend `native/matcher_nif` with one call that
carries a burst's whole non-RNG path, or add `nx` + `exla` — is written down in
`docs/speed.md` and still undecided.

## Open points and bugs

| #   | What                                                                                                                                                                                                                                                                                                   | Done means                                                                                                                    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Benchmark against Monty on a quiet machine** — nothing else on this list should come first                                                                                                                                                                                                           | The table from step 1 and step 2 above, side by side, with the ratio stated                                                   |
| 2   | **`lazy_html` is one patch behind**: 0.1.14 needs `fine ~> 0.2.0`, and `pythonx 0.4.11` pins `fine ~> 0.1.2`. Verified in a scratch project that it resolves without pythonx, so this is pythonx's constraint                                                                                          | `pythonx` allows `fine 0.2`, then `mix deps.update lazy_html`. Nothing to do before that                                      |
| 3   | **`.sobelow-skips` is line-anchored.** The four reviewed `DOS.ModuleConcat` entries record `file:line:fingerprint`; inserting a line above a flagged one makes lint fail again                                                                                                                         | Either accept the re-record (`.sobelow-conf` says how) or decide the marker comments are the better mechanism — see #4        |
| 4   | **`# sobelow_skip` comments did not hold across sobelow versions.** Placed in the function body, 0.16 honoured them and 0.18.1 did not; only the skip file suppressed the findings in both                                                                                                             | A short note in `.sobelow-conf` so the next person does not repeat the experiment, or a marker form verified on both versions |
| 5   | **`mix complexity` locally can report ~196 functions above CRAP 20** after a subset `--export-coverage` run — a poisoned `cover/default.coverdata`, not a regression. CI merges four partitions and is green                                                                                           | Delete `cover/*.coverdata`, re-run `scripts/quality.sh`; the history is in `docs/speed.md`'s acceptance section               |
| 6   | **Heavy tests time out on a loaded machine** — three files, all `ExUnit.TimeoutError`, all green in CI. The current limits (300 s / 60 s) cannot tell "slow machine" from "hung"                                                                                                                       | Decide whether that is acceptable; if not, the tests need a liveness check (a progress assertion) rather than a bigger number |
| 7   | **`scripts/image.sh run` and `smoke` do not fetch prerequisites.** Deliberate — a smoke test must not download ~700 MB — so `run` needs `--data DIR` or a manual `/app/bin/prerequisites`                                                                                                              | A `--fetch` flag on `run`, or leave it and keep the sentence in `docs/container.md`                                           |
| 8   | **Fly: `release_command` runs only `/app/bin/migrate`.** Prerequisites are not fetched at deploy; a Machine with an empty volume serves a studio whose runs cannot read their model                                                                                                                    | Decide: run `/app/bin/prerequisites` as a second release command, fetch into a mounted volume once, or refuse to start        |
| 9   | **MCP config from the address bar**: done in `ex.tbp.monty` (`/mcp/config` uses `socket.host_uri`, test pins a mapped port) and in `ex_gocd` (`ExGoCDWeb.Mcp.BaseUrl.url/1`). **`confluence_phx_mirror` is the one exception** — the token `curl` on `/profile` uses `Sites.host()` from configuration | A request-derived base URL there, the way `ex_gocd` does it, plus a test                                                      |
| 10  | **`ex_gocd` lint**: the 2026-11-02 hand-over recorded `mix credo --strict` failing on the MCP code (`lib/ex_gocd/mcp/tools/*.ex`, `lib/ex_gocd_web/controllers/mcp/oauth_controller.ex`). Not checked today                                                                                            | Run its gate and confirm; fix or record                                                                                       |

## Where the work stands, in one paragraph

The port runs Monty's configs, reaches the object Monty names, and holds an
acceptance ladder that has not moved through a dozen optimisations; the studio,
the MCP server and the container image are real and CI-checked. What is open is
speed — a factor of about twelve on the step — and the next move there is a
design decision rather than a kernel. Everything else in the table above is
small, and none of it should be started before the benchmark.
