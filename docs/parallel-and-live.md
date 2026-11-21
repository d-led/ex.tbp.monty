# Parallel episodes, and an experiment that never stops

Two things Monty does that this port has not needed yet, and that the BEAM makes
cheap enough to be a reason to be here rather than an afterthought:

1. **Running episodes in parallel** — Monty's `run_parallel.py`, one process per
   episode.
2. **Running an episode against a live world** — a camera, a robot, anything that
   produces observations on its own clock.

The first is nearly free here, because an episode is already a function of its
inputs. The second needs two new pieces and no change to the model. What follows
is what each one is, what it costs, and what has to be built — so the order the
work arrives in stays a decision rather than a discovery.

## 1. What Monty's parallel mode is

[`run_parallel.py`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/run_parallel.py)
takes an experiment's Hydra config, expands it into one config **per episode**,
and hands those to a `multiprocessing` pool:

```python
ctx = mp.get_context("spawn")
with ctx.Pool(num_parallel, maxtasksperchild=1) as p:
```

Each worker runs one episode, writes its own log directory, and exits
(`maxtasksperchild=1`); the parent then concatenates the per-worker JSON and CSV
into one run and computes the overall statistics. `spawn` rather than `fork` is
deliberate — a forked MuJoCo GL context misbehaves.

The constraint is in the code, twice, as an assertion:

> parallel experiments only work (for now) with per object env interfaces

`OneObjectPerEpisodeInterface`: **one object per episode**. That is the price of
isolation in Python. Each process must own its environment and its learning
modules because both are mutated in place; anything that spans episodes cannot be
parallelised at all.

Two costs follow, both from the same cause. Each spawned worker re-reads and
re-parses the pretrained library, because a mutable object graph cannot be shared
between processes. And the results of an episode are a set of files that is
concatenated afterwards, so a parallel run is something you read when it finishes.

## 2. What this port already has, and what that buys

An episode here is `Monty.Runtime.Episode.run/3`: a model, an environment
**function**, a seed. It mutates nothing it does not own, and the pretrained
library is immutable data handed in (see the decision at the end of
[roadmap.md](roadmap.md)). That is the whole of what a parallel runner needs:

| Monty                                                 | Here                                                                  | Why it is cheaper                                                               |
| ----------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| One process per episode, `spawn`, re-unpickled memory | One `Task` per episode, library shared                                | An immutable graph is a reference; a thousand concurrent episodes cost one copy |
| `num_parallel` workers                                | `Task.async_stream(episodes, &run/1, max_concurrency: n)`             | No pool bookkeeping, no `maxtasksperchild`, back-pressure built in              |
| A crash kills a worker and the pool replaces it       | A supervised task; the crash is reported, the other episodes continue | Failure isolation is the runtime's job, not the runner's                        |
| Log dir per worker, concatenated at the end           | Rows written as episodes finish; the aggregate is a query             | The studio already stores run history                                           |
| Progress is a print, or nothing                       | `Phoenix.PubSub` per step, frames included                            | Watching a run is the same code as watching a live one                          |
| Single machine                                        | `:erpc`/`Node.spawn` when the day comes                               | Episodes share no state, so distribution needs no redesign                      |
| One object per episode, asserted                      | Same, but as a _consequence_                                          | Per-module derived streams mean an episode cannot see another's draws           |

The last row is the one worth arguing. Monty's restriction exists because mutable
state leaks between episodes. Here determinism is per episode by construction —
`Context.rng_for/2` derives every module's stream from the episode seed, the
module and the step ([`monty-differences.md`](monty-differences.md) §2.1) — so two episodes
cannot
influence each other even if they run in the same process. **`num_parallel` is
therefore a performance knob and can never be a correctness one**, which is a
statement Monty cannot make about its own pool without auditing every global.

## 3. What is not free

Said plainly, because these are the numbers that decide the design:

- **Memory per concurrent episode, not cores.** An episode holds hypotheses over
  every object it is matching, so the right `max_concurrency` is
  `min(schedulers, memory_budget / episode_peak)`. The peak is measured rather than
  assumed: `MIX_ENV=test mix run scripts/probe_episode_peak.exs [experiment]
  [steps]` walks one episode and prints the app's own footprint, what the
  episode's start reads and the peak while it steps. On this Mac, on the synthetic
  stand-in, one episode of `base_config_10distinctobj_dist_agent` — 39 steps to
  its conclusion — read **84 MB** with the app up, **151 MB** with the run
  started, and **207 MB** at its peak: a second episode costs about **56 MB** of
  its own, while most of the 67 MB a start reads is the library every episode
  shares. Read it on the world a run will use before choosing the number. This is
  the one place where the BEAM's sharing helps less than it looks: the library is
  shared, the hypothesis space is not.
