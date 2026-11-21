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
A divided run is held to it: `test/monty/studio/jobs/run_test.exs` walks the same
episodes whole and in parts and demands the same steps, and a world that draws is
held to the same check.

## 3. What is not free

Said plainly, because these are the numbers that decide the design:

- **Memory per concurrent episode, not cores.** An episode holds hypotheses over
  every object it is matching, so the right `max_concurrency` is
  `min(schedulers, memory_budget / episode_peak)`. Measure the peak rather than
  assuming it: `MIX_ENV=test mix run scripts/probe_episode_peak.exs [experiment]
[steps]` walks one episode and prints the app's own footprint, what the
  episode's start reads and the peak while it steps. Read it on the world a run
  will use. This is the one place where the BEAM's sharing helps less than it
  looks: the library is shared, the hypothesis space is not.
- **The database is now in the hot path.** An episode per row is fine; a frame
  per row is not. Frames go to files with a retention window; the row keeps the
  path, the counts and the conclusion.
- **One scheduler per core, and NIFs must yield.** Anything that blocks in C (a
  camera driver, a simulator) belongs behind a port, not in a NIF called from a
  step.
- **Fairness.** `Task.async_stream` with `ordered: false` gives completion order;
  a long episode must not starve a queue of short ones — which is what the
  existing queue (Oban) is for, rather than a bare task per episode.
- **The largest term in a step was a sort, not a phase to divide.** On the
  ten-distinct-objects evidence experiment
  (`randrot_noise_10distinctobj_5lms_dist_agent`, seed 42, 26 steps, world
  `ex_mujoco`, on the Mac this was measured on) the model took 121 s and the
  world 3.5 s. The log's own split put nine tenths of that in the vote round and
  nearly all of the round in `receive` — the modules applying the votes they
  heard. A round carries about 160 votes for one object and a module holds
  thirteen thousand hypotheses, and each hypothesis sorted the whole vote list to
  find its three nearest: O(H·V log V) in Elixir for what Monty asks a KD-tree,
  O(H log V). `EvidenceGraphLM` now builds that index — `KdTree`, native when
  this machine has it — and asks it for the three nearest of each hypothesis. The
  same episode then takes **18 s** in the model, with the same steps, the same
  votes and the same beliefs, and a step is ~700 ms of which the world is ~80 ms.
  So before deciding what to fan out, read the split: the biggest term here was a
  loop that had no business being in a step at all.

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

Parallel episodes are built: `Partition` and `Jobs.Run.run_wave` divide a run's
episodes across parts, the run form carries a `parallelism` select, and a divided
run's library names the objects its parts trained (`training.md`). The page can
put two parts of one divided run beside each other (`/compare`). What the
milestones below add is the part that makes it trustworthy and watchable:

| Milestone            | Needs                          | Done when                                                                                                                                     |
| -------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Parallel episodes    | a world; episode peak measured | a divided run takes the same steps as the serial one (`test/monty/studio/jobs/run_test.exs`), and `max_concurrency` follows the measured peak |
| Live episode         | a sensor source behind a port  | the studio shows a live episode's hypotheses; a frame-per-tick recording replays to the same conclusions                                      |
| Distributed episodes | the two above                  | one experiment across two nodes, with the aggregate identical                                                                                 |

A world that **draws** has one more requirement, and it is not the division's: a
render must not depend on what else rendered first. Two parts on one node are two
renderers, and `ex_mujoco` bound the offscreen buffer once per renderer, so the
first of them to draw after the second was made drew into the second's buffer and
read its own back — black below row 42 of 64, on that one render. A divided run of
`base_config_10distinctobj_dist_agent` therefore took different steps from the
serial one (104 whole, 171 then 140 in two parts) while the stand-in scene agreed
exactly. Fixed in `ex_mujoco` 0.2.6 by binding the buffer per render, and held by
`renderer_test.exs`: "a second renderer of the same scene does not change the
first one's picture".

The check for both is the same one this port has used everywhere else: **the same
numbers as serial, then the same numbers as Python.** Parallelism that changes a
result is a bug, and a live run that cannot be replayed from its recording is not
an experiment.
