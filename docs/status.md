# Status

Where the port stands, what to measure next, and what is open. Written
2026-11-03, at the end of a day in which the machine sat at a load average of 60
to 90, so the numbers below are the ones that survive load — reductions and
reclaimed words — plus the run shapes CI has now checked.

The order that matters: **benchmark against Monty first, on a quiet machine,
before changing anything else.** Everything else in this file is a list, not a
queue.

## Green right now

`main` is `523b733` (PR #9, the prerequisites saga). CI on it is **green in
every job**: `lint`, `types`, all four test partitions, `coverage, CRAP and
parity`, and `image, scan, non-root, publish`. Before it, `578ba03` was green in
every job too, in 30m9s on both architectures.

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

## Stand-ins are gone (2026-11-04)

An experiment built from a class this application has not written is **refused**,
not stood in for. `Setup` reports `:modules_not_ported` as an `:error`, so the
page disables the run, `mix monty.run` exits 1 with the finding that says why,
the queue marks the record failed with that sentence, and `Run.start/2` refuses
the setup before a model is built. The same rule covers a phase this port cannot
run: `do_train: true` is `:training_not_implemented`, because a training episode
here would explore and conclude nothing.

- **84 of Monty's 210 experiments** name at least one such class (67 use a
  `DisplacementGraphLM` group, 34 are pretraining experiments, overlapping), and
  every training tutorial is among them — including `tutorial/first_experiment`,
  which is therefore no longer one of `Catalog.templates/0`. The catalogue still
  lists them: it is Monty's, and a row that says "cannot run here" is a fact
  about the port worth seeing.
- Two latent defects surfaced the moment the tests stepped a real learning
  module instead of the stand-in (which kept no hypotheses at all): the detailed
  JSON logger encoded a hypothesis set's raw f64 binary and crashed on
  `Jason.encode!` — **fixed**, it now reads through `Hypotheses.locations/1`;
  and a vote shaped like a sensor module's (`possible_states`,
  `sensed_pose_rel_body`) had no clause in `EvidenceGraphLM.apply_votes/2` —
  **fixed** (2026-11-04). The clause was not what was missing: the model's
  `_combine_votes` was, so the runtime handed each receiver the raw vote of each
  source instead of the object-keyed messages `receive_votes/2` reads, and no
  vote was ever moved out of the sender's sensor frame.
  `Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching.combine_votes/2`
  now does that arithmetic and `Monty.Runtime.Step.State` routes through it.
  Two more holes in the same round were closed with it: **`update_stats_after_vote`**
  was not ported, so a round never settled a module's own conclusion (`:no_match`
  when nothing is possible, and the _recovery_ out of it when votes bring
  possibilities back — the terminal check never clears `:no_match`); and
  **`lm_to_lm_vote_matrix: null`** — what most single-module configs say — was
  read as "every module wired to nothing", so a round ran where Monty skips
  `_vote` altogether. A run of `base_config_10distinctobj_dist_agent` now reports
  `votes 0/0`, which is what Monty does, and the acceptance ladder is unchanged.

## A page of runs is a page of rows (2026-11-04)

`/runs` read every column of twenty-five runs, `timeline` included — 156 MB
across this machine's seventy-seven runs and 53 MB in the worst one — and the
page timed out its database connection after 15 s. `RunHistory.search/1` and
`list/1` now read what `head/1` reads, every field but the pictures, and a
`:recorded`/`:settled` broadcast carries the same row instead of a record with
tens of megabytes of `timeline` that no table row looks at.

The run page's "What this experiment needs before it can run" link was offered
from every failure, including one whose process had merely been killed. It is
now offered only when the explanation says the prerequisites page is where to
look — a missing file, or a model with no exported memory.

Deleting runs was the same defect wearing different clothes. The button said
"Delete all 1–25 of 77 shown", which reads as _this page_, while it deleted
every run the filter matched; and it deleted them one `get` and one `delete` at
a time, reading each row's pictures first — 156 MB re-read to be thrown away —
so the page sat silent until it was over. The label now says `Delete all 77
matching`, the work happens in a task that renders "Deleting 25 of 77 runs…" as
it goes, and the rows go with `delete_all` in chunks.

## A starting point that starts (2026-11-04)

The builder opened on `tutorial/first_experiment`, so a draft saved without
touching anything inherited that tutorial's refusal: it is a training experiment
over `DisplacementGraphLM`, and neither is written here. It now opens on the
first of `Catalog.templates/0`, `base_config_10distinctobj_dist_agent` — the
experiment the acceptance ladder runs — and taking the name from the catalogue is
what stops the default and the list of experiments that run from drifting apart.