- **The database is now in the hot path.** An episode per row is fine; a frame
  per row is not. Frames go to files with a retention window; the row keeps the
  path, the counts and the conclusion.
- **One scheduler per core, and NIFs must yield.** Anything that blocks in C (a
  camera driver, a simulator) belongs behind a port, not in a NIF called from a
  step.
- **Fairness.** `Task.async_stream` with `ordered: false` gives completion order;
  a long episode must not starve a queue of short ones — which is what the
  existing queue (Oban) is for, rather than a bare task per episode.

## 4. A live experiment

The model does not need to know. An episode already takes an environment as a
function from the previous step's actions to `{observations, proprioceptive_state}`
— `Monty.Runtime.Episode`'s moduledoc says so — and a camera satisfies exactly
that shape. Two pieces are missing:

1. **A clock.** Today the loop advances when `run/3` asks it to. A live episode
   advances at a rate: a `GenServer` that ticks (10 Hz, say), asks the source for
   the current observations, steps the model, and sends the actions on. Pacing
   belongs in the driver, not in the model, for the same reason `max_steps` does.
2. **A sensor source behind a port.** One process per source, owning the device,
   publishing the latest frame and its pose. This is the piece that keeps a
   camera driver from blocking a scheduler, and it is also where a robot's command
   sink goes.

What that gives, without a line of model code:

- a **live demo**: an agent looking at an object on a desk, its hypotheses and
  evidence drawn in the studio as they change — the same frames the studio already
  draws from a recorded run;
- **continuous experiments**: an episode that does not end, with bounded history
  (short-term memory plus a retention window), so a long observation is a
  measurement rather than a leak;
- **teleoperation**, which is what `tbp.teleop` is for: human commands and model
  commands are both actions, and both reach the world through the same sink.

Monty's own precedents are the side projects in the org, and they are the shapes
to copy rather than invent: [`tbp.teleop`](https://github.com/thousandbrainsproject/tbp.teleop)
(visualise and teleoperate a run in real time),
[`everything_is_awesome`](https://github.com/thousandbrainsproject/everything_is_awesome)
(a LEGO robot hackathon fork), [`tbp.ultrasound_perception`](https://github.com/thousandbrainsproject/tbp.ultrasound_perception)
(real sensor data), and [`prototype.simulator`](https://github.com/thousandbrainsproject/prototype.simulator)
(a world behind a socket — the same seam a camera would use).

## 5. Where this sits in the plan

**Parallel episodes are built** — `Partition` and `Jobs.Run.run_wave` divide a
run's episodes across parts, the run form carries a `parallelism` select, and a
divided run's library has been read back and scored against its objects
(`training.md`, "A divided run writes the same memory"). The four things that made
it something to trust are in:

- **The referee** — "a run of several parts finds what the undivided run finds,
  episode for episode" (`test/monty/studio/jobs/run_test.exs`) walks four
  episodes twice, once whole and once in two parts, and asserts every step of
  every episode is the same step: the same percepts, votes, goals and beliefs, and
  the same tally at the close. A division is a change of schedule, so nothing else
  may move.
- **The memory number** — `scripts/probe_episode_peak.exs` prints an episode's
  peak and §3 quotes the reading, so a concurrency is arithmetic rather than a
  number chosen by feel.
- **The comparison, on the page** — `/compare` offers a divided run's parts under
  the run in each of its two pickers. Picking two parts (or a part and the whole
  run) reads both columns from the runs' `eval_stats.csv`, because a part has no
  summary of its own, and the page says so above the table. That is a reader's own
  proof that the division did not change the answer.
- **A headless lever** — `mix monty.run <experiment> --episodes 8 --parallel 4`
  for the runs a script starts; the page stays the way a person starts one.

What is left in this lane:

- **`/compare` starting the second run** — a reader still starts the second run
  from the experiment page and then picks it here, rather than pressing one
  button on the first run's page.
- A part's **wall clock** is shown only for a run of one wave: a run that trains
  and then evaluates numbers both waves from one, and the part rows carry no wave.

**Live episodes are not started**: they need a sensor source behind a port, and
the model needs no change. **Distributed episodes** follow both.

The check is the same one this port has used everywhere else: **the same numbers
as serial, then the same numbers as Python.** Parallelism that changes a result
is a bug, and a live run that cannot be replayed from its recording is not an
experiment.
