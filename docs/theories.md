# Independent processes on theories

The core claim of the thousand brains is that recognition is many independent
models voting, not one loop asking each model in turn. This note is the plan for
making the port behave that way, and for showing the difference it makes.

It is a plan, not a result: the numbers below are the ones to take, and the gate
they have to pass is already written down ([speed.md](speed.md) "The gate").

## What a step is now

`Monty.Runtime.Step` is Monty's loop, and a loop is a sequence of barriers
(`Monty.Runtime.Barrier`): every sensor answers, then every module is handed its
inputs, then votes are sent, then votes are settled. Four rounds a step, each one
"start them all, wait for all of them".

Two of the rounds have already left the synchronous shape, and the reason is
worth keeping in view because it is the same reason the rest can follow:

| Already moved    | What it does now                                                                                                                                                  |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Learning modules | `LearningModuleServer.hand_off/5` gives a module its step as a message; `scheduling: :barrier` awaits the epoch, `:lagged` reads the epoch before and never waits |
| Sensors          | `State.sensors_step/1` decides whether one round may run all sensors at once — `:serial` when a sensor draws from the episode's random stream                     |

What is still strictly turn-based, per step, in `packages/ex_tbp_monty_core`:

- `propose_goals/1`, `sensor_goals/1`, `sensor_regions/1` — `Enum.map` over the
  modules, **one blocking `GenServer.call` after another**, twice a step
  (`Step.round_and_goals/2`). With five modules that is ten round trips a step
  that no one is overlapping.
- The vote round (`Step.vote_and_pass_goals/1`) and the settle round
  (`Step.deliver_votes/2`) — barriers with `:infinity`, so a slow module sets the
  pace of the step for every other module.
- The coordinator computes each module's inputs itself (`route_inputs/3`), so a
  module cannot begin on the part of its input that has arrived.

The cost of that shape is what item 4 of [speed.md](speed.md) "Open" calls the
architectural change the user required. It was never measured separately from the
rest of a step, and the first move below is the measurement, not the rewrite.

## What it should be

A module is not a server that answers questions in order. It holds **a theory**
about what is being looked at — a hypothesis, its evidence, the poses it would
expect next — and it publishes what its theory says as the theory changes. The
step's owner stops asking and starts **waiting, with an expectation set**:

- **Every module is told what arrived**, once, and owns what it does next. No
  round trip decides when it starts.
- **The owner waits on an expectation set**, not on a list: which answers this
  step cannot proceed without is known before the step starts (a vote round wants
  every voter's vote; a goal round only wants the goals of modules that updated).
- **A quiescence deadline decides whether the step is alive, never what it
  concluded.** All expected answers present → proceed. An expectation missed →
  abort loudly with a reason. That distinction is gate item 2 and it is the one
  thing a deadline may not be allowed to blur.
- **Cancellation is an exit signal**, not a call timeout: a step that no longer
  needs an answer kills the process holding it, and the kill cannot be confused
  with an empty answer.
- **The result carries a reason**: `%{replies: …, waited_for: …, missing: …,
reason: :complete | :quiesced | :aborted}`. A page and a log can then say why a
  vote round saw three of four modules.

The shape already exists once in this codebase, in `Monty.Runtime.Barrier`'s
spawned path: spawn, monitor, receive a reply or a death, kill on deadline. What
changes is that the _expected_ set and the _reason_ move out of the caller's head
and into the round's result, and that the round stops being the caller's
structure — a module keeps running between rounds.

## The trap that decides the design

Monty threads **one `numpy.RandomState`** through every module in a fixed order
(gate item 1). A step that lets the scheduler decide who draws first is a
different experiment. So "independent processes on theories" is only admissible
where nothing in the process draws from the episode's stream:

- `State.sensors_step/1` is the existing example of asking the question before
  choosing a shape; `Monty.Random.Stream` and `Step.step_sensor_modules/4` are
  what a sensor that draws looks like.
- A learning module's step draws from the _derived_ per-module stream
  (`Context.rng_for/2`, [monty-differences.md](monty-differences.md) §2.1), so
  modules are order-independent already — that is what makes the hand-off legal.
- Anything that would mix the two (a shared draw inside a concurrent round) is a
  defect, not a tuning choice.

## How it is proved

Three gates, then the demonstration. The gates are the ones that already exist:

1. `mix monty.run base_config_10distinctobj_dist_agent --episodes 1 --steps 8
--no-record` — the eight lines and the goals count must not move by one
   digit ([speed.md](speed.md) "The gate").
2. The parity suites stay `==`, not approximate.
3. One RNG stream per episode, threaded in Python's order.

The demonstration is the point of the exercise, and it is a different number from
"ms per step":

> **steps and wall seconds until the winning object's evidence passes the
> recognition threshold and stays above it**, on a fixed pair of runs
> (10 distinct objects, and the five-dog corpus), against the turn-based build.

Turn-based inference pays for every round of every step, whether or not the
conclusion had already settled. A collaboration of theories can conclude when the
theories agree, which is the experiment the thousand brains predicts: **fewer
steps to a robust answer, not only fewer milliseconds.**

## Order of work

1. **Measure the rounds before touching them.** `probe_step_phases.exs` splits a
   step into world, model and the rest; split the model further into the four
   rounds, on a quiet box, one module and five. Without that split "the rounds
   cost" is a guess.
2. **Goals and regions behind one round.** They are the two strictly serial
   phases and the smallest change: `Barrier.run/2` already exists, and the
   question is whether a module may be asked its goals while another is still
   finishing its epoch (it may not, in `:barrier` mode — so this item is
   `:lagged`-shaped or it is nothing).
3. **The vote round as an expectation set with a reason**, keeping `:infinity`
   behaviour identical when every module answers.
4. **Independent theories.** A module keeps stepping and publishing between the
   coordinator's rounds; the coordinator waits on expectations, kills on
   abort, and records why.
5. **The time-to-robust measurement**, on both corpora, with the turn-based build
   as the control.

Each step lands only when the gate passes; the numbers go in this file with the
box and the world they came from.

## Not this

- **Not parallel episodes.** That is [parallel-and-live.md](parallel-and-live.md),
  a different axis: `num_parallel` is a performance knob because an episode shares
  nothing.
- **Not a new scheduler.** The BEAM's is the mechanism; the work is in what the
  step asks for and when it stops waiting.
- **Not a rewrite of the model.** Nx/EXLA on the model (item 3 of
  [speed.md](speed.md)) is orthogonal and stays where it is.