The acceptance config could not be offered as it stood. It writes
`n_eval_epochs: ${constants.rotations_all_count}`, and `Blueprint` was checking
that text, so the number a run reads — 14, from `conf/constants/defaults.yaml` —
was validated as a string and refused. `Blueprint.findings/2` now resolves that
one reference before it checks the count, and the config keeps Monty's own text:
a draft must still compose to the experiment it came from, and composition leaves
interpolation to `Monty.Config.Resolvers` at setup time.

## The skip that a shifted line could drop (2026-11-04)

`.sobelow-skips` records a reviewed finding as `file:line:fingerprint`, so a line
inserted above a flagged one drops the entry and the scan fails on a change that
touched nothing about it. Inserting one line above
`Monty.Studio.Logging.described_module/1` did exactly that: the finding came back
with the line number moved past the entry.

The comment form was recorded as unreliable across versions, and half of that is
right. `# sobelow_skip ["DOS.ModuleConcat"]` _inside the function body_ is
ignored by 0.18.1 — 0.16 honoured that placement — while directly above the `def`
it suppresses the finding. All four sites now carry it there; each already said,
three lines below, why the atoms are bounded by `lib/monty/module_map/data.ex`
rather than by anything a request says. `.sobelow-skips` is empty, and the scan
was re-run with a line inserted above one of the markers: nothing came back.
What the two placements do is written in `.sobelow-conf`, so the experiment does
not have to be repeated.

## A page of runs no longer reads a transcript (2026-11-05)

The page of runs became a page of rows on 2026-11-04, but two of its columns were
still counted from each run's log — how many steps it took, and how many of the
experiment's episodes those steps walked — so `RunHistory.search/1` read every
transcript on the page to work out two integers. A run of 4 789 steps carries 53
MB of log; twenty-five of them is the cost the page had just been made not to pay
for the pictures, one layer down.

Both are columns now, `steps_done` and `episodes_done`, written by
`RunHistory.checkpoint/1` from the same log, in the same update: a row cannot say
three steps about a transcript that holds two. A run recorded before the columns
existed is counted once in the migration — `jsonb_array_length` on Postgres,
`json_array_length` on SQLite, distinct episodes both ways, which is the
definition `episodes_run/1` has always used. `steps_run/1` and `episodes_run/1`
read them, `search/1` drops to a row, and MCP's delete dry run takes its count
from the row rather than from a log it was reading only to count.

What a _single_ run still reads is the log, and that is the right cost: `head/1`
carries it because the run's own page draws its steps, and `running_for/2`
carries it because the page that joins a run in flight reports how far the last
_episode_ got, which no column says.

## The export the ranking read (2026-11-04)

