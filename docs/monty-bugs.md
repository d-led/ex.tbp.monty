# Suspected defects in Monty, and this port's decisions

Two things make an Elixir run disagree with a Python one: something in Monty
that looks wrong, and a decision here. Both are recorded here, in the same
shape, because anyone comparing two sets of numbers needs them together. The
word *suspected* is doing work: each entry says what the code does, what its own
comments say it means, and what evidence there is — a reader who knows the
project better may well read the intent differently, and the code has not been
reported upstream by us.

**Read §2.1 and §2.5 before diffing any run.** They are the two that change the
numbers; everything else changes where code lives or what an error looks like.

## At a glance

| § | What | Status | What this port does |
|---|------|--------|---------------------|
| [1.1](#11-the-sanity-check-in-_compute_graph_mismatch-cannot-fail) | A sanity check that compares a value with itself | Confirmed | Ports the transform, drops the check |
| [1.2](#12-npall-over-euler-angles-a-single-axis-rotation-is-never-a-pose-change) | `np.all` over the three Euler angles | Confirmed, `np.any` is what the comments describe | Reproduced on purpose, pinned by a test |
| [1.3](#13-npall-on-the-top-two-ids-stricter-than-its-own-comment) | Same, over the top-two ids | Confirmed, and Monty's TODO names the fix | Reproduced on purpose, pinned by a test |
| [1.4](#14-argsort-2-on-a-single-hypothesis) | `argsort(...)[-2]` on one hypothesis | Latent | Answers `{best, nil}` instead |
| [1.5](#15-first_sensor-is-only-bound-inside-the-loop) | A name bound after its first read | Latent | Answers a value, not an unbound name |
| [1.6](#16-jumptogo-saves-one-name-and-restores-another) | A checkpoint saves one attribute and restores a different one | Confirmed, only bites a resumed run | No checkpoint loading here |
| [1.7](#17-a-depth-of-zero-is-read-as-an-object-a-metre-away) | A depth of 0 (nothing there) read as "object within a metre" | Suspected, masked by enclosed scenes | The stand-in world has a wall, so a miss still has a depth |
| [2.1](#21-random-streams-the-one-that-changes-your-numbers) | One mutable RNG vs a stream per module | Decision | Per-module streams |
| [2.2](#22-motor_only_step-travels-in-the-result) | A policy sets a flag on the motor system | Decision | The flag travels in the result |
| [2.3](#23-the-motor-system-answers-with-itself) | The motor system mutates itself | Decision | It answers with its next version |
| [2.4](#24-get_output1-answers-message-lm) | `get_output` answers a bare `Message` | Decision | `{message, module}`, like every step |
| [2.5](#25-a-sampler-answers-the-stream-it-leaves-behind) | A sampler needs the stream it just used | Decision | Samplers answer `{action, rng}` |
| [2.6](#26-get_top_two_pose_hypotheses_for_graph_id2-answers-best-nil) | The top-two lookup raises | Decision | Answers `{best, nil}` |
| [2.7](#27-depth_at_center-lives-in-the-policy-namespace) | A 530-line module for one centre pixel | Decision | The read lives in the policy namespace |
| [2.8](#28-small-vocabulary-differences) | Python's strings, objects, units | Decision | Atoms, tuples, Monty's units |
| [2.9](#29-inheritance-becomes-public-functions-and-a-module-dispatched-hook) | Subclassing | Decision | Public function + module-dispatched hook |

Statuses mean:

- **Confirmed** — the behaviour follows from the code alone.
- **Latent** — the behaviour looks wrong, but something else currently stops it
  being reached.
- **Reproduced** — this port keeps the behaviour on purpose, so numbers stay
  comparable. Pinned by a test.

## How the links work

Monty's code is linked to
[`thousandbrainsproject/tbp.monty` at `9130364`](https://github.com/thousandbrainsproject/tbp.monty/tree/91303642784ce176e2b8196c7bb990fef57688b6)
— the revision `mix monty.config.snapshots` and `mix monty.module_map.verify`
check against. Line numbers are pinned to it; the function names will outlive
them. This port's code is linked relative to this file. Snippets are quoted
verbatim, only dedented from Monty's nesting.

---

# 1. Suspected defects in Monty

## 1.1 The sanity check in `_compute_graph_mismatch` cannot fail

**What's wrong.** The check subtracts an expression from itself, so the
difference is exactly zero and the assertion compares a value with itself.

**The code.**
[`goal_generation.py:671-682`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/goal_generation.py#L671-L682)

```python
# Perform the same transformation to the estimated location (sanity check)
transformed_current_loc = top_mlh["rotation"].inv().apply(
    top_mlh["location"]
) - top_mlh["rotation"].inv().apply(top_mlh["location"])
transformed_current_loc = (
    second_mlh["rotation"].apply(transformed_current_loc)
    + second_mlh["location"]
)
assert np.all(transformed_current_loc == second_mlh["location"]), (
    "Graph transformation to 2nd object reference frame not returning correct "
    "transformed location"
)
```

**What it should be.** The comment calls this a sanity check, so it should check
what the comment claims: that the transform which puts the most likely object's
graph into the second object's learned frame round-trips a point — transform
`top_mlh["location"]` into the second object's frame and back, and assert it
returned.

**Why it matters.** It is the only check that the two graphs are being compared
in one frame. Without it, a broken transform would silently make the "most
disagreeing" point arbitrary, and the goal generator would jump somewhere
unrelated without saying so.

**What this port does.** The transform is ported unchanged, as
`EvidenceGoalGenerator`'s private `into_frame/3` — see
[`evidence_goal_generator.ex`](../lib/monty/frameworks/models/goal_generation/evidence_goal_generator.ex) —
and the assertion is not recomputed, with the reason in a comment there.
Nothing about the numbers changes.

## 1.2 `np.all` over Euler angles: a single-axis rotation is never a pose change

**What's wrong.** `np.all` over three elementwise comparisons is true only when
*all three* Euler angles differ, so a rotation about a single axis never counts
as a pose change.

**The code.**
[`goal_generation.py:960-973`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/goal_generation.py#L960-L973),
in `_check_conditions_for_hypothesis_test`:

```python
if self.prev_top_mlhs is not None and np.all(
    top_mlh["rotation"].as_euler("xyz")
    != self.prev_top_mlhs[0]["rotation"].as_euler("xyz")
):
    logger.debug("Hypothesis jump indicated: change in most-likely rotation of MLH")
    return True
```

**What it should be.** On the reading the comments support: `np.any`, so that any
changed angle is a changed pose. The comment above the block names exactly that
case — "we didn't find the mug handle following a previous jump, and have
therefore eliminated a pose" — and the TODOs above ask for an angle *threshold*
"rather than it needing to be identical", both of which say "a difference
counts". If the intent was instead "only a change of all three angles counts",
the comments are what is wrong.

**Why it matters.** It decides *when* the agent spends a hypothesis-testing
jump. Some pose changes that should prompt one do not, so the number of jumps,
and therefore the path, differs from the documented intent.

**What this port does.** Reproduced exactly — correcting it here would make our
runs diverge from Monty's, which is the one thing a comparison cannot afford.
Pinned by the test "does not treat a turn about one axis as a new pose" in
[`evidence_goal_generator_test.exs`](../test/monty/frameworks/models/goal_generation/evidence_goal_generator_test.exs).

## 1.3 `np.all` on the top-two ids, stricter than its own comment

**What's wrong.** The condition fires only when *both* ids change. A new
runner-up under an unchanged leader is not a change as far as this code is
concerned. The comment above says "if the identities or *order* … of the top two
MLH changes", and the log line inside says "change or shuffle in top-two MLH
IDs" — neither says that both must change.

**The code.**
[`goal_generation.py:942-960`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/goal_generation.py#L942-L960)

```python
# If the identities or *order* (i.e. which one is most likely)
# of the top two MLH changes, perform a new jump test, as this
# is a reasonable heuristic for us having a new interesting
# place to test
# TODO when optimizing, consider using np.any rather than np.all, i.e. as long
# as there is any change in the top two MLH
if self.prev_top_mlhs is not None and np.all(
    [
        self.prev_top_mlhs[0]["graph_id"],
        self.prev_top_mlhs[1]["graph_id"],
    ]
    != [top_id, second_id]
):
    logger.debug(
        "Hypothesis jump indicated: change or shuffle in top-two MLH IDs"
    )
    return True
```

**What it should be.** `np.any`, as the TODO in the same block says — unless the
intent really is "only a change of both counts", in which case the comment and
the log line are what is wrong. Either way the code and its own description
disagree, and only Monty's authors can say which was meant.

**Why it matters.** Same consequence as §1.2: fewer hypothesis-testing jumps than
the comment describes. The two `np.all`s are one reason an Elixir run and a
Python run can take different numbers of steps on the same object — unless both
read the intent as I do here and the comments are the thing that is wrong.

**What this port does.** Reproduced, pinned by "does not jump when only one of
the top two changes".

## 1.4 `argsort(...)[-2]` on a single hypothesis

**What's wrong.** With one hypothesis the evidence array has length one, and
`[-2]` raises `IndexError: index -2 is out of bounds`.

**The code.**
[`learning_module.py:758-763`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/evidence_matching/learning_module.py#L758-L763)

```python
def get_top_two_pose_hypotheses_for_graph_id(self, graph_id):
    """Return top two hypotheses for a given graph_id."""
    mlh_for_graph = self._calculate_most_likely_hypothesis(graph_id)
    second_mlh_id = np.argsort(self._hypotheses[graph_id].evidence)[-2]
    second_mlh = self._get_mlh_dict_from_id(graph_id, second_mlh_id)
    return mlh_for_graph, second_mlh
```

**What it should be.** Answer "there is no second best" rather than raise: guard
the length, or sort once and take the last two when there are two.

**Why it matters — and why it is latent.** Its only caller is
`EvidenceGoalGenerator._compute_graph_mismatch`, whose result is only used when
`focus_on_pose` is set, and that flag is set only after a guard that returns
early while the object still has a single hypothesis —
[`goal_generation.py:900-904`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/goal_generation.py#L900-L904)
and again at
[`925-930`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/goal_generation.py#L925-L930):
`if len(self.parent_lm._hypotheses[top_id].evidence) == 1: return False`. Nothing
changes the hypothesis space between that guard and the call, so the crash is
out of reach today. It becomes reachable the moment those two pieces of code are
separated — for example by computing goals a step later than the gating
decision.

**What this port does.** Answers `{best, nil}` for a single hypothesis instead of
raising, and says so in the doc of
[`EvidenceGraphLM.get_top_two_pose_hypotheses_for_graph_id/2`](../lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex).
An exception becomes a value the caller must handle, which is a difference in
its own right — see [§2.6](#26-get_top_two_pose_hypotheses_for_graph_id2-answers-best-nil).

## 1.5 `first_sensor` is only bound inside the loop

**What's wrong.** `first_sensor` is assigned on the loop's first iteration and
read after it. An agent reporting no sensors leaves it unbound, so the failure is
an `UnboundLocalError` several lines later rather than the message the code
intends.

**The code.**
[`motor_policies.py:905-911`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L905-L911)
— the same pattern again at
[`633-639`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L633-L639),
in `JumpToGoal`:

```python
for ii, current_sensor in enumerate(self._pre_jump_state.sensors):
    if ii == 0:
        first_sensor = current_sensor
    assert np.all(
        self._pre_jump_state.sensors[current_sensor].rotation
        == self._pre_jump_state.sensors[first_sensor].rotation
    ), "Sensors are not identical in pose"
```

**What it should be.** Collect the rotations first and compare the collection, so
the empty case is a decision the code makes rather than a name it forgot.

**Why it matters.** Diagnostic only: an agent with no sensors is itself nonsense,
so no numeric run is affected. It costs whoever is debugging an odd environment
more time than spelling out the empty case would have.

**What this port does.**
[`InformedPolicy.shared_sensor_rotation/1`](../lib/monty/frameworks/models/motor_policies/informed_policy.ex)
asks for the shared rotation with the empty case spelled out — the identity when
there are none — so the failure mode is a value rather than an unbound name.

## 1.6 `JumpToGoal` saves one name and restores another

**What's wrong.** The jump state is saved from `_undo_actions` and restored into
`_undo_jump_actions`, which nothing in `JumpToGoal` reads or writes. `is_jumping`
is saved and never restored. So a policy restored from a checkpoint has no undo
actions and does not know it was mid-jump.

**The code.**
[`motor_policies.py:463-478`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L463-L478),
where the two names meet:

```python
def load_state_dict(self, memento: Memento) -> None:
    self._agent_id = memento["agent_id"]
    self._undo_action = memento["undo_action"]
    self._is_undoing_jump = memento["is_undoing_jump"]
    self._pre_jump_state = memento["pre_jump_state"]
    self._undo_jump_actions = memento["undo_jump_actions"]

def state_dict(self) -> Memento:
    return {
        "agent_id": self._agent_id,
        "undo_action": self._undo_action,
        "is_jumping": self._is_jumping,
        "pre_jump_state": self._pre_jump_state,
        "undo_jump_actions": self._undo_actions,
    }
```

The actions the jump computes are stored in `_undo_actions`
([line 662](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L662))
and read from there when an undo is due; `_undo_jump_actions` appears nowhere else
in the class, and `_is_undoing_jump` is written by `load_state_dict` and read by
nothing.

**What it should be.** One name for one thing, and every saved key restored:
load into `_undo_actions`, restore `_is_jumping`, and drop `_is_undoing_jump` if
the class does not use it. Which of the two names is the right one is Monty's
call; that they differ is not.

**Why it matters.** Only when a run is resumed from a checkpoint — mid-jump, the
undo actions are lost, so a jump that landed badly cannot be undone and the
sensor stays where it landed. Everywhere else this is invisible.

**What this port does.** Nothing: `load_state_dict`/`state_dict` are absent, by
the decision recorded in
[`motor_policy.ex`](../lib/monty/frameworks/models/motor_policies/motor_policy.ex)
— this port's checkpoint is the studio's own record of a run, not a memento
handed back to a policy. If that changes, this defect is the reason to write the
checkpoint test first.

---

## 1.7 A depth of zero is read as an object a metre away

**What's wrong.** A surface agent that cannot see the object is supposed to
search for it. Before it searches, `_touch_object` reads the depth at the centre
pixel and treats *anything* closer than a metre as the object to move onto. A
depth image reports 0 where the camera saw nothing — Monty's own convention
elsewhere: `sensor_processing` drops points whose depth is 0, and `CameraSM`
reports `min_depth` and `mean_depth` over the ones that are not 0. So a view with
nothing in it takes the "move onto it" branch, and the distance comes out
negative, because the object distance and the sensor's height are both positive.
The agent backs away from the emptiness, every step, for as long as the view
stays empty.

**The code.**
[`motor_policies.py:1163-1179`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L1163-L1179):

```python
depth_at_center = PositioningProcedure.depth_at_center(
    agent_id=self.agent_id,
    observations=observations,
    sensor_id=view_sensor_id,
)
if depth_at_center < 1.0:
    distance = (
        depth_at_center
        - self.desired_object_distance
        - state[self.agent_id].sensors[view_sensor_id].position[2]
    )
    ...
    return MoveForward(agent_id=self.agent_id, distance=distance)
```

`PositioningProcedure.depth_at_center`
([`positioning_procedures.py:76-94`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/environments/positioning_procedures.py#L76-L94))
returns the pixel as it is: no check for "no return".

**What it should be.** Decide what a depth of 0 means before comparing it with a
metre — search, or ask the world for a depth it trusts. Which is Monty's call;
that 0 is not a distance is not.

**Why it is suspected rather than observed.** Monty's experiments put a
transform in front of the camera that removes the case:
`MissingToMaxDepth(max_depth: 1)` replaces every depth of 0 with 1, and 1 is not
less than 1, so the search branch runs as intended. The surf agent's own config
says so —
[`tests/conf/snapshots/base_config_10distinctobj_surf_agent.yaml:152-160`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/tests/conf/snapshots/base_config_10distinctobj_surf_agent.yaml#L152-L160).
So the trap is latent: it needs a depth image that still has 0 in it — a raw
sensor, or a transform chain that left `MissingToMaxDepth` out.

**What this port does.** Reproduces the branch as it is, and ports the transform
that moves the trap out of reach: `MissingToMaxDepth`
([`missing_to_max_depth.ex`](../lib/monty/frameworks/environment_utils/transforms/missing_to_max_depth.ex))
is built from the experiment's config and applied to observations before any
module reads them (`Monty.Studio.Run`). Without it, a surface agent against a
world whose miss is depth 0 backs away 13.5 cm per step.

---

# 2. Where this port deliberately differs

Decisions, not suspected defects. Each is a place where two runs can differ
without either being wrong.

## 2.1 Random streams: the one that changes your numbers

**The difference.** Monty threads one mutable `RandomState` (`ctx.rng`) through
every module in step order, so what a module draws depends on how many draws
everything before it made. This port derives a stream per module from the episode
seed, the module id and the step.

**The code.**
[`motor_policies.py:217`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L217)
is where a policy draws (`self.action_sampler.sample(self.agent_id, ctx.rng)`).
Seventeen calls read `ctx.rng` across eight files — `motor_policies.py` ten
times, the sensor modules and `goal_generation.py` once each — so everything
that samples shares one stream. Ours:
[`Context.rng_for/2`](../lib/monty/context.ex).

**Why it is deliberate.** A single mutable stream across modules is exactly the
kind of shared state an immutable, per-process design cannot carry without
threading it through every function and every message. Deriving per module also
lets a single step be replayed on its own, which is what the studio's replay
uses.

**What it costs.** With the same seed, an Elixir run and a Python run draw
*different* random actions. Every policy that samples — `BasePolicy`,
`InformedPolicy`, `SurfacePolicy` — walks a different path, so recognition rates
and step counts differ even when the arithmetic is identical.

**What to compare instead.** The deterministic parts: evidence given the same
percept sequence (which the replay test asserts to a millionth, where the export's
rounding puts it), hypothesis counts, and aggregates over many episodes. A
per-step, per-seed comparison needs a Monty-compatible single-stream mode, which
is not built.

## 2.2 `motor_only_step` travels in the result

**The difference.** Monty hands the motor system to the selector
(`fixme_provide_motor_system`) so a policy can set `motor_only_step` on it
directly. Here the policy says it in the `MotorPolicyResult` and the motor system
carries it.

**The code.**
[`motor_policies.py:1120-1125`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L1120-L1125)
— the hack, in Monty's own words. Ours:
[`motor_policy_result.ex`](../lib/monty/frameworks/models/motor_policies/motor_policy_result.ex)
and [`motor_system.ex`](../lib/monty/frameworks/models/motor_system.ex).

**Why it is deliberate.** The same effect on the step, with no shared mutable
object between policy, selector and motor system.

## 2.3 The motor system answers with itself

**The difference.** `MotorSystem.call/6` answers `{actions, motor_system}` rather
than only the actions. Same for the selectors and the policies.

**Why it is deliberate.** The record of what was decided has to live somewhere,
and a struct cannot be changed in place. Monty mutates itself; this returns the
next version of itself.

**Where.** [`motor_system.ex`](../lib/monty/frameworks/models/motor_system.ex),
[`motor_policy_selectors.ex`](../lib/monty/frameworks/models/motor_policy_selectors.ex).

## 2.4 `get_output/1` answers `{message, lm}`

**The difference.** Monty's returns the `Message` alone; ours answers it with the
module, like every other step in this port.

**Why it is deliberate.** One calling convention for every step, so composing
steps does not need to remember which ones answer bare values.

**What to do about it.** A caller that wants the confidence reads
`elem(result, 0).confidence`. See
[`EvidenceGraphLM.get_output/1`](../lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex).

## 2.5 A sampler answers the stream it leaves behind

**The difference.** Monty writes `self.action_sampler.sample(self.agent_id,
ctx.rng)` and mutates `ctx.rng` in place, so one stream advances across the
episode. Here `ActionSampler.sample/3` answers `{action, rng}` and the caller
threads it; a policy starts its stream from the context on the first draw and
`reset/1` forgets it.

**The code.** Monty:
[`action_samplers.py:61-71`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/actions/action_samplers.py#L61-L71).
Ours: [`action_sampler.ex`](../lib/monty/frameworks/actions/action_samplers/action_sampler.ex),
used by [`base_policy.ex`](../lib/monty/frameworks/models/motor_policies/base_policy.ex),
[`informed_policy.ex`](../lib/monty/frameworks/models/motor_policies/informed_policy.ex)
and [`surface_policy.ex`](../lib/monty/frameworks/models/motor_policies/surface_policy.ex).

**Why it is deliberate — and why it is not about speed.** A policy draws more
than once in a step: `SurfacePolicy` samples a tangential direction and a
distance, and the search draws a random angle. A stream keyed to the step alone
would answer all of those draws with the same action, which is wrong rather than
slow. `scripts/bench_samplers.exs` records that threading is also the cheaper
option (1.0 µs against 1.4 µs per draw, in a ~39 ms step), but that is a
tie-breaker, not the reason.

**What it costs.** The same as §2.1: the numbers a draw produces are Monty's for
a given stream, but the stream is not Monty's.

## 2.6 `get_top_two_pose_hypotheses_for_graph_id/2` answers `{best, nil}`

**The difference.** Monty raises where this port returns a value — see
[§1.4](#14-argsort-2-on-a-single-hypothesis).

**Why it is deliberate.** A goal generator running without a hypothesis to test
is a normal state, not an exception, and a crash in the middle of an episode is
worse than a goal that is not proposed.

**Where.** [`evidence_graph_lm.ex`](../lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex).

## 2.7 `depth_at_center` lives in the policy namespace

**The difference.** Monty keeps it in `positioning_procedures.py`, as a
`@staticmethod` of `PositioningProcedure` at
[line 75](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/environments/positioning_procedures.py#L75).
Here it is
[`MotorPolicies.depth_at_center/3`](../lib/monty/frameworks/models/motor_policies.ex),
reading the same shape — `observations[agent_id][sensor_id]["depth"]`, centre
pixel.

**Why it is deliberate.** That module is 530 lines of good-view searching for
distant agents, none of it needed yet, and the centre-pixel read is needed by two
policies now. It moves to its mapped home when an environment is ported.

## 2.8 Small vocabulary differences

- `PolicyStatus` is `:ready | :in_progress` here, `"ready" | "in_progress"`
  upstream; the strings appear only on a wire.
  → [`policy_status.ex`](../lib/monty/frameworks/models/motor_policies/policy_status.ex)
- `rotation_quat` is a `{w, x, y, z}` tuple here and a `quaternion` object there;
  `ActionJSONDecoder` converts on the way in from JSON lists.
  → [`action_json_decoder.ex`](../lib/monty/frameworks/actions/action_json_decoder.ex)
- Monty's `fixme_undo_last_action` raises `TypeError("Invalid action: …")`; ours
  is `undo_last_action/1` and raises `ArgumentError` naming the kind of action it
  was given. The `fixme_` prefix is Monty saying it would rather have
  `Action.undo`, and the name here leaves the complaint out.
  → [`motor_policies.ex`](../lib/monty/frameworks/models/motor_policies.ex)
- Actions keep Monty's units (degrees, metres, `wxyz`), deliberately: an action
  built here must be the same object an environment there would perform.
  → [`lib/monty/frameworks/actions/`](../lib/monty/frameworks/actions)

**Why it is deliberate.** Atoms for closed sets, tuples for quaternions, and
Monty's units throughout: the vocabulary stays Monty's where it would show up in
a number, and becomes Elixir's where it would not.

## 2.9 Inheritance becomes public functions and a module-dispatched hook

**The difference.** Monty's `SurfacePolicy` is an `InformedPolicy`: it inherits
the jump machinery and overrides `__call__`, `reset` and `_handle_successful_jump`.
Elixir structs do not inherit, so the port does two things Monty does not have to:

- the jump step is a public `InformedPolicy.goal_driven_actions/4`, taking any
  policy that carries the jump fields (a `jump_state` shape) and answering the
  policy it leaves behind — what `SurfacePolicy` calls instead of inheriting;
- Monty's `_handle_successful_jump` is `handle_successful_jump/1`, dispatched to
  the policy's own module by `MotorPolicies.successful_jump/1`, because a private
  function cannot be overridden by another module's struct.

**The code.** Monty:
[`motor_policies.py:1077-1100`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L1077-L1100)
(`class SurfacePolicy(InformedPolicy)`). Ours:
[`informed_policy.ex`](../lib/monty/frameworks/models/motor_policies/informed_policy.ex),
[`motor_policies.ex`](../lib/monty/frameworks/models/motor_policies.ex),
[`motor_policy.ex`](../lib/monty/frameworks/models/motor_policies/motor_policy.ex)
(the optional callback) and
[`surface_policy.ex`](../lib/monty/frameworks/models/motor_policies/surface_policy.ex).

**Why it is deliberate.** Nothing observable changes: the same step produces the
same actions and the same policy state. What changes is where the code lives, and
that the shared shape is a type (`InformedPolicy.jump_state/0`) rather than a
class hierarchy.

---

# Checked and found consistent

Recorded so the next reader does not repeat the audit. The first two are claims
Monty's documentation makes; the rest are claims the code makes about itself.

- [`docs/how-monty-works/motor-system.md`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/docs/how-monty-works/motor-system.md):
  a selector chooses among policies, the selector is what goals reach, and
  policies are the only things that produce actions — the shape of
  [`MotorPolicySelectors`](../lib/monty/frameworks/models/motor_policy_selectors.ex)
  and [`MotorSystem`](../lib/monty/frameworks/models/motor_system.ex) here.
- [`docs/how-monty-works/motor-system/policy.md`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/docs/how-monty-works/motor-system/policy.md):
  "if the sensor patch moves off the object, the previous action is reversed" is
  `InformedPolicy`'s step exactly, and `InformedPolicyRandomWalk`'s too — the
  `distant_2` and `distant_5` motor-system configs pass the latter as their
  selector's `default`. The `alpha` momentum that page also mentions is
  `SurfacePolicy`'s tangential-direction weighting, not the random walk's: a
  random walk samples independently on every step.
- `get_output()` returning a `Message` makes `parent_lm.get_output().confidence`
  correct in the evidence goal generator (see §2.4 for our shape).
- `threshold_possible_matches`, `x_percent_threshold` and the
  `x_percent_scale_factor` application agree with their own comments.
- `MotorSystem` keeps each step's actions with the state they were chosen in,
  resets that record per episode, and keeps the selector's own record for
  `state_dict`, as its comments say.