`mix complexity` ranks `cover/default.coverdata`, and `default` is the name a
bare `mix test --cover` on one file exports to: a subset run leaves an export
behind that says every module it never loaded is uncovered, and the ranking then
reports about a hundred and ninety functions above CRAP 20 that are not
(`docs/status.md` #5). `scripts/quality.sh` removes that export before the suite
writes the one it is about to rank — the only file the script deletes — and
`--no-tests`, which re-uses an export instead of writing one, now says which file
it read and when it was written, so a partial export reads as a partial export
rather than as a regression.

## Open points and bugs

| #   | What                                                                                                                                                                                                                                                                                                                                                                                                                                          | Done means                                                                                                                   |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Benchmark against Monty on a quiet machine** — nothing else on this list should come first                                                                                                                                                                                                                                                                                                                                                  | The table from step 1 and step 2 above, side by side, with the ratio stated                                                  |
| 2   | **`lazy_html` is one patch behind**: 0.1.14 needs `fine ~> 0.2.0`, and `pythonx 0.4.11` pins `fine ~> 0.1.2`. Verified in a scratch project that it resolves without pythonx, so this is pythonx's constraint                                                                                                                                                                                                                                 | `pythonx` allows `fine 0.2`, then `mix deps.update lazy_html`. Nothing to do before that                                     |
| 3   | ~~**`.sobelow-skips` is line-anchored.**~~ — **done 2026-11-04.** The four reviewed `DOS.ModuleConcat` findings are marked above their own definitions, which a shifted line cannot drop, and the fingerprint file is empty                                                                                                                                                                                                                   | The marker survives a line inserted above it; `.sobelow-conf` says which placement works                                     |
| 4   | ~~**`# sobelow_skip` comments did not hold across sobelow versions.**~~ — **done 2026-11-04.** Placement, not the version: inside a function body 0.18.1 ignores the comment, above the `def` it honours it                                                                                                                                                                                                                                   | A short note in `.sobelow-conf`, and four markers verified against 0.18.1                                                    |
| 5   | ~~**`mix complexity` locally can report ~196 functions above CRAP 20** after a subset `--export-coverage` run — a poisoned `cover/default.coverdata`, not a regression.~~ — **done 2026-11-04.** The gate deletes the export before the suite writes the one it ranks, and `--no-tests` names the file it re-used                                                                                                                             | `scripts/quality.sh` ranks an export it wrote; a reused one is stated with its timestamp                                     |
| 6   | ~~**Heavy tests time out on a loaded machine**~~ — **done 2026-11-04.** The three files that export and replay real memory carry `@moduletag :heavy`; the limit stays 300 s, and a loaded laptop says `mix test --exclude heavy` instead of reporting a timeout that says nothing                                                                                                                                                             | `mix test --exclude heavy` is green on a loaded box; CI runs everything                                                      |
| 7   | **`scripts/image.sh run` and `smoke` do not fetch prerequisites.** Deliberate — a smoke test must not download ~700 MB — so `run` needs `--data DIR` or a manual `/app/bin/prerequisites`                                                                                                                                                                                                                                                     | A `--fetch` flag on `run`, or leave it and keep the sentence in `docs/container.md`                                          |
| 8   | ~~**The Linux bundle is a `.deb` only.**~~ — **done 2026-11-05.** `tauri.bundle.linux.json` names `deb` and `appimage`; the flag that overrode that list is gone, `linuxdeploy` gets `LD_LIBRARY_PATH` over the release's own libraries (its wheels link each other by soname) and `APPIMAGE_EXTRACT_AND_RUN`, and a shape the config asked for but the bundler did not make now fails the build instead of printing a line under a green job | An AppImage beside the `.deb` in the same download: 231 MiB on the x64 runner, beside a 535 MiB `.deb` and a 525 MiB tarball |
| 9   | **MCP config from the address bar**: done in `ex.tbp.monty` (`/mcp/config` uses `socket.host_uri`, test pins a mapped port) and in `ex_gocd` (`ExGoCDWeb.Mcp.BaseUrl.url/1`). **`confluence_phx_mirror` is the one exception** — the token `curl` on `/profile` uses `Sites.host()` from configuration                                                                                                                                        | A request-derived base URL there, the way `ex_gocd` does it, plus a test                                                     |
| 10  | **`ex_gocd` lint**: the 2026-11-02 hand-over recorded `mix credo --strict` failing on the MCP code (`lib/ex_gocd/mcp/tools/*.ex`, `lib/ex_gocd_web/controllers/mcp/oauth_controller.ex`). Not checked today                                                                                                                                                                                                                                   | Run its gate and confirm; fix or record                                                                                      |
| 11  | ~~**The builder's default base cannot run**~~ — **done 2026-11-04.** `Blueprint` starts from `tutorial/first_experiment`, so a new draft inherited the refusal, and the obvious replacement was refused too because `n_eval_epochs: ${constants.rotations_all_count}` was checked as text. It now starts from the first template and resolves that reference before checking the count                                                        | `Blueprint.new/1` with a name alone composes into a setup `Setup.valid?/1` accepts                                           |
| 12  | ~~**`EvidenceGraphLM.apply_votes/2` has no clause for a sensor module's vote**~~ — **done 2026-11-04.** The payload `receive_votes/2` was handed was never the shape it reads, because `_combine_votes` had not been ported: votes now reach a module keyed by object and moved into its own sensor's frame                                                                                                                                   | `MontyForEvidenceGraphMatching.combine_votes/2` plus two tests that specify the move; `apply_votes/2` is unchanged           |
| 13  | ~~**`RunHistory.search/1` still carries each run's log.**~~ — **done 2026-11-05.** The two numbers a row draws were counted from the transcript; they are columns written with it now, so a page of runs reads rows and nothing else, and the MCP dry run takes its count from the row                                                                                                                                                        | `steps_done` and `episodes_done` are written by `checkpoint/1`; the /runs badge still says `ep 2/140` out of them            |

## Where the work stands, in one paragraph

The port runs Monty's configs, reaches the object Monty names, and holds an
acceptance ladder that has not moved through a dozen optimisations; the studio,
the MCP server and the container image are real and CI-checked. What is open is
speed — a factor of about twelve on the step — and the next move there is a
design decision rather than a kernel. Everything else in the table above is
small, and none of it should be started before the benchmark.
