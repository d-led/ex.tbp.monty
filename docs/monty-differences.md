# Differences, and what this port suspects in Monty

Two things make an Elixir run disagree with a Python one: a decision this port
made, and something in Monty that looks wrong. Both are here, because anyone
comparing two sets of numbers needs them together.

Where an entry suspects Monty, _suspected_ is doing work: it says what the code
does, what its own comments say it means, and what evidence there is. Someone who
knows the project better may read the intent differently, and nothing here has
been reported upstream.

## Read this first

**Two entries change a run's numbers. Read those two before you diff a run.**

1. [**§2.1 Random streams**](#21-random-streams-one-stream-per-episode-numpys-numbers)
   — the one that bites.
2. [**§2.5 A sampler answers the stream it leaves behind**](#25-a-sampler-answers-the-stream-it-leaves-behind)
   — the same stream, one layer down.

Everything else changes where code lives, what an error looks like, or what
happens on a path Monty itself never takes.

**Looking for something specific?**

| If you are asking…                           | Read                             |
| -------------------------------------------- | -------------------------------- |
| "two runs disagree — is it me or Monty?"     | §2.1 and §2.5                    |
| "is this a bug in Monty, or deliberate?"     | §1                               |
| "why is the Elixir code shaped differently?" | §2                               |
| "has this been compared against Monty yet?"  | [`validation.md`](validation.md) |

**Status words**, used in one column of the table below:

| Word           | Means                                                                      |
| -------------- | -------------------------------------------------------------------------- |
| **Confirmed**  | It follows from Monty's code alone.                                        |
| **Suspected**  | It looks wrong; only Monty's authors can say what was meant.               |
| **Latent**     | It looks wrong, but something else stops it being reached today.           |
| **Reproduced** | This port keeps it on purpose, so numbers stay comparable. A test pins it. |
| **Decision**   | Not a defect — the port chose a different shape.                           |

## At a glance

| §                                                                                            | What                                                                        | Status                                                      | What this port does                                                                |
| -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [1.1](#11-the-sanity-check-in-_compute_graph_mismatch-cannot-fail)                           | A sanity check that compares a value with itself                            | Confirmed                                                   | Ports the transform, drops the check                                               |
| [1.2](#12-npall-over-euler-angles-a-single-axis-rotation-is-never-a-pose-change)             | `np.all` over the three Euler angles                                        | Confirmed, `np.any` is what the comments describe           | Reproduced on purpose, pinned by a test                                            |
| [1.3](#13-npall-on-the-top-two-ids-stricter-than-its-own-comment)                            | Same, over the top-two ids                                                  | Confirmed, and Monty's TODO names the fix                   | Reproduced on purpose, pinned by a test                                            |
| [1.4](#14-argsort-2-on-a-single-hypothesis)                                                  | `argsort(...)[-2]` on one hypothesis                                        | Latent                                                      | Answers `{best, nil}` instead                                                      |
| [1.5](#15-first_sensor-is-only-bound-inside-the-loop)                                        | A name bound after its first read                                           | Latent                                                      | Answers a value, not an unbound name                                               |
| [1.6](#16-jumptogo-saves-one-name-and-restores-another)                                      | A checkpoint saves one attribute and restores a different one               | Confirmed, only bites a resumed run                         | No checkpoint loading here                                                         |
| [1.7](#17-a-depth-of-zero-is-read-as-an-object-a-metre-away)                                 | A depth of 0 (nothing there) read as "object within a metre"                | Suspected, masked by the configured transform               | Ports the transform that masks it, and applies it before any module reads          |
| [1.8](#18-the-pixel-grid-is-not-a-cameras-pixel-grid)                                        | Unprojection samples the image's edges, not its pixel centres               | Suspected, sub-millimetre at Monty's scale                  | Reproduced, and the stand-in world renders the same grid                           |
| [1.9](#19-the-mean-is-divided-by-the-count-twice-in-the-plane-fit)                           | A mean divided by the count twice inflates the plane fit's scatter matrix   | Suspected, nil for a centred neighbourhood                  | Reproduced on purpose, recorded at the code site                                   |
| [1.10](#110-the-pose-not-defined-flag-is-written-where-nothing-reads-it)                     | A "pose not defined" flag written to the wrong features dict                | Suspected, needs a percept to be visible                    | Reproduced on purpose, pinned by a test                                            |
| [1.11](#111-the-rgb-blur-comment-names-the-wrong-kernel-size)                                | A comment says OpenCV picks `6*sigma + 1`; measured, it picks `8*sigma + 1` | Confirmed by measurement                                    | Follows the code (OpenCV), not the comment                                         |
| [1.12](#112-lab-goes-through-opencvs-8-bit-tables)                                           | `cvtColor` on a `uint8` image answers 8-bit Lab, so it quantises            | Confirmed by measurement over every 8-bit colour            | Floats; agrees to 2.67 of 255                                                      |
| [1.13](#113-cv2s-area-resize-does-something-else-when-only-one-axis-enlarges)                | `INTER_AREA` with one axis enlarging is neither area nor linear             | Confirmed by measurement; unreachable from Monty's pyramids | Answers the area average                                                           |
| [1.14](#114-a-pixel-with-no-depth-becomes-the-nearest-patch-in-the-view)                     | A depth of zero, mapped to log-depth zero, is _above_ every real depth      | Suspected; masked by the depth transforms real configs use  | Reproduced on purpose, pinned by a test                                            |
| [1.15](#115-montys-two-gaussians-are-not-the-same-gaussian)                                  | OpenCV's Gaussian and SciPy's are one function truncated two ways           | Confirmed by measurement                                    | Each where Monty uses it: OpenCV for salience, SciPy for the positioning procedure |
| [2.1](#21-random-streams-one-stream-per-episode-numpys-numbers)                              | One mutable RNG threaded through every module                               | Decision                                                    | One stream per episode, held in a process                                          |
| [2.2](#22-motor_only_step-travels-in-the-result)                                             | A policy sets a flag on the motor system                                    | Decision                                                    | The flag travels in the result                                                     |
| [2.3](#23-the-motor-system-answers-with-itself)                                              | The motor system mutates itself                                             | Decision                                                    | It answers with its next version                                                   |
| [2.4](#24-get_output1-answers-message-lm)                                                    | `get_output` answers a bare `Message`                                       | Decision                                                    | `{message, module}`, like every step                                               |
| [2.5](#25-a-sampler-answers-the-stream-it-leaves-behind)                                     | A sampler needs the stream it just used                                     | Decision                                                    | Samplers answer `{action, rng}`                                                    |
| [2.6](#26-get_top_two_pose_hypotheses_for_graph_id2-answers-best-nil)                        | The top-two lookup raises                                                   | Decision                                                    | Answers `{best, nil}`                                                              |
| [2.7](#27-depth_at_center-lives-in-the-policy-namespace)                                     | A 530-line module for one centre pixel                                      | Decision                                                    | The read lives in the policy namespace                                             |
| [2.8](#28-small-vocabulary-differences)                                                      | Python's strings, objects, units                                            | Decision                                                    | Atoms, tuples, Monty's units                                                       |
| [2.9](#29-inheritance-becomes-public-functions-and-a-module-dispatched-hook)                 | Subclassing                                                                 | Decision                                                    | Public function + module-dispatched hook                                           |
| [2.10](#210-missing-coverage-counts-as-zero)                                                 | `features["object_coverage"]` raises when it was not asked for              | Decision                                                    | A missing coverage is zero                                                         |
| [2.11](#211-a-sensor-with-no-surface-answers-nil)                                            | A sensor's step always answers a percept                                    | Decision                                                    | No surface to see is `nil`, not a made-up location                                 |
| [2.12](#212-the-sensors-pose-is-composed-once)                                               | Two classes compose a sensor's world pose                                   | Decision                                                    | One function, two callers                                                          |
| [2.13](#213-two-protocols-and-a-mutable-transform-become-one-behaviour-and-a-threaded-value) | Protocols for `isinstance`, and transforms that mutate themselves           | Decision                                                    | The port's one sensor behaviour; a transform answers itself                        |
| [2.14](#214-the-positioning-loop-is-bounded)                                                 | The positioning loop has no bound                                           | Decision                                                    | Stops after 100 steps, and says so                                                 |
| [2.15](#215-two-recording-environments-and-only-one-of-them-is-montys)                       | Two recording environments                                                  | Decision                                                    | A recording names which interpreter made it                                        |
| [2.16](#216-distractors-are-refused-not-placed)                                              | Distractors are placed around the target                                    | Decision                                                    | Refused — the stand-in world holds one object                                      |
| [2.17](#217-a-recognition-policy-is-given-what-it-reads-not-the-model)                       | A policy is handed the live model                                           | Decision                                                    | Handed a view of it: four readings                                                 |
| [2.18](#218-a-memory-arrives-as-an-export-not-as-a-pickle)                                   | A memory is a torch pickle                                                  | Decision                                                    | An export (JSONL), read once and copied per run                                    |
| [2.19](#219-back-where-it-started-is-an-angle-not-the-same-floats)                           | "Back where it started" is exact float equality                             | Decision                                                    | An angle, to a thousandth of a degree                                              |
| [2.20](#220-a-supervised-episodes-answer-is-a-call-and-an-impossible-config-is-refused)      | An episode's answer is written into modules                                 | Decision                                                    | A call per module; impossible configs refused, not crashed                         |
| [2.21](#221-an-object-orientation-channels-evidence-is-ported-but-not-yet-dispatched)        | An orientation channel's evidence                                           | Ported, not dispatched                                      | Computed and answerable; nothing asks it yet                                       |
| [2.22](#222-in-parallel-divides-one-runs-work-into-parts)                                    | `run_parallel.py` runs one config per episode                               | Decision                                                    | Parts of one run and one record                                                    |
| [2.23](#223-how-often-a-surface-agent-reads)                                                 | A surface agent reads on one step in four                                   | Same rule; ours is named where it is read                   | Three gates, and the cheapest run wins by the filter, not the model                |
| [2.24](#224-the-vote-round-finds-its-neighbours-by-scanning)                                 | The vote round's three nearest votes                                        | A scan, not a k-d tree                                      | Same neighbours, same arithmetic, more distance computations                       |

## How the links work

Monty's code is linked to
[the revision these entries were read from](https://github.com/thousandbrainsproject/tbp.monty/tree/91303642784ce176e2b8196c7bb990fef57688b6)
— which is why line numbers are pinned to it; the function names will outlive
them. The map and the shipped config copy have moved on since: the commit the map
was read from is `Monty.ModuleMap.Data.sources/0`, and the copy is named in
[`priv/monty/inputs.json`](../priv/monty/inputs.json), so a line number here is a
line of the linked revision and not of today's checkout. This port's code is
linked relative to this file. Snippets are quoted verbatim, only dedented from
Monty's nesting.

---

# 1. Suspected defects in Monty

## 1.1 The sanity check in `_compute_graph_mismatch` cannot fail

**In one line:** it can never fail, so the one check that the two graphs are being
compared in the same frame does nothing.

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

**In one line:** a rotation about one axis never counts as a pose change, so
fewer hypothesis-testing jumps happen than the comments describe.

**What's wrong.** `np.all` over three elementwise comparisons is true only when
_all three_ Euler angles differ, so a rotation about a single axis never counts
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
therefore eliminated a pose" — and the TODOs above ask for an angle _threshold_
"rather than it needing to be identical", both of which say "a difference
counts". If the intent was instead "only a change of all three angles counts",
the comments are what is wrong.

**Why it matters.** It decides _when_ the agent spends a hypothesis-testing
jump. Some pose changes that should prompt one do not, so the number of jumps,
and therefore the path, differs from the documented intent.

**What this port does.** Reproduced exactly — correcting it here would make our
runs diverge from Monty's, which is the one thing a comparison cannot afford.
Pinned by the test "does not treat a turn about one axis as a new pose" in
[`evidence_goal_generator_test.exs`](../test/monty/frameworks/models/goal_generation/evidence_goal_generator_test.exs).

## 1.3 `np.all` on the top-two ids, stricter than its own comment

**In one line:** the jump condition fires only when _both_ of the top two
changes — a new runner-up under the same leader does not count.

**What's wrong.** The condition fires only when _both_ ids change. A new
runner-up under an unchanged leader is not a change as far as this code is
concerned. The comment above says "if the identities or _order_ … of the top two
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

**In one line:** with one hypothesis, `[-2]` raises — but a guard upstream keeps
the case out of reach today.

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

**In one line:** an agent with no sensors fails with `UnboundLocalError` several
lines later, instead of the message the code intends.

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

**In one line:** a policy resumed mid-jump comes back with no undo actions and no
memory that it was jumping.

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

**In one line:** "no depth" (0) reads as "object closer than 1 m", so an agent
facing nothing backs away from it, every step, forever.

**What's wrong.** A surface agent that cannot see the object is supposed to
search for it. Before it searches, `_touch_object` reads the depth at the centre
pixel and treats _anything_ closer than a metre as the object to move onto. A
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

## 1.8 The pixel grid is not a camera's pixel grid

**In one line:** the unprojection grid spans the image's edges rather than its
pixel centres, so every point is half a pixel out.

**What's wrong.** A depth image is unprojected with a grid that runs from −1 to
+1 over the _pixels_, not over the pixel _centres_:

```python
x, y = np.meshgrid(
    np.linspace(-1, 1, self.w[i]), np.linspace(1, -1, self.h[i])
)
```

The first sample lands on the image's left edge and the last on its right one. A
camera's first pixel centre is half a pixel in from the edge, so the grid is a
half pixel too far left at one edge, a half pixel too far right at the other,
and `w / (w - 1)` too wide — 64/63 for the 64-pixel patches Monty's experiments
use. Everything unprojected inherits both errors: a surface point is displaced
by about `fx · depth / w`, and the patch's middle pixel — the one a sensor module
reports the surface normal and the principal curvatures at — sits `1/64` of the
half-width off the sensor's own axis rather than `1/128`.

**The code.**
[`transforms.py:597-599`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/environment_utils/transforms.py#L597-L599)
and the `center_id` that both `SensorModule` and
`MontyForEvidenceGraphMatching` compute as `half_obs_dim + obs_dim * half_obs_dim`
([`sensor_modules.py:207-210`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/sensor_modules.py#L207-L210)).

**What it should be.** `linspace(-1 + 1/w, 1 - 1/w, w)` — the pixel centres —
which is what the simulator that produced the image rendered.

**Why it is suspected rather than observed.** At Monty's surface scale the
displacement is microscopic: for a patch at ten times zoom on an object 5 cm
away, `fx · depth / w` is 78 µm and the off-axis centre is 1.6 mm out. Nothing
in a Monty run would notice. It is recorded because it is visible the moment the
world and the transform have to agree with each other, which is what this port's
stand-in simulator does.

**What this port does.** Reproduces Monty's grid in the transform
([`depth_to_3dlocations.ex`](../lib/monty/frameworks/environment_utils/transforms/depth_to_3d_locations.ex)),
and renders the stand-in world's image on the same grid
([`scene.ex`](../lib/monty/simulators/synthetic/scene.ex)) so that the two
disagree about nothing. A test unprojects every pixel of a rendered patch and
requires the points to land on the sphere.

## 1.9 The mean is divided by the count twice in the plane fit

**In one line:** `np.mean` already divides by the count, so dividing again leaves
the mean's outer product in the scatter matrix.

**What's wrong.** `surface_normal_total_least_squares` builds the scatter matrix
a total-least-squares plane fit is made of — the covariance of the patch's
points — and subtracts the mean's outer product from the second moment. The mean
it subtracts has already been averaged, and is then divided by the count again:

```python
p_mean = 1 / n_points * np.mean(x_mat, axis=0, keepdims=True).T
m_mat = 1 / n_points * np.matmul(x_mat.T, x_mat) - np.matmul(p_mean, p_mean.T)
```

`np.mean` divides by `n_points` already, so `m_mat` is `C + (1 - 1/n²) μμᵀ`
rather than the covariance `C`: the mean's outer product is under-subtracted by a
factor, and the matrix is inflated along the direction of the neighbourhood's own
offset from the origin. The eigenvector with the smallest eigenvalue is then not
the normal of the best-fit plane in general.

**The code.**
[`sensor_processing.py:437-441`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/utils/sensor_processing.py#L437-L441).

**What it should be.** `p_mean = np.mean(x_mat, axis=0, keepdims=True).T` — once.

**Why it is suspected rather than observed.** The neighbourhood the fit uses is
already expressed relative to the middle pixel (`center_neighbors` subtracts it),
so for a symmetric neighbourhood `μ` is near zero and the difference is nil. It
shows when the neighbourhood is one-sided — the middle pixel near the edge of the
object, so that most of the patch is masked out — and even then it is small: on a
five-centimetre sphere's patch at five centimetres, with a quarter-patch
neighbourhood, the two estimates differ by about a degree. Measured here with
numpy against the covariance the comments describe, not from a Monty run.

**What this port does.** Reproduces the expression as it stands
([`sensor_processing.ex`](../lib/monty/frameworks/utils/sensor_processing.ex)),
so a normal estimated here and one estimated by Monty move together, and records
it at the code site.

## 1.10 The "pose not defined" flag is written where nothing reads it

**In one line:** the flag lands in `features`, while every reader looks in
`morphological_features`.

**What's wrong.** A sensor module computes whether the curvature directions are
meaningful — two principal curvatures that differ by less than
`pc1_is_pc2_threshold` leave the directions arbitrary — and reports that as the
morphological feature `pose_fully_defined`. When it could _not_ do the fit at all
(no curvature feature was requested, or no surface normal was found) it flags the
percept anyway, but writes the flag into the **non-morphological** features:

```python
        else:
            # Flag that PC directions are non-meaningful for e.g. downstream motor
            # policies
            features["pose_fully_defined"] = False
```

So a percept can carry `pose_fully_defined: False` in its features and
`pose_fully_defined: True` among its morphological features at the same time, and
a policy that reads the morphological one — which is where the same name is
computed and where every other reader looks — sees neither. Monty's
`Message.get_feature_by_name` searches the non-morphological features first, so a
reader going through it sees the flag; a reader indexing
`morphological_features` does not.

**The code.**
[`sensor_modules.py:339-343`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/sensor_modules.py#L339-L343).

**What it should be.** `morphological_features["pose_fully_defined"] = False`,
which is the dict the same quantity is written to a few lines earlier
(`sensor_modules.py:294`).

**Why it is suspected rather than observed.** For the experiments this port runs
— a surface agent whose config asks for `principal_curvatures` — the `else` fires
only when no surface normal could be fitted, and in that case
`process_features_in_lm` is false as well, so the percept never reaches a learning
module. The disagreement is visible on a percept, not in a result.

**What this port does.** Reproduces it
([`observation_processor.ex`](../lib/monty/frameworks/models/sensor_modules/observation_processor.ex)),
with a test that pins the flag where Monty puts it.

## 1.11 The RGB blur comment names the wrong kernel size

**In one line:** the docstring says OpenCV picks `6*sigma + 1`; measured, it picks
`8*sigma + 1`.

**What Monty does.** `GaussianBlurRGB` passes `(kernel_size, kernel_size)` to
OpenCV, and its docstring says what OpenCV does when `kernel_size` is left at
zero:

```python
            kernel_size: Kernel size for blur. If 0 (default), OpenCV auto-computes
                from sigma using `6*sigma + 1` rounded to nearest odd. If specified,
                must be odd.
```

Measured against OpenCV 4.10 on a float image, the kernel it picks is
`8*sigma + 1`, rounded and forced odd — `sigma: 2` is seventeen pixels, not
thirteen
([`transforms.py:290-301`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/environment_utils/transforms.py#L290-L301)).

**What this port does.** Follows the code, because the code is what decides the
numbers: `GaussianBlurRGB` derives `round(8*sigma + 1)` and forces it odd, and a
test pins the sizes OpenCV answers (`sigma: 1` → 9, `1.5` → 13, `2` → 17). The
port's kernel was checked against `cv2.GaussianBlur` itself to `1.0e-7`, which is
float32 precision.

**Why it matters little, and where it would.** No config that uses this transform
leaves the kernel size at zero — they give a `sigma` and take the default kernel
— so the difference is latent for Monty's own experiments, and would only show in
a config that relies on the comment's arithmetic.

---

## 1.12 Lab goes through OpenCV's 8-bit tables

**In one line:** `uint8` in, so Lab comes back 8-bit and quantised rather than
floating point.

**What Monty does.** `vocus2/images.py` converts an 8-bit RGB image to Lab and
divides by 255 to bring it into `[0, 1]`:

```python
    return cv2.cvtColor(image, cv2.COLOR_RGB2Lab).astype(np.float32) / 255.0
```

([`vocus2/images.py:22-28`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/salience/strategies/vocus2/images.py#L22-L28))

Because the input is `uint8`, OpenCV answers `CV_8U` — L from 0 to 255 for 0 to
100, and a and b shifted by 128 — so the conversion quantises, and OpenCV's
integer path is not the same arithmetic as the floating-point definition.

**What this port does.** Computes the standard chain — sRGB gamma decode,
OpenCV's D65 matrix, the Lab cube-root — in floating point, then applies the same
`0..255` scaling and divides by 255. Measured against OpenCV 4.10 over all
16,777,216 8-bit colours, the worst disagreement is **2.67 units of 255**, in the
dark saturated corner: about one percent of the range.

**Why it matters little.** The two opponent spaces, which are what VOCUS2's
`a`/`b` channels actually use for colour opponency, are exact. Lab reaches the
port only where a config names it as its colour converter, and a one-percent
lightness difference moves a salience weight by about as much. Reproducing it
exactly would mean reimplementing OpenCV's lookup tables, which is a different
kind of promise than this port makes: it reproduces Monty's numbers, not
OpenCV's rounding.

---

## 1.13 `cv2`'s area resize does something else when only one axis enlarges

**In one line:** enlarge one axis and shrink the other, and `INTER_AREA` stops
being an area average — it is neither area nor linear.

**What Monty does.** `vocus2/images.py::resize` is a thin wrapper over
`cv2.resize`, and the pyramids use `INTER_AREA` to shrink by an octave and
`INTER_CUBIC` to enlarge:

```python
def resize(
    image: npt.NDArray[np.float32],
    shape: tuple[int, int],
    interpolation: int = cv2.INTER_AREA,
) -> npt.NDArray[np.float32]:
    return cv2.resize(image, (shape[1], shape[0]), interpolation=interpolation)
```

([`vocus2/images.py:64-69`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/salience/strategies/vocus2/images.py#L64-L69))

Measured, `INTER_AREA` is the area average whenever the destination is no larger
on either axis (checked in one and two dimensions). When the destination is
larger on exactly one axis and smaller on the other, OpenCV answers something
that is neither the area average nor the linear interpolation: a 3×8 image
resized to 6×3 has 0.625 in its first pixel where the area average is 0.875.

**What this port does.** Answers the area average in every case, which is what
the name means. The parity fixture in
[`images_parity_test.exs`](../test/monty/frameworks/models/salience/strategies/vocus2/images_parity_test.exs)
pins the cases Monty reaches: an octave halving, a non-integer shrink, and three
cubic enlargements.

**Why it matters little, and where it would.** A pyramid only ever shrinks by
area and enlarges by cubic, so no Monty experiment reaches the mixed case. It
would show in a strategy that resized an image to a shape larger on one axis
only — none does today.

---

## 1.14 A pixel with no depth becomes the nearest patch in the view

**In one line:** an empty pixel scores as the _nearest_ thing in view, so a hole
in the depth map looks like an object held against the lens.

**What Monty does.** `DepthSalience.process` turns a depth image into
`-log(depth)` and then removes the infinities:

```python
        image = -np.log(image).astype(np.float32)
        image = np.nan_to_num(image, posinf=0.0)
```

([`vocus2/vocus2.py:316-317`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py#L316-L317))

A depth of zero — nothing there — is exactly what produces the `+inf`, so this
line decides what an empty pixel means to the depth channel. Mapping it to zero
puts it at the **top** of the log-depth scale: a real depth of 2 m is about
-0.69 here, so an empty pixel arrives 0.69 _nearer than everything else in the
view_, and the centre/surround difference that follows is a strong positive
response. The pixel is then one of the most salient in the map.

**Why it is probably not what was meant.** The line is removing infinities, not
choosing a meaning for absence; the natural reading of "no depth" is "no
evidence", which would be a large positive log-depth — the bottom of the scale —
or a mask. As written, a hole in the depth map is indistinguishable from an
object held against the lens.

**What this port does.** Reproduces it, arithmetic and consequence, because a
number that differs from Monty's is worse than a number that agrees with a
suspected defect. A test pins the behaviour: the empty corner answers a positive
salience, lower than a real near step's but not zero, and
`DepthSalience`'s docs say so at the code site.

**Why it is latent for Monty's own experiments.** The transforms a camera runs
before a salience module sees its depth — `MissingToMaxDepth` and
`DepthTo3DLocations` — turn a missing reading into the maximum depth, not into
zero, so the case is rare in a configured run and reachable mainly by a caller
that hands a depth image straight to the strategy.

## 1.15 Monty's two Gaussians are not the same Gaussian

**In one line:** `cv2.GaussianBlur` and `scipy.ndimage.gaussian_filter` differ in
kernel size, edge rule and reach — they are not interchangeable.

**What.** The salience code blurs with OpenCV — `cv2.GaussianBlur`, kernel size
`8σ+1` (§1.11), `BORDER_REFLECT_101` (§1.11) — and the positioning code smooths
with SciPy — `scipy.ndimage.gaussian_filter(image, sigma, mode="constant")`, a
kernel of radius `int(4σ + 0.5)`, normalised to one, applied separably with
**zero** padding. Same mathematical object, different truncation, different edge
rule, and a factor-of-two difference in how far the kernel reaches.

**Why it matters to a port.** Both are now implemented, and reusing one for the
other would be wrong by more than the smoothing: at σ = 1 the SciPy kernel has
nine taps and the OpenCV one seventeen. The SciPy rule was measured against
SciPy's own answer over an image of random values — worst difference `2e-16`
over σ = 1, 2, 3 — before it was written down, and the recorded answers of
`GetGoodView` check the whole of it, because the pixel the procedure aims at is
the maximum of the smoothed mask.

**A plateau is not a specification.** On a _symmetric_ object the smoothed mask
has a flat maximum, and which pixel NumPy's `argmax` returns is then a fact about
summation order, not about Monty: two faithful implementations can disagree by a
pixel. The fixture therefore uses a notched object, whose brightest pixel is
clear of the runner-up by `0.02` of the mask's height.

---

# 2. Where this port deliberately differs

Decisions, not suspected defects. Each is a place where two runs can differ
without either being wrong.

## 2.1 Random streams: one stream per episode, NumPy's numbers

**In one line:** Monty threads one mutable RNG through every module; so does this
port — but as a process, not a value passed around.

**The difference.** Monty threads one mutable `RandomState` (`ctx.rng`) through
every module in step order, so what a module draws depends on how many draws
everything before it made. This port used to derive a stream per module from the
episode seed, the module id and the step, and it no longer does: the episode's
one stream is `Monty.Random.Stream`, seeded with the episode's seed and drawn by
whatever the coordinator steps next.

**The code.**
[`motor_policies.py:217`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/motor_policies.py#L217)
is where a policy draws (`self.action_sampler.sample(self.agent_id, ctx.rng)`).
Seventeen calls read `ctx.rng` across eight files — `motor_policies.py` ten
times, the sensor modules and `goal_generation.py` once each — so everything
that samples shares one stream. Ours: `Monty.Random.Stream` (the stream) and
`Monty.Random.Numpy` (the generator), reached from a module as `ctx.rng`.

**Why a process is the faithful translation.** A single mutable object shared by
everything in a step is what the BEAM calls a process. The alternative — a value
threaded through every module call — would have every module answer its advanced
stream, so the coordinator's step would be rewritten for a number generator. The
process keeps the modules pure and the ordering property exact.

**What it costs, and what it does not.** A draw is a call, and a step's draws
come in the order the modules are stepped. That is why the coordinator now steps
sensor modules one at a time: with a barrier, which module drew first would be
decided by which call arrived first. Monty's own loop is one call after another
for the same reason, so a step's _numbers_ are unaffected — a step's _wall clock_
is the sum of the sensor modules rather than the slowest.

**Measured.** Against Monty's own world
([`scripts/probe_world_episodes.exs`](../scripts/probe_world_episodes.exs),
`base_config_10distinctobj_dist_agent`), with
`Monty.Frameworks.Experiments.Seed` giving the episode seed Monty's own
`episode_seed` column: the first action of the first episode is
`turn_left 16.782644145270698°` + `look_up 20.802956601860625°` in both. Before
the stream it was `turn_left -33.06°` + `look_up 11.29°` — the salience module's
dither, drawn from a stream that was not Monty's, pushing `LookAtGoal` towards a
different point of the same view.

**What is still not Monty's, and why it is no longer this.** Two episodes of ten
agree with Monty step for step (21 and 28 steps), and eight do not:
21/27/28/36/40/34/38/37/46/45 here against 21/28/28/26/42/21/35/50/47/29. The
stream is in step for the first seven of them, though — the same number of
32-bit words consumed at every step (228, 40, 400, 420, 512, 456, 6) — and the
first action that differs is chosen while both streams stand at word 184. So the
two runs draw the same numbers and decide differently: the difference is in
goal selection at the step the learning module's evidence first drives the motor
system, and only from step 8 do the draws differ as a consequence of the
different view. That is a decision to compare, not a generator to port.

**A camera's message noise draws from the stream too, since 2026-11-06.** It used
to draw from `Monty.Context.rng_for/2` — an Erlang `:exsss` stream of the sensor's
own, one per step — so a config with `noise_params` made none of Monty's numbers
and spent none of the episode's stream: every draw after it belonged to a
different experiment. `DefaultMessageNoise` now draws NumPy's normals from
`ctx.rng` (`Monty.Random.Stream.normals/4`, and `random/1` for a boolean's
probability), which is where Monty's `rng.normal(0, sigma, shape)` and
`rng.random()` read. The numbers themselves are pinned against
`numpy.random.RandomState(7)` in `camera_sm_test.exs`.

**Measured, `unsupervised_inference_distinctobj_dist_agent`, seed 42, episode 1,
step 0** — the first observation of the episode, per graph's highest evidence,
against a run of Monty's own captured from its dashboard stream
(`contrib/liveview_experiment` broadcaster, `zmq_port`):

| graph           | Monty, `noise_params` removed | this port, `noise_params` removed |
| --------------- | ----------------------------- | --------------------------------- |
| mug             | 0.926976537864891             | 0.926976537864891                 |
| bowl            | 0.911301662451220             | 0.911301662451220                 |
| strawberry      | 0.809914                      | 0.809913732534838                 |
| mustard_bottle  | 0.806172                      | 0.806172023088476                 |
| spoon           | 0.762661                      | 0.762661333111226                 |
| potted_meat_can | 0.673517                      | 0.673516709831654                 |
| dice            | 0.633181191709936             | 0.633181191709935                 |
| c_lego_duplo    | 0.513050                      | 0.513050464142806                 |
| banana          | 0.471451                      | 0.471450867812467                 |
| golf_ball       | 0.469935                      | 0.469934640113824                 |

So the world, the positioning, the patch, the features and the feature evidence
are Monty's to the last bit — the largest disagreement in the table is one unit
in the last place. With the noise on, the same step reads 0.650 / 0.672 / 0.445
where Monty reads 0.856 / 0.880 / 0.710, and that is the remaining piece: a
`noise_params` is a **dict in Monty and a map here**, so the features are drawn in
the YAML's order there and in term order here, which assigns the same count of
draws to different features and — because `rk_gauss` keeps one spare value —
changes which `random_sample` calls interleave with it. Carrying the YAML's key
order into the composed config is the work that would close it.

Draw sites still on a per-module stream: `DepthTo3DLocations` noise,
`Monty.SensorModules.SensorModule`'s transform pipeline, and
`ActionSampler.stream/3`.

## 2.2 `motor_only_step` travels in the result

**In one line:** the flag rides in the result instead of being set on a shared
object.

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

**The half of the hack that is not a difference — keep it until Monty drops it.**
`SurfacePolicy.fixme_provide_motor_system` also sets `motor_only_step = True` on
the motor system, so a surface episode's **first** step moves the sensor and
reads nothing. That is observable in Monty's own recording: the first percept of
every episode is at step 4 or later, never at step 1
(`test/fixtures/monty_base_10simobj_episode.jsonl`, episodes at steps 4, 4, 6,
4). This port had it wrong — the step's flag was a copy that began `false` and
was only ever updated by a policy call — so a surface run handed its module a
percept at step 1 and its first real one at step 3 of a different cycle. Now the
policy answers `reads_nothing_first?/0` (`SurfacePolicy`, and through it
`SurfacePolicyCurvatureInformed`, as Monty's subclassing gives it), and
`MotorSystem.new/1`, `MotorSystem.reset/1` and `State.new/1` ask for it. Monty
still marks the whole thing TODO; when he removes the line, remove these three
too.

## 2.3 The motor system answers with itself

**In one line:** every call answers the next version of itself, because a struct
cannot be changed in place.

**The difference.** `MotorSystem.call/6` answers `{actions, motor_system}` rather
than only the actions. Same for the selectors and the policies.

**Why it is deliberate.** The record of what was decided has to live somewhere,
and a struct cannot be changed in place. Monty mutates itself; this returns the
next version of itself.

**Where.** [`motor_system.ex`](../lib/monty/frameworks/models/motor_system.ex),
[`motor_policy_selectors.ex`](../lib/monty/frameworks/models/motor_policy_selectors.ex).

## 2.4 `get_output/1` answers `{message, lm}`

**In one line:** `{message, module}`, so every step in the port has one shape to
compose.

**The difference.** Monty's returns the `Message` alone; ours answers it with the
module, like every other step in this port.

**Why it is deliberate.** One calling convention for every step, so composing
steps does not need to remember which ones answer bare values.

**What to do about it.** A caller that wants the confidence reads
`elem(result, 0).confidence`. See
[`EvidenceGraphLM.get_output/1`](../lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex).

## 2.5 A sampler answers the stream it leaves behind

**In one line:** `{action, rng}` — the caller threads the stream, so several
draws in one step get different answers.

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
slow. [`scripts/bench_samplers.exs`](../scripts/bench_samplers.exs) records that
threading is also the cheaper
option (1.0 µs against 1.4 µs per draw, in a ~39 ms step), but that is a
tie-breaker, not the reason.

**What it costs.** The same as §2.1: the numbers a draw produces are Monty's for
a given stream, but the stream is not Monty's.

## 2.6 `get_top_two_pose_hypotheses_for_graph_id/2` answers `{best, nil}`

**In one line:** "there is no second hypothesis" is a value here, not a raise.

**The difference.** Monty raises where this port returns a value — see
[§1.4](#14-argsort-2-on-a-single-hypothesis).

**Why it is deliberate.** A goal generator running without a hypothesis to test
is a normal state, not an exception, and a crash in the middle of an episode is
worse than a goal that is not proposed.

**Where.** [`evidence_graph_lm.ex`](../lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex).

## 2.7 `depth_at_center` is a function, and the policies delegate to it

**In one line:** the centre-pixel read lives with the procedures; policies reach
it through their own namespace.

**The difference.** Monty keeps it in `positioning_procedures.py`, as a
`@staticmethod` of `PositioningProcedure` at
[line 75](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/environments/positioning_procedures.py#L75).
Here it is
[`PositioningProcedures.depth_at_center/3`](../lib/monty/frameworks/environments/positioning_procedures.ex),
reading the same shape — `observations[agent_id][sensor_id]["depth"]`, centre
pixel — and
[`MotorPolicies.depth_at_center/3`](../lib/monty/frameworks/models/motor_policies.ex)
delegates to it.

**Why it is deliberate.** A behaviour cannot carry a static function, so the
question lives with the procedures and the policies reach it through their own
namespace, which is where the policies' code already asked it from while the
environment layer was unported. The call sites read as they did.

## 2.8 Small vocabulary differences

**In one line:** atoms for closed sets, tuples for quaternions, and Monty's units
wherever a number could differ.

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
  → [`action.ex`](../lib/monty/frameworks/actions/action.ex)

**Why it is deliberate.** Atoms for closed sets, tuples for quaternions, and
Monty's units throughout: the vocabulary stays Monty's where it would show up in
a number, and becomes Elixir's where it would not.

## 2.9 Inheritance becomes public functions and a module-dispatched hook

**In one line:** a public function plus a module-dispatched hook replaces
Python's class hierarchy — same actions, different address.

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

## 2.10 Missing coverage counts as zero

**In one line:** a coverage nobody asked for reads as zero, instead of raising
`KeyError`.

**What Monty does.** A sensor module's percept is built from the middle pixel, and
a surface sensor may still extract features with that pixel off the object as long
as part of the patch is on it — so the condition reads the coverage it computed a
few lines earlier:

```python
        if on_object or (self._is_surface_sm and features["object_coverage"] > 0):
```

`features["object_coverage"]` only exists if the config asked for that feature, so
a surface sensor that declared some other features and whose middle pixel is off
the object raises `KeyError`
([`sensor_modules.py:222`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/sensor_modules.py#L222)).
Every config Monty ships that sets `is_surface_sm: true` also asks for
`object_coverage`, so the crash is latent there.

**What this port does.** Reads a coverage that was not asked for as zero
([`observation_processor.ex`](../lib/monty/frameworks/models/sensor_modules/observation_processor.ex)),
which answers the same question — "is any of this patch on the object?" — without
making a missing feature a crash. The percept itself still carries only the
features the config declared.

---

## 2.11 A sensor with no surface answers `nil`

**In one line:** a sensor that saw no surface says so; it does not invent a
location no pixel supports.

**What Monty does.** `CameraSM.step` always answers a percept: the processor
reads `observation["semantic_3d"]` and indexes its middle row, so an observation
that never went through the depth-to-points transform raises `KeyError` rather
than reporting nothing
([`sensor_modules.py:196`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/sensor_modules.py#L196)).
Monty's own environments always run the transform, so the path is never taken
there.

**What this port does.** `ObservationProcessor.process/2` answers
`{:error, :no_point_cloud}`
([`observation_processor.ex`](../lib/monty/frameworks/models/sensor_modules/observation_processor.ex))
and `CameraSM.step/4` answers `nil`
([`camera_sm.ex`](../lib/monty/frameworks/models/sensor_modules/camera_sm.ex)) —
a sensor that saw no surface, which is a different thing from a sensor that saw a
surface it could not fit. The runtime already has a shape for a sensor with
nothing to say on a step: a module whose percept is `nil` contributes nothing to
the learning modules' inputs.

**Why it is deliberate.** The stand-in world in this port can answer an
observation that has not been through the transform — the view finder's
observation, before a transform the port has not written runs — and a percept
invented for it would carry a location that no pixel supports. A percept
describing nothing is worse than no percept at all.

---

## 2.12 The sensor's pose is composed once

**In one line:** one function composes a sensor's world pose, called by both
sensor modules — one rule, not two copies.

**What Monty does.** The sensor's place in the world is the agent's pose with the
sensor's own offset turned and added, and its rotation the two rotations
multiplied. Monty writes those two lines in two classes —
`CameraSM.update_state`
([`sensor_modules.py:565-570`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/frameworks/models/sensor_modules.py#L565-L570))
and `SensorModule.update_state`
([`sensor_module.py:193-198`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/sensor_modules/sensor_module.py#L193-L198)):

```python
        self._sensor_state = SensorState(
            position=agent.position
            + qt.rotate_vectors(agent.rotation, sensor.position),
            rotation=agent.rotation * sensor.rotation,
        )
```

**What this port does.** One function, `AgentState.sensor_pose/2`
([`agent_state.ex`](../lib/monty/frameworks/models/motor_system_state/agent_state.ex)),
which both sensor modules call. It also owns the error for an agent that has no
such sensor, so the two classes cannot disagree about what that means.

**Why it is deliberate.** The two copies are one rule, not two: a change to how a
sensor is placed — a different offset convention, a normalised rotation — would
have to be made twice in Monty, and a run that got it once would disagree with
itself. Nothing observable moves: the same numbers come out of both callers, and
a test pins the composition through each of them.

---

## 2.13 Two protocols and a mutable transform become one behaviour and a threaded value

**In one line:** two `Protocol`s become one behaviour, and a transform answers the
transform it leaves behind instead of mutating itself.

**What Monty does.** `tbp/monty/sensor_modules/sensor_module.py` declares
`RuntimeSensorModule` and `Transform` as `Protocol`s, and
`tbp/monty/experiment/sensor_module.py` declares `ResettableSensorModule` and
`ExperimentTransform`. The protocols exist so a runtime can ask
`isinstance(module, RuntimeSensorModule)` or
`isinstance(transform, ExperimentTransform)` — structural typing, not a base
class. And a transform is a mutable object: the sensor module calls it and the
object keeps whatever it learned
([`sensor_module.py:180-186`](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/sensor_modules/sensor_module.py#L180-L186)).

**What this port does.** Three things, all of them the same discipline the rest of
the port follows:

- a protocol that only asks "does this object have these functions?" is a
  behaviour here, and the port has exactly one sensor behaviour —
  `Monty.Frameworks.Models.AbstractMontyClasses.SensorModule`. So
  `RuntimeSensorModule` and `ResettableSensorModule` do not become modules at all
  (they are the only two classes marked `:excluded` in the module map for this
  reason); a sensor module _is_ something with `update_state/2`, `step/4` and
  `reset/1`;
- `Transform` is a behaviour, `Monty.SensorModules.SensorModule.Transform`, and a
  transform that can also be reset declares the second one,
  `Monty.Experiment.SensorModule.ExperimentTransform` — the same two callbacks,
  which is what Monty's protocol pair means;
- because an Elixir struct cannot be mutated, a transform answers the transform it
  leaves behind: `call(transform, ctx, payload) :: {payload, transform}`, and the
  sensor module keeps that one for the next step. A reset then has something to
  reset, which is what `ExperimentTransform` is for.

**Why it is deliberate.** Without the threading, a stateful transform — a
smoothing filter, a background model — would be frozen at construction and would
silently behave as if it were stateless. It is the same answer the port already
gives for samplers (§2.5) and for every step in the runtime: the result comes out
with the state it left.

---

## 2.14 The positioning loop is bounded

**In one line:** bounded at 100 steps, with an error that says so, instead of a
run that hangs.

**What Monty does.** `ExperimentEnvironment.pre_episode` builds each configured
positioning procedure and steps the environment until the procedure answers
`terminated` or `truncated`, with no bound on the number of steps ([environment.py
lines 240-267](https://github.com/thousandbrainsproject/tbp.monty/blob/91303642784ce176e2b8196c7bb990fef57688b6/src/tbp/monty/experiment/environment.py#L240-L267)).
A procedure that neither reaches the object nor gives up therefore hangs the
experiment.

**What this port does.**
[`Monty.Runtime.Positioning.prepare/5`](../lib/monty/runtime/positioning.ex) stops
after `:max_steps` (100 by default) and answers
`{:error, {:positioning_did_not_finish, steps}}`.

**Why.** A hang inside a supervised job is a wedged run that nobody can see; an
error is a run that says what went wrong. Monty's own procedures finish in a few
dozen steps on the shipped configs — a studio run of
`base_config_10distinctobj_dist_agent` takes 25 — so the bound only fires where
Monty would have hung.

## 2.15 Two recording environments, and only one of them is Monty's

**In one line:** two interpreters on purpose, and every recording says which one
made it.

**What Monty does.** `environment_arm64.yml` pins `python=3.8`,
`numpy<=1.23.5` (because `numpy >= 1.24` drops `np.long`), `quaternion=2023.0.3`
(same reason), `scikit-learn=1.3.2`, `pytorch=1.13.1`, `pyg=2.1.0`,
`pytorch-scatter=2.0.9`, `pytorch-sparse=0.6.15` and `habitat-sim=0.2.2`.

**What this port records with.** Two interpreters, on purpose:

- Monty's own conda environment `tbp.monty` — Python 3.8.20, `numpy` 1.23.5,
  `quaternion` 2023.0.3, `scipy` 1.10.1, `scikit-learn` 1.3.2, `torch` 1.13.1,
  `torch_geometric` 2.1.0, `torch_sparse` 0.6.15, `torch_scatter` 2.0.9,
  `omegaconf` 2.3.0, `habitat_sim` 0.2.2 — which is the pin list above. Anything
  that needs Monty's learning modules or its simulator is recorded here.
- A throwaway Python 3.13 environment built by
  [`scripts/setup_monty_oracle.sh`](../scripts/setup_monty_oracle.sh) for the
  recorders that only need arithmetic: `numpy` 2.4.1, OpenCV 4.10.0,
  `quaternion` 2024.0.13, `scipy` 1.18.1, `omegaconf` 2.4.0, `scikit-learn`
  1.9.1, and `torch` 2.15.0 with `torch_geometric` 2.8.1 when asked for. Used
  where the conda environment is absent, and never where a Monty answer is what
  is being recorded.

**Why.** The pinned environment exists here, so parity recordings are made in it;
the pip environment removes the "install conda, then 3.8, then Habitat" cliff
from any other machine, at the cost of recording a newer library's answers. The
two are not interchangeable and a recording says which ran it.

**What this does not license.** OpenCV is 4.13.0 in the pinned environment and
4.10.0 in the pip one; the fixtures that compare against OpenCV (§1.12, §1.13,
§1.15) were recorded under 4.10.0. Re-recording them in the pinned environment
would be measuring 4.13.0, which is a different measurement, not a fresher one.

## 2.16 Distractors are refused, not placed

**In one line:** `{:error, {:distractors_not_supported, n}}` for any `n > 0`,
because the stand-in world holds one object.

**What Monty does.** `OneObjectPerEpisodeInterface` adds the primary target, then
draws `num_distractors` names from the source list — everything but the target —
places them around it, and records for each whether it is the primary target.

**What this port does.**
[`OneObjectPerEpisodeInterface.place_distractors/2`](../lib/monty/experiment/environment/one_object_per_episode_interface.ex)
answers `{:error, {:distractors_not_supported, n}}` for any `n > 0`, and
`change_object_by_idx/3` passes that up. Everything above it is Monty's: which
objects a distractor may be drawn from (`distractor_candidates/2`), the target's
semantic id, and the attributes the scene is asked to add it with.

**Why.** The stand-in world holds one object. Placing "distractors" it cannot
hold, or quietly running an experiment that asked for a cluttered scene and got an
empty one, would make a number that means something different from Monty's. A
refusal is a run that says which feature is missing.

## 2.17 A recognition policy is given what it reads, not the model

**In one line:** four readings, not the live model — so a decision can be recorded
and replayed.

**What Monty does.** A policy is `__call__(self, model: MontyBase, count)`: it is
handed the model object and reads whatever it likes off it — `model.is_done`,
`model.is_exploring`, `model.matching_steps`, and
`lm.recognition_status.conclusion` for each learning module. It also logs and
telemeters every terminal decision through `logger.info` and `telemeter.info`.

**What this port does.**
[`Monty.Experiment.RecognitionStrategy`](../packages/ex_tbp_monty_core/lib/monty/experiment/recognition_strategy.ex)
declares a model _view_ — a map with exactly the readings a policy takes: the
four above, plus the modules' terminal states and the model's match criterion,
which `MatchCriteria` asks the model for. Each policy is a `{module, state}` pair
dispatched by `RecognitionStrategy.call/3`. Constructors answer `{:ok, policy}` or
`{:error, message}`, carrying Monty's `ValueError` sentences.

**Why.** The decision is what has to be compared with Monty's, and a decision
that can reach into live processes is a decision that cannot be recorded and
replayed. [`scripts/record_monty_recognition_strategy.py`](../scripts/record_monty_recognition_strategy.py)
asks Monty's real classes over the same view; the port answers every one of them
the same way.

**What is therefore not compared.** The log lines and telemetry events Monty
emits when a policy fires. They are the experiment's reporting, not its
arithmetic; when the episode loop is wired to these policies, what it reports is
its own concern.

## 2.18 A memory arrives as an export, not as a pickle

**In one line:** `.pt` becomes JSONL once, off the BEAM; a run is handed a copy,
because a run learns.

**What Monty does.** A pretrained learning module is a torch pickle (`.pt`)
holding `GraphObjectModel`s; `MontyExperiment` loads it into the learning modules
it has just built (`initialize_model` in `monty_experiment.py`).

**What this port does.** `Monty.Studio.Pretrained.Torch`
reads that pickle in
Monty's own environment and writes the graphs out as JSONL under the data
folder — `<data>/libraries/<release>/<model>.jsonl.gz`, one object per line,
positions and the
four matched features per node, every number at full precision (these files were
once rounded to six decimals, and [`validation.md`](validation.md) records what
that cost).
`Monty.Studio.Memory` reads one
back into a `GraphMemory`, and a run builds its learning module around it
(`EvidenceGraphLM.from_config/2` takes an optional `:memory`). The library's
README records which release and which command produced each file.

**Why.** The port cannot read a torch pickle and should not learn how: what a
model _is_, for matching, is a position per node and a row of features per node,
and both are plain numbers. Exporting them once keeps `torch` out of the Elixir
runtime entirely.

**The consequence worth stating.** Decoding is about six seconds and the result
is about four megabytes, so the decoded memory is cached per library path in
`:persistent_term` and every run is handed a _copy_ (about twenty milliseconds).
The copy is not an optimisation detail: a run learns, so two runs sharing one
memory would learn into each other's, which Monty never does — it loads the
pickle afresh for each experiment.

**And the mode.** `ExperimentMode` is an enum of the strings `"eval"` and
`"train"` in Monty; here it is `:eval` and `:train`
([`ExperimentMode`](../lib/monty/frameworks/experiments/mode/experiment_mode.ex))
with `to_string/1` and `from_string/1` for the places a config or a log needs the
string.

## 2.19 "Back where it started" is an angle, not the same floats

**In one line:** compared as an angle under 0.001°, because the quaternion
round-trip is 1.1e-16 away.

**What Monty does.** `InformedPolicy._assert_undo_jump_was_successful` compares
the agent's pose after an undo jump with the pose it stored before the jump, with
`np.all(state[agent].rotation == self._pre_jump_state.rotation)` — exact
equality, on quaternions, and it raises when they differ.

**What this port does.** The position is compared exactly, as Monty's is; the
orientation is compared as an **angle**, and anything under a thousandth of a
degree counts as where it started
([`InformedPolicy`](../lib/monty/frameworks/models/motor_policies/informed_policy.ex)).
The raise now says how far the agent was turned, so the number is in the sentence
rather than something to reproduce.

**Why exact equality cannot hold here.** Monty stores the quaternion the
environment gave it and hands that same quaternion back, so the comparison is
between one value and itself. An agent's rotation here is rebuilt from the
world's answer by **normalising** the quaternion the world reports
(`Rotation.from_quaternion/1`), so a pose that is put back exactly still comes
back **1.1e-16** away — measured by `Rotation.to_quaternion/1` followed by
`Rotation.from_quaternion/1`. Monty's assertion is not too strict for Monty; it is
too strict for a rotation that makes that trip, and it fired on
`base_10simobj_surf_agent` after ten objects, ending a run that had done nothing
wrong.

**What it costs.** Nothing that is measurable: a jump that misses by even a
hundredth of a degree still raises, and the raise now carries the angle.

---

## 2.20 A supervised episode's answer is a call, and an impossible config is refused

**In one line:** six numbers through one call per module, and two refusals where
Monty would raise mid-run.

**What Monty does.** `MontySupervisedObjectPretrainingExperiment` runs its
training episodes as exploration and then reaches into every learning module to
state the answer the experiment already knows:

```
lm.detected_object = target.object_name
lm.buffer.stats["possible_matches"] = [target.object_name]
lm.buffer.stats["detected_location_on_model"] = self.first_epoch_object_location[target.object_name]
lm.buffer.stats["detected_location_rel_body"] = target.position
lm.buffer.stats["detected_rotation"] = target.euler_rotation
lm.detected_rotation_r = Rotation.from_quat(target.quat_rotation).inv()
lm.buffer.stats["detected_scale"] = target.scale
```

and, for a module it does not supervise, clears those fields so that
`update_ltm_from_stm` has no `detected_object` to write a graph under.

**What this port does.** The same six numbers, in the same order, through one
function per module: `GraphLM.supervise/3` for a module the experiment names and
`GraphLM.clear_hypotheses/1` for the others
([`graph_lm.ex`](../lib/monty/frameworks/models/graph_matching/graph_lm.ex)).
`Monty.Studio.Run.supervise/1` reads the target off the world and calls the
model once, which is where the loop stops being able to reach into a module: a
module here is a process, not an attribute
(§2.9 says the same about every other method the model calls).

Two things follow from that, and both are refusals rather than stand-ins:

- **`GraphLM.from_config/2` refuses the base class.** `graph_1lm.yaml` names
  `GraphLM` itself; Monty builds it and raises `NotImplementedError` on the
  second step, inside a run. Here the setup is refused before it starts, with the
  sentence "a bare graph module has no matching scheme to narrow possible matches
  with" (§2.6 of the hand-over is why this is a finding and not a stand-in).
- **A supervised experiment against the stand-in scene is refused.** The answer
  it states is read off `primary_target`, and the synthetic sphere answers none,
  so `Setup` refuses the run (`:no_target_to_supervise`) rather than crashing at
  the end of an episode that had already run.

**What this does _not_ change.** The `location_on_model` a module is given is the
object's place the _first_ time the experiment showed it, not this episode's —
Monty's `first_epoch_object_location`, carried by the run. A later epoch that
places the object elsewhere still extends the graph it built the first time.

**One repair came with it.** Monty's `Predefined` and `RandomRotation` samplers
write `quat_rotation` beside `rotation`, the same `wxyz` quaternion under a
second name, and the world's `primary_target` is a `PrimaryTarget` — an
`object_name`, a `semantic_id` and every sampled parameter
(`experiment/primary_target.py`) — so every sampled parameter travels with the
answer. This port dropped `euler_rotation` and `quat_rotation` when it copied a
sampled object into its scene, so a target here had no turn to state. Both
samplers carry `quat_rotation` now, `priv/monty_py/world.py` keeps it, and
`supervise/3` raises with the object's name if a target still has none. The
target's own key is `object_name` here too, which is what Monty renamed it to
once the type had a field of that name.

## 2.21 An object-orientation channel's evidence is ported but not yet dispatched

Monty's PR #1266 splits the scored distances in two — `euclidean_distances` for a
channel whose pose is an object orientation, `custom_distances` for one whose pose
is a surface — and scores the orientation case with a new
`_object_pose_evidence`, the angle between two rotation matrices off the trace of
their relative rotation. Both pieces are here, with their tests translated
(`GraphMatchingUtils.euclidean_distances/2`,
`HypothesesDisplacer.object_pose_evidence/2`), and `flatness/1` now names its
`0.5` as `@minimum_curvature`.

What is not here is the dispatcher that would choose between them. Monty reads it
from the channel's own pose type (`isinstance`), and every channel this port
builds so far carries a `SurfacePoseVectors` pose: the sensor modules that send
an `OrientationMatrix` belong to the `experiment/` layer, which the module map
still lists as planned. Wiring it before there is a channel to dispatch on would
be a branch no run can take.

## 2.22 "In parallel" divides one run's work into parts

Monty runs an experiment in parallel with a second script,
`framework/run_parallel.py`. It generates **one config per part** —
`generate_parallel_eval_configs` writes a config per object _and_ rotation,
`generate_parallel_train_configs` one per object with its rotations in sequence —
hands them to a `multiprocessing.Pool(num_parallel)`, and when the pool is empty
merges what they produced: `load_state_dict_from_parallel` loads every part's
`model.pt` into one model (`post_parallel_train`), the CSVs and transcripts are
concatenated (`post_parallel_eval`), and the parts' directories are deleted.

This port divides the same way, with two differences that are the studio's rather
than the maths':

- **A part is a piece of one run, not a run.** Monty writes one config per
  episode of an evaluation; here the plan is `Monty.Studio.Partition`, and `n` in
  parallel is `n` parts of the experiment — `n` contiguous stretches of the
  episode list for evaluation, and one part per object (objects taken in turn
  when there are more objects than workers) for training. The division of _work_
  is Monty's; only the number of pieces a page draws is the studio's, because a
  page with a chart and two pictures per episode would have a hundred and forty
  of them.
- **One record and one job for the whole experiment.** The parts are processes
  inside that job (`Task.async` under a meeter, `Monty.Studio.Jobs.Run`), not
  jobs of their own: the Runs page shows the experiment once rather than `n`
  times, and one process writes the row. Each part keeps a stream of its own —
  its steps, its frames, its memory — under the stream id the record's plan gave
  it, and its steps carry the experiment's own episode number, so the run's
  transcript and chart are all the parts one after another.
- **A part's pictures are the run's pictures**, kept in the run's own directory
  in a folder named `part-<index>-<step>`: a picture is fetched from a run, and a
  part's stream id has no run row behind it.
- **The trained memory is handed to the evaluation.** `run_parallel.py` generates
  the evaluation configs from the original config, so a config that trains and
  then evaluates is evaluated under `run_parallel` against the memory its config
  _names_, not the one its training built. Here a batch of such a config runs a
  training wave, then `Monty.Studio.Jobs.Merge` merges the parts' memories
  (`Monty.Studio.Memories`, Monty's `load_state_dict_from_parallel` per module)
  and starts the evaluation wave pointed at the merged library. That is one thing
  this port does that Monty's runner does not.

Episode numbers are shared, not renumbered: a part walks the experiment's own
episode numbers (`0, 2, 4, …` for the second of two training objects), because the
number is what says which object stands in front of the agent, which rotation it
is and which draws the episode takes. Monty's partitioned training configs instead
repeat one object in the interface and set `change_every_episode: true`; with the
numbers kept, the same episodes come out without the flag.

A part of a training wave keeps its memory in its own directory and does not write
the library tree (`Learned.keep(..., library: false)`): the library is what the
parts learned between them, and a part that wrote it as it finished would overwrite
the merged memory with its own share.

## 2.23 How often a surface agent reads

**In one line:** three gates decide whether a module sees a percept, and all
three are the model's, so all three are ported — the cadence they add up to is the
world's.

**What Monty does.** A surface agent does not look at the object every step:

1. **The step is not motor-only.** `SurfacePolicy` sets `motor_only_step` unless
   the action it has just chosen was `OrientVertical` — its own comment: "we only
   want to send data to the learning module after taking the OrientVertical
   action; the other three actions in the cycle are motor-only to keep the
   surface agent on the object". The flag is read at the _start_ of a step, so it
   decides the step after the one that set it, and
   `fixme_provide_motor_system` starts every episode with it `True` (§2.2).
2. **The sensor module passes the message.** `CameraSM`'s
   `FeatureChangeFilter` sets `process_features_in_lm` from the config's
   `delta_thresholds`, which for this experiment are `on_object: 0`,
   `n_steps: 20`, `hsv: 0.1, 0.1, 0.1`, `pose_vectors: [π/4, 2π, 2π]`,
   `principal_curvatures_log: [2, 2]` and `distance: 0.01`; a percept that is not
   on the object never passes.
3. **The module treats that as a displacement only.** When no percept carries
   features, `is_location_only_step` makes `matching_step` call
   `_displace_hypotheses` and return: the hypotheses move with the agent, no
   matching runs and no evidence changes.

**Why the numbers are what they are.** A tangential move is 4 mm
(`ConstantSampler`'s `translation_distance`) and the distance threshold is 10 mm,
so distance alone can never fire; a read happens when the colour, the surface
normal or the log curvatures moved more than their threshold, or after twenty
steps. In Monty's recording of `base_10simobj_surf_agent`
([`test/fixtures/monty_base_10simobj_episode.jsonl`](../test/fixtures/monty_base_10simobj_episode.jsonl))
the module is given a percept at episode steps 4, 16, 20, 32, 36, 40, 44, 48 and
52: twelve steps between the first two, four between the rest, so the agent walks
three cycles across a flat part with nothing worth matching and reads on every
cycle once the surface starts to bend.

**Where the port stands.** All three gates are here:
`SurfacePolicy.reads_nothing_first?/0` with `MotorSystem.new/1` and `reset/1` for
the opener (§2.2); `FeatureChangeFilter` built from the config's
`delta_thresholds`, which arrive as numbers because
[`Monty.Config.Resolvers`](../packages/ex_tbp_monty_core/lib/monty/config/resolvers.ex)
evaluates the `${np.list_eval:...}` in the YAML; and
`Monty.Runtime.location_only_step?` inside `EvidenceGraphLM`.

**Where Monty's run is the cheaper one.** A location-only step skips the matching
work outright, so Monty pays for a match at best once every four steps and once
every twelve on a flat face. A run of ours that reads on every cycle does four
times the matching for the same movement; that, and not the model, is what a
reader sees as "his run is faster". The model itself is exact: replaying Monty's
own percepts through `EvidenceGraphLM`
([`test/monty/surf_replay_test.exs`](../test/monty/surf_replay_test.exs))
reproduces his evidence to `1e-12` and his conclusion exactly.

**The percept is his too — measured, not assumed.**
[`scripts/probe_percept_parity.exs`](../scripts/probe_percept_parity.exs) gives
our world Monty's own first three actions and reads the patch he read at step 4:
his middle pixel `hsv [0.9966667, 0.6756757, 0.5803922]`, his `min_depth`
`0.024471`, his `mean_depth` `0.024568`, to the last bit. The two MuJoCo bindings
also render the same bytes as each other
([`scripts/probe_world_parity.exs`](../scripts/probe_world_parity.exs)). So a run
of ours that pays more per movement is paying for **different actions on a
different trajectory**, not for a different renderer or a different feature
calculation — and the recording is what makes that measurable step by step.

That comparison also turned up the last bit it took to be exact: skimage's
`img_as_float` scales a byte by the reciprocal of 255, and `148 * (1/255)` is one
double away from `148 / 255`. `SensorProcessing.rgb2hsv/1` now scales the same
way, which is why the middle pixel's `hsv` agrees with his rather than almost
agreeing.

**And the action is his.** `scripts/probe_action_parity.exs` asks the body the one
question that needs no percept: a surface episode opens with `_touch_object`'s
forward move, and its distance is arithmetic on the view finder's middle depth and
the sensor's own offset. His recording says `0.036434554755687715`, ours says
`0.0364345532655716` — a difference of 1.5 nanometres, because the pose behind
that depth was composed along a slightly different float path. No threshold in the
policy or the filter can see that.

**And the stream is his, from the first step to the seventh.**
`scripts/probe_action_stream.exs` asks the experiment's motor system and surface
policy what they would do at every step of his episode while the world is moved by
_his_ actions. Steps 1–3 and 5–7 are his acts to the last digit — the forward
distance, both orientations, and each of their translations. The first
`move_tangentially` used to be his direction **negated**, which sent the agent
round the object the other way: a different surface, different feature changes, and
about four times the reads for the same movement.

The cause was the sign of a pair of principal directions, and it is worth knowing
why that is not cosmetic. A pair and its negation describe the same surface, so
only the sign of `(dir1, dir2, normal)` is fixed — Monty fixes it himself by
flipping `dir2` when the triple is left-handed, and numpy's `eig` decides the
remaining one. A surface policy steers by `dir1`, so the port that has numpy's
`eig` sign walks his way and the port with the opposite one walks backwards.
`SensorProcessing.principal_curvatures/4` now answers with numpy's sign — pinned
by `test/monty/frameworks/utils/sensor_processing_test.exs`, which holds it to the
numbers Monty's own interpreter gives for a bowl.

What is left was the heading _after_ a curvature-guided step: the momentum blend
that mixes a fresh curvature direction with the one last taken. Two things were
wrong there, and both are now his:

- **The blend that a step answers with.** A port that answers with the raw
  curvature direction walks a different path from the first step after a
  curvature-guided one.
- **The angle the blend remembers.** Monty writes
  `self.prev_angle = self.tangential_angle` _after_ `update_tangential_reps/1`
  has replaced the angle with the blended one, so each average is measured from
  the heading taken, not from the raw direction. The port remembered the raw one
  and lagged a step behind on every average, which is a few degrees of drift that
  compounds. With both fixed the stream is his for **28 steps** of the first
  episode, where it parted at 12 before; the next difference is a tangential
  direction at that step, still being chased with the same probe.

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

## 2.24 The vote round finds its neighbours by scanning

**In one line:** the same neighbours, the same arithmetic, found by a scan
instead of a k-d tree.

**What Monty does.** `_update_evidence_with_vote` builds a `KDTree` over the
votes the module has been given, asks it for the three nearest votes to every
hypothesis' location (`query(..., k=3, p=2)`), turns the distances into weights
(`(max_match_distance - d) / max_match_distance`) so that a vote at or beyond
`max_match_distance` is masked out, takes the masked maximum of those votes'
confidences, and blends it into the hypothesis' evidence:
`(evidence + vote_weight * vote) / (1 + vote_weight)` when
`past_weight + present_weight == 1`, and `evidence + vote_weight * vote`
otherwise.

**What this port does.**
[`EvidenceGraphLM.update_evidence_with_vote/3`](../packages/ex_tbp_monty_core/lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex)
computes the same three things in the same order, and both blends are Monty's
lines. The neighbour search is the difference: it walks the votes for each
hypothesis and keeps the three nearest, rather than asking an index. The
acceptance is the same set — `distance < max_match_distance` here is
`node_distance_weights <= 0` there, because the weight is zero exactly at the
radius — and the maximum over the surviving votes is the same value.

**Why.** There is no k-d tree on the BEAM that answers "the three nearest of a
few dozen points, repeatedly", and the port's vote rounds carry a handful of
votes: the scan is `hypotheses × votes` distance computations, which a step
affords, and it keeps the whole arithmetic in Elixir where it can be read
against Monty's. If a config ever votes with thousands of points, the index is
the answer and `native/kd_tree_nif` already exists for it.

**What is therefore not compared.** The tree's own answers — the order of equal
distances, and numpy's tie-breaking — because this port does not have a tree.
For distinct distances the two agree exactly, and the vote round is covered by
the learning module's own cases.

## 2.25 Two epoch brackets have no counterpart here

**In one line:** Monty wraps every epoch in `pre_epoch` and `post_epoch`; this
port runs the episodes of a phase and keeps the memory once, at the end of the
run.

**What Monty does.** `MontyExperiment.run_epoch` is a bracket around the episode
loop: `pre_epoch()`, one `run_episode()` per object, `post_epoch()`. The first
logs which epoch is running, sets `env_interface` to the train or the eval
interface, and calls `env_interface.pre_epoch()` and
`logger_handler.pre_epoch(logger_args)`. The second saves the model, the
experiment's counters and the config with `torch.save` into
`output_dir/<epoch number>`, calls `logger_handler.post_epoch(logger_args)`,
increments `train_epochs` or `eval_epochs`, and calls that interface's
`post_epoch`.

**What this port does.** `MontyExperiment.run_epochs/2` walks the epochs and
`run_epoch/2` walks the objects of one, which is Monty's bracket minus the two
ends. The mode and the objects are chosen once per phase
(`Monty.Studio.Setup`, `Monty.Studio.Jobs.Run`), the interface is opened per
episode, every episode is reported as it ends (`Monty.Studio.Logging.report/4`),
the epoch numbers live in the run's record, and what a run learns is kept once,
under a release named by the studio (`Monty.Studio.Learned.keep/5`). The
interface's own `pre_epoch` and `post_epoch` are ported — Monty's are no-ops —
and nothing calls them, because nothing brackets an epoch.

**Why.** What Monty's `post_epoch` writes is a checkpoint per epoch: a torch
`model.pt` and an experiment-state file per epoch directory. This port's
equivalent artefact is a memory library that the studio names by model and
release, and it is written when a run finishes. Writing one per epoch would
change what a run leaves behind and how often, which is a decision about the
studio's releases rather than a translation of Monty's line, so it is recorded
here unsolved.

**What is therefore not compared.** The epoch directories Monty leaves, the
`exp_state_dict.pt` counters it saves beside them, and the interface and logger
epoch hooks, which here have no caller.

## 2.26 A sensor keeps its step record only for a detailed logger

**In one line:** Monty appends every percept to `processed_obs` and, when
`save_raw_obs` is set, every raw observation to its telemetry, unconditionally;
this port appends either only when the run's logging reads them, because one
episode's worth is what takes a process past the run's heap ceiling.

**What Monty does.** `SensorModule.step` ends with
`self.processed_obs.append(percept.__dict__)`, and its `SnapshotTelemetry`
records the raw observation of every step when the config says `save_raw_obs:
True`. Both exist for `state_dict()` — which the detailed logger writes out and
`plot_utils_analysis.py` reads back.

**What this port does.**
[`CameraSM`](../packages/ex_tbp_monty_core/lib/monty/frameworks/models/sensor_modules/camera_sm.ex)
and [`TwoDSensorModule`](../packages/ex_tbp_monty_core/lib/monty/frameworks/models/two_d_sensor_module.ex)
take `:has_detailed_logger`, which `Monty.Studio.Setup.model_spec/3` answers from
the experiment's logging section and hands to every sensor module it builds —
the same flag, from the same place, that the learning modules already take for
their own detailed statistics. The camera keeps its raw observations when the
config asked for them **and** that flag is on, and its percepts when the flag is
on; `state_dict/1` answers both keys either way, empty.

**Why.** A raw observation is 1.6 MB of Elixir terms where Monty holds a few
numpy arrays — measured on `surf_agent_unsupervised_10distinctobj`, whose sensor
config is `save_raw_obs: true`, at 490 MB after three hundred steps, against
nothing at all for the percepts. A thousand-step episode therefore held the
sensor module's process at gigabytes, the run's heap ceiling (`run_max_heap_mb`)
killed it, and every training run of this port stopped silently at the step the
exploring phase ended — for Monty's own config, on Monty's own objects, exactly
as for a corpus of ours. Monty does not have this failure because the same list
costs it a fraction of the memory and because nothing kills a Python process for
it.

**What is therefore not compared.** The step record a run whose logging is not
detailed would have kept: `state_dict()['raw_observations']` and
`['processed_observations']` are empty there, where Monty's hold the episode. A
run that wants them says so in its logging section, and then keeps them as Monty
does.

## 2.27 A library says which object each graph was built from

**In one line:** Monty keeps `graph_id_to_target` on the learning module and
saves it with the model; this port's library used to keep the graphs alone, so a
recognition run could not say whether a `match` named the object it was shown.

**What Monty does.** `GraphLM._update_target_graph_mapping` records two sets in
the module — graph → the objects it was built from, and object → its graphs — and
`fixme_update_ground_truth` calls it after a training episode with the object the
experiment placed. Both live in the module's `state_dict`, which is what a
checkpoint holds, so a run that loads a pretrained model loads the answers with
it, and `logging_utils.unsupervised_stats` can ask "was the target among the
possible matches" of a memory it did not build.

**What this port does.** The same two maps live on
[`EvidenceGraphLM`](../packages/ex_tbp_monty_core/lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex)
and are updated the same way. They are now written into the library too:
`Monty.Studio.Memory.save_all/4` takes each module's map beside its memory and
writes a `targets` list into every record, `Monty.Studio.Memory.load_with_targets/4`
reads it back, and `Monty.Studio.Setup` hands it to the module it builds
(`:memory_targets`), which indexes itself by those names instead of by the graph's
own id. `mix monty.run` reads the map off each module at the end of a training
episode (`Monty.Studio.Run.memory_targets/1`) and passes it to
`Monty.Studio.Learned.keep/5`.

A phase is a sequence of episodes and each one builds a graph under an id of its
own, so the map a phase writes down is every episode's.
`Monty.Studio.Run.merge_targets/2` — this port's addition, with no Monty
counterpart — is that union, and every episode's model is built with the names the
phase already has (`:memory_targets` on `Monty.Studio.Run.start/2`), so its own
update adds to them instead of starting again from the library on disk.

**Why.** A graph an unsupervised training run names `new_object3` carries no
identity: eight dogs gave four graphs, four of them concluded on `new_object3`,
and the library held nothing that could say whether that was the dog the episode
had shown. A `match` was therefore a conclusion and not an answer — the number
this corpus exists to measure could not be computed at all. A library written
before records carried `targets` is read as it always has been: a graph is named
after the object it was stored under, which is what this port assumed. Keeping
only the last episode's map was the other half of the same silence, and it hid
behind the first half: a phase that trained on five dogs named one graph and left
the rest called `new_object0`, which read as "this port has no names" rather than
as "this port threw four of them away".

**What is therefore not compared.** Monty's `.pt` checkpoint, which carries the
whole model's state — the module's other learned fields included. Only the two
maps travel here, because they are the ones a later run scores itself against.

## 2.28 A sensor says whether it draws from the episode's stream

**In one line:** Monty's `SensorModule` interface has a callback this port added,
`draws_from_stream?/1`, because a step here steps the sensors of a phase at once
and may only do that when none of them draws.

**What Monty does.** `Monty.step` calls each sensor module in turn, on one thread,
and every draw a sensor takes comes out of the environment's generators in that
order. What a sensor draws is therefore never a question Monty asks: the order is
given by the loop.

**What this port does.**
[`SensorModule`](../packages/ex_tbp_monty_core/lib/monty/frameworks/models/abstract_monty_classes/sensor_module.ex)
carries an optional `@callback draws_from_stream?(state) :: boolean()`, declared
in the `use` block with the other optional callbacks and defaulting to `false`.
`Step` asks it once, when the model is built, and reads the answer as permission:
the sensors of a phase that all answer `false` can be stepped concurrently, and
one that answers `true` pins the phase to Monty's serial order. The episode's
single stream is `Monty.Random.Stream` (§2.1), whose draws must be taken in the
order the episode takes them or the numbers stop matching Monty's.

Three ported classes answer it, each saying in the code that the method is
ours and not Monty's: `CameraSM` and `TwoDSensorModule` answer `true` exactly
when their config gave them `noise_params`, and `SalienceSM` answers `true`
always, because it dithers every informative step.

Around the callback the port also has `Monty.Runtime.Step.State.sensors_step/1`
— `:concurrent` for a set of sensors that draw nothing, `:serial` for a set in
which one does — and a run option of the same name (`:auto`, the default,
`:serial` or `:concurrent`) so the two rounds can be run against each other.
Neither exists in Monty: it has no such question, and the option is a run's, not
a config's — Monty's Hydra YAML has no key for it and this port added none.

**Why.** Stepping sensors concurrently is where this port's speed comes from on
a config with several of them, and a concurrent step of a module that draws would
order its draws by completion rather than by position — a different episode, not
a faster one. The callback keeps that decision with the module that knows the
answer, instead of a list of "noisy sensors" kept somewhere in the runtime and
wrong the first time a sensor gains noise.

**What is therefore not compared.** Nothing: a sensor that does not draw answers
`false` and the phase steps it exactly as Monty's loop does. A sensor that draws
keeps the serial order, so its numbers are Monty's too.

**What it bought, measured.** `scripts/probe_sensor_rounds.exs` steps the same
episode twice, once with each round, and compares every step's percepts, actions
and terminal states. On this machine (Apple Silicon, macOS 26), the MuJoCo world
through `ex_mujoco`, `tutorial/dist_agent_5lm_2obj_eval` — six sensors, none of
them drawing — three epochs agreed step for step and the mean model step was
1793 / 110 / 456 ms serially against 1266 / 109 / 512 ms concurrently: the same
number, whichever round asks. That config's sensors are cheap; a phase that costs
its slowest sensor rather than their sum is a factor only where one sensor is
expensive, and nothing here makes a phase whose sensors are cheap faster. The
first measurement of this was wrong in the other direction, and the reason is
worth keeping: a request closure holds what the sensor needs — a round of several
requests copies that into a process of its own, so a closure over _all_ the
observations paid one copy per sensor per step and the concurrent round lost by a
factor.

## 2.29 A module's step is handed over, and waited for by epoch

**In one line:** Monty calls each learning module's step inside its own loop;
here the coordinator hands the step to the module's process as a message and
waits for the epoch only where it needs the answer — the vote round.

**What Monty does.** `MontyBase.step` calls `_step_learning_modules`, which calls
every module's `matching_step` in the caller's thread, one at a time. The step is
therefore _performed by_ the coordinator, and a module that took a second held
the loop for a second.

**What this port does.** Each module is a process with a mailbox
(`Monty.Runtime.LearningModuleServer`), and a step is given to it:

- `hand_off(server, epoch, percepts, ctx, target)` — one message carrying the
  stepwise target, the percepts and the context, answered at once. The three
  things a step used to make of a module (name it, step it, record whether it had
  anything to process) happen in the module's own process, in that order,
  including "no input, so not stepped";
- `await(server, epoch)` — `:ok` at once if the module is already past `epoch`,
  otherwise the reply arrives when it gets there; `processed_through/1` reads
  where it is.

Two messages from one sender arrive in order, so a `hand_off/5` followed by an
`await/3` cannot race: the work is always enqueued before the wait.

**Why.** It is the difference between a module _being called_ and a module
_working_: the coordinator's stack no longer grows with the module's step, and a
module's pace is its own. It is also the precondition for a continuous pipeline —
modules that keep working while their siblings do, with the epoch as the only
place the coordinator says "not before step n" — which is where this port means
to go (`docs/monty-differences.md` §2.28 already made the sensor phase a round
the sensors themselves permit).

**What is therefore not compared.** Nothing, yet: the vote round still begins
after every module has finished its step, because a vote is the module's state
_after_ its step. So the decisions are Monty's, and the suite that pins them
passes unchanged; what moved is where the work runs, not what it computes.

## 2.30 A step can be scheduled a lagged epoch behind

**In one line:** a barrier step — Monty's order, and this port's default — waits
for the modules it just handed work to before its vote round; a lagged step does
not, and integrates the epoch _before_ instead, from the report each module sent
when it finished it.

**What Monty does.** `MontyBase.step` hands each module its percepts and waits for
the answer inside the loop (`_step_learning_modules`), so the vote round — the one
place the modules' theories meet — begins only once every module has finished the
step it is voting on. Goals and regions are then asked of the modules in a second
round, after their steps. One step's work cannot overlap with the next step's
sensors, because there is one thread and it is the step's.

**What this port does.** `Monty.Runtime.Step.State.scheduling/1` is `:barrier` or
`:lagged`. A run chooses it on the experiment page — the `scheduling` box beside
its episode count, recorded on the run as `inputs["scheduling"]`, so the worker
takes the mode from the record — and `MONTY_STUDIO_SCHEDULING` answers for a run
started from the command line (`Monty.Studio.Jobs.scheduling/1`). Two runs of one
experiment, one `scheduling` apart, are read side by side on the studio's
`/compare` page: the numbers, each module's conclusions and how many episodes
reached each state, with the inputs that differ named above the table
(`Monty.Studio.Comparison`). A lagged step:

- hands epoch _n_ to every module and does not wait for it (`hand_off/5`, no
  `await/3`);
- runs its round for epoch _n − 1_, reading the vote, the goals and the region
  from the report that module sent (`handle_cast({:voted, …})`). Nothing is asked
  of a module here, because a question would queue behind the epoch it is already
  working on;
- hands the combined votes over rather than delivering them (`deliver_votes/3`),
  and the module applies them at its own next boundary (§2.29's vote round);
- replies when the last report for _n − 1_ is in hand. The reply is deferred, not
  awaited: `handle_call/3` returns `{:noreply, …}` with the step parked, and
  `GenServer.reply/2` fires in the mailbox handler that hears the last report. A
  call cannot wait for messages it will not read until it has returned, which is
  why the step had to be cut (`finish_step/2`) for this to be possible at all.

The sensors are not lagged: they are asked per step in either mode, because a
sensor's answer is the step's input and not a theory about it.

**Why.** It is the point of the epoch hand-off: a module's pace becomes its own,
and the coordinator waits only for the report it genuinely cannot do without. The
world and the sensors of step _n + 1_ overlap with the modules still working on
step _n_.

**What is therefore not compared.** The trajectory. A lagged step's goals are one
epoch older than the percepts they move on, so a lagged run is a different episode
from Monty's, and no parity is claimed for it — which is why `:barrier` stays the
default and the mode is a run's own choice. Two properties are kept
inside the mode, and both are tested: the lag is exactly one epoch (never "as far
behind as the module happens to be"), so the same episode run twice is the same
trajectory; and the votes of epoch _e_ apply at the boundary of _e + 1_, so a
faster module cannot compute a different answer from a slower one.

**What it bought, measured — two runs from the page.** Two runs of
`tutorial/dist_agent_5lm_2obj_eval`, started one at a time from the experiment
page, episodes = 1, seed 42, six sensors and five learning modules, the MuJoCo
world through `ex_mujoco`, on this machine (Apple Silicon, macOS 26):

| mode    | steps | model time  | wall clock | what the modules concluded    |
| ------- | ----- | ----------- | ---------- | ----------------------------- |
| barrier | 34    | 61 253.9 ms | 1 min 11 s | all five `match`              |
| lagged  | 39    | 9 825.3 ms  | 14.6 s     | three `match`, two `time_out` |

The round is what the lag removes, and on this config it is most of a step: 6.2×
less model time, 4.9× less wall clock. It is also a different episode — the
trajectory parts at step 6 — and on this one it is a worse one: a lagged step's
goals are an epoch older than the percepts they move on, and two of the five
modules ran out of steps without concluding, where the barrier run's five all
recognised the mug. **So "lagged is faster" is true and is not an argument for
using it.** It is a scheduling option whose price is measured on the same page,
and `barrier` is the default for exactly that reason.

An earlier read of this came from `scripts/probe_lagged_steps.exs` — kept, because
it is what found the goal-list crash, but not for numbers: on a machine shared
with two live dev nodes it disagreed with itself between runs of the same episode,
which is how a 3.8× became a 0.8× with nothing changed in between. The two runs
above are the ones a person would make, and they are what the claim rests on.

**What would make the lag worth its price.** The one thing the lag does not remove
is the _dependency_: a module's belief is an epoch behind the world, so a policy
acts on an older picture. Making that cheap rather than costly is a question about
the experiment — an episode that needs fewer steps to conclude, or a forecast that
does not need the newest belief — not about the scheduler. Until there is such an
answer, this is a lever with a measured cost.

## 2.31 A straggler is given time to deliver its prediction

**The port's addition.** Monty ends an episode the moment its match criterion is
satisfied — by default the first module to report `:match` — and every module
still stepping is told it has timed out. Its computation is thrown away with the
step it was in the middle of, which is a loss with no counterpart in a brain:
neurons compute in parallel and waste work constantly, and the work that matters
is the work that arrives before the decision. The port's step coordinator
therefore has a **settle window**, `settle_steps` (default **0**, Monty's rule):

- when the criterion is first satisfied the window opens and the episode keeps
  stepping for that many more steps, or until every module has a terminal state,
  whichever comes first;
- a module that concludes inside the window is counted as having matched, not as
  one that timed out;
- at the close of the window every module still stepping is asked, in one round,
  what it was voting for (`send_out_vote/1`), and that answer is kept beside its
  `:time_out` as `still_believing` — a late prediction is still a prediction,
  and the record says what it was.

**Measured**, `tutorial/dist_agent_5lm_2obj_eval`, episode 1, seed 42,
`scheduling: lagged`, from the page, one lever apart:

| run                                    | settle | wall   | result                                           |
| -------------------------------------- | ------ | ------ | ------------------------------------------------ |
| `9fe411a7-7ba7-47f3-a166-0c890dc66c49` | 0      | 25.7 s | `mug`, three modules `match`, **two `time_out`** |
| `a112ab07-4213-4a44-9d89-9aca1eb17ab2` | 5      | 15.2 s | `mug`, **no module timed out**                   |

The five modules had all been voting `mug` for the whole episode with different
evidence (`lm_3` was at 21.9 when the criterion fired, `lm_4` at 70.7); the two
that ran out of steps were not in disagreement with the three that concluded,
they were slower. A window of five steps was enough for them to deliver.

**Not yet done:** the window is a number a run chooses, and the run page states
the choice only in the form it was started with; the collected `still_believing`
is in the step's status but not yet in the page's verdict line.

## 2.32 An attention system is stepped, and its grid is not in a memento

Monty builds the attention system its config names (`MontyExperiment` pops
`attention_system` out of the monty config and instantiates it, and `MontyBase`
falls back to `NoopAttentionSystem` when a config names none), steps it once a
step's goals and regions are proposed (`_pass_goals`) and resets it per episode
(`MontyBase.reset`). This port does the same: `Setup.model_spec/3` builds the
class the config names, `Monty.Runtime.Step.State` carries the system and steps it
in `step_attention/3`, and `reset_episode_state/1` resets it in the same places
Monty does — which includes _not_ resetting it in
`NoResetEvidenceGraphMatching`'s later resets, since Monty's override does not.

The system is a struct threaded through the step's state rather than an object
mutated in place, which is how every other piece of model state travels here
(`docs/monty-differences.md` §2.1): what a step did to attention is in its return
value, and two runs of one episode cannot share a grid by accident.

Two smaller differences:

- **The grid is not carried in a memento.** Monty's `snapshot()` includes
  `attention_system_dict` — the grid and its telemetry. Nothing in Monty reads it
  (no logger in `fw/loggers/` or `fw/utils/logging_utils.py` mentions attention),
  so this port does not build one.
- **Only `voxel_size` is read from the config.** `DefaultAttentionSystem`'s
  other arguments — `weight_pooler`, `decay`, `merge`, `goal_filter`, `telemetry`
  — are Monty's defaults here and the port's `new/1` states them. No config in
  `conf/` sets any of them; a config that did is refused with
  `:attention_argument_not_read` rather than run with the argument dropped, which
  would be a different experiment wearing the same config's name.

## 2.33 A pickle's NaN is `nil`

The v11 compositional models carry a NaN in the pandas frame that a training run's
attention bookkeeping left in the saved state — Monty's voxel grid is a pandas
`DataFrame` (`attention/voxel_grid.py`), and a weight for a voxel nothing occupied
is NaN there. Python writes NaN as the ordinary value it is; it propagates through
arithmetic and compares unequal to everything, itself included.

BEAM has neither NaN nor infinity: `<<value::float-64>>` does not match those bit
patterns, so a pickle carrying one stops the reader at that byte.
`Monty.Studio.Pretrained.Pickle` therefore walks the pickle opcode by opcode
before the dependency reads it and writes every non-finite `BINFLOAT` — and a text
`FLOAT` of `nan` or `inf` — as `NONE`, that is `nil`, which is this port's NaN, as
it is everywhere else a value is absent (`docs/validation.md`).

The walk is by opcode, not by byte search, because a NaN's byte pattern also
occurs inside tensor storages, which are the numbers the read exists for: a
search-and-replace would corrupt them. An opcode the walk's table does not know
is an error, never a guess, and a pickle with no non-finite number in it comes
back byte for byte — which is every model this port read before v11.

An export reads the object models' graph memory, not that bookkeeping, so the
translated value is read past and no record carries it (a record holding `nil`
where a number belongs would be a broken feature, and none does). Where a NaN
would reach a step, `nil` is what it becomes: the port's answer for a value that
is absent.

## 2.34 A sensor is refused when its own layers are missing

`sensor_module_spec/2` in `Monty.Studio.Setup` used to fall back to the stand-in
sensor when no ported class could build a config's entry. That is not what Monty
does — `MontyExperiment` instantiates whatever the config names, and a config
whose salience strategy or segmentation class does not exist is an import
error — and it was not harmless: the cows family's view finder names `Vocus2` as
its `salience_strategy` and `SlicMerge` as its `segmentation_strategy`, so the
run stepped a plain camera instead, proposed no goals, and concluded nothing
while looking healthy. `Setup` now records a `:sensor_module_not_buildable`
finding and the config is refused.

Two consequences worth knowing:

- **A sensor's layers are part of the experiment.** `CameraSM`,
  `TwoDSensorModule`, `ExperimentSensorModule` and `SalienceSM` each refuse the
  layer classes this port has not written (`{:unsupported_layer, key, target}`)
  rather than taking a default, and `TwoDSensorModule` now checks its `_target_`
  like the others do, so it no longer claims a config that is not its own.
- **A postponed config can carry the code too.** Monty's own test doubles are
  sensors this port cannot build; a config of doubles is still shelved as
  `:not_planned` (`:test_fixture_class`), and its codes now name both facts.

`Snapshot` — `tbp/monty/experiment/sensor_modules/telemetry.py::Snapshot`, the one
transform `surf_agent_unsupervised_10distinctobj`'s view finder names — is ported
as `Monty.Experiment.SensorModules.Telemetry.Snapshot`, so that config builds and
runs. It appends the observation to `telemetry["raw_observations"]` and the
sensor's pose to `telemetry["sm_properties"]`, clearing both on the step after a
reset, exactly as Monty's `_reset` flag does. The pose is written with Monty's
keys and this port's quaternion order (`wxyz`, §2.4) as a list, where Monty
stores numpy-quaternion's `[x, y, z, w]` array; nothing reads it back into a
computation.

The cows family stays refused until `SlicMerge`
(`frameworks/models/salience/segmentation/slic_merge.py`, `skimage`'s SLIC plus
a BFS merge) is written. Its view finder's salience strategy is read now:
`SalienceSM` builds the shape Monty's configs write — the `Vocus2` class with its
colour, depth and orientation channels as objects of their own, which is Hydra
instantiating `Vocus2.__init__` one parameter at a time — as well as the older
`Vocus2.from_config` with a nested `Vocus2SalienceConfig` that the two
`camera_dist_*_vocus2` sensor configs still name. The three arguments no config
states (`color_space_converter`, `combine`, `normalize`) are refused rather than
dropped, because a different combination or rescale is a different salience map
under the same config's name.

## 2.35 A run that is stopped says so

A process that passes its heap ceiling (`run_max_heap_mb`, applied as `+hmax`) is
killed by the emulator: there is no exception, so the dying process cannot report
itself, and the log simply stops. `mix monty.run` stepped an experiment in the
reporting process, so a run killed that way ended with no conclusion, no summary
and a log whose last line was a step — which is what
`surf_agent_unsupervised_10distinctobj` did at its 1201st step, once the view
finder's `Snapshot` transform (§2.34) made it runnable.

What actually died was the process holding the model: a step is a call into it,
a killed process takes that call's exit with it, and the exit was uncaught — which
is why the VM went down saying nothing. `mix monty.run` catches it now
(`Monty.Studio.RunLimits.watch_step/1`) and ends with a sentence and a non-zero
status:

```
** (Mix) the run stopped at a step: the step worker it was waiting for stopped
mid-call ({:via, Registry, {Monty.Runtime.Registry, {:step, "studio-8"}}}), and
what stopped it is the line logged above
```

An ordinary crash is not caught: it has a stacktrace, and the task prints it.

A worker killed mid-step takes the caller's `GenServer.call` with it, and the
request that call carried is a step's whole observation — printing it would bury
the sentence, so that shape is named rather than dumped.

**Why it ran out of heap, measured** (this checkout, this machine, the config's
own two 64×64 sensors): both sensors keep every observation of the episode — the
patch through `save_raw_obs: true` (`SnapshotTelemetry`), the view finder through
`Snapshot`. That is Monty's behaviour and costs it almost nothing, because one
observation is two numpy arrays. Here one observation is **515 kB** as nested
lists, 450 kB of it the two images (`:erts_debug.size/1`, rounded down), so 1200
steps of two sensors is 1.2 GB before the model and its graphs are counted
anywhere — the worker's heap had reached 237 Mwords young and 522 Mwords in its
block when the ceiling stopped it. Nothing reads those pixels back, so this is the
port's representation and not its model. The choices, none of them taken yet, now
with their numbers:

1. **Keep the pixels as Monty does and raise the ceiling** — faithful, and it does
   not fit: an episode is 4000 steps, so twelve gigabytes.
2. **Keep the poses and not the frames** — nothing at all. The run's own picture
   writer has already put each step's frame in the run's video files, so the
   sensor's copy is a second copy of a recording that already exists.
3. **Keep the frames as flat binaries** — the same numbers, `<<x::float-64>>`
   after `<<x::float-64>>`, are **160 kB** an observation: 384 MB for a 1200-step
   episode and 1.3 GB for a 4000-step one, which fits. A reader that wants pixels
   decodes one binary; no reader exists today.

## 2.36 `SlicMerge` is skimage's SLIC, computed here

The cows family's view finder names `SlicMerge` as its segmentation, and a
salience module with no segmentation proposes goals and no region — which is why
those fourteen experiments were refused rather than run with a stand-in sensor
(§2.34). `Monty.Frameworks.Models.Salience.Segmentation.SlicMerge` is the port,
and it is the whole class: SLIC superpixels, each superpixel's mean colour in
Lab, the graph of shared edges, the walk outward from the point of fixation, and
the mask the walk answers.

**SLIC itself.** `skimage.segmentation.slic` is Cython, so there is nothing to
call: the port computes the same arithmetic in the same order — `regular_grid`'s
seeds (a 256×256 view with 70 requested seeds gets a step of 16 and 256 seeds),
the window of twice the step around each seed, colour distance plus `1/step²`
times squared pixel distance, the strict `>` that hands a pixel over, ten
iterations or until nothing changes, and `_enforce_label_connectivity`'s
breadth-first pass that absorbs a blob smaller than half a nominal segment. It is
checked against `skimage` 0.26 itself: a 16×16 view's label field is a test
fixture (`test/…/slic_merge_test.exs`), and a real 64×64 MuJoCo view was
compared label for label, with no pixel differing.

**The order is what makes it exact, so the order stays.** A rewrite of the
k-means loop — pixel-major instead of seed-major, tuples instead of `:array`,
a bisection instead of filtering every window — was 27% faster (1.6 s against
2.1 s on the 256×256 view) and left one pixel of the 64×64 view's label field
differing, from the sixth of the ten iterations on. One pixel is not a rounding
detail: `base_infer_cows_small_compositional` reached `learning_module_2:
match` at step 35 with 923 062 goals proposed on the exact loop, and had no
conclusion at step 60 with 1 567 990 on the fast one. The rewrite was reverted;
speed is a NIF's job, where the arithmetic is the same arithmetic and only the
interpreter changes.

**Two colours, because Monty has two.** The merge compares mean colours in the
Lab that `cv2.cvtColor` answers divided by 255, so `merge_threshold` of 0.04 is a
distance in `[0, 1]` — `Images.rgb_to_lab/1` does that. SLIC's k-means runs in
`skimage`'s Lab, `L` in `0..100` with `a` and `b` unshifted, which is the scale
`compactness` of 10 is calibrated against; the port's conversion is re-scaled to
it. Each is done where Monty does it.

**Two things that cannot be written the same way.**

- **The Lab values differ in the last decimals.** Monty's two paths are OpenCV's
  8-bit lookup tables (§1.12) and `skimage`'s own floats; the port uses one
  floating-point chain for both. Same colour space, and the largest disagreement
  is a percent of the range in the darkest, most saturated corner of it. A
  segmentation decision that falls inside that difference could differ from
  Monty's; none did on the views compared.
- **A segment that wins no pixel is dead, not NaN.** `skimage` divides its
  centroid by zero and carries a NaN, which can never claim a pixel again. NaN is
  `nil` here (`docs/validation.md`) and `nil` poisons every comparison that
  follows, so the centroid is marked dead and skipped — the same label field
  without the NaN.

**What it costs, measured** on this machine: a 64×64 view takes about 150 ms,
and the cows family's 256×256 view takes 2.1 s — against 5 ms for `skimage`'s
Cython on the same view. That, plus `Vocus2`'s salience map at 2.6 s for the
same view, is about 5 s a step on `base_infer_cows_small_compositional`, where
the run itself was 35 steps for one episode and concluded (`learning_module_2:
match`, goals proposed at last). A run of the whole experiment is therefore
hours of arithmetic rather than minutes: the numbers are Monty's, the speed is
not yet, and moving SLIC into a NIF is the obvious next step if the cows runs
are wanted at Monty's rate.

## 2.37 A captured scene's PNG is decoded here, byte for byte

The image world (`SaccadeOnImageEnvironment`, the family of
`*_world_image_on_scanned_model` configs) is still unwritten — the module map
says `:planned` and readiness says `not_planned`, because it needs a world kind
this build does not carry. Its first dependency is written, because it is the one
that could be wrong silently: Monty opens a capture with
`PIL.Image.open(rgb_path)` and takes `np.array` of it as the observation's
`rgba`, so a decoder that is nearly right would feed every sensor a picture
Monty never saw.

`ExTbpMonty.Core.Png.decode/1` is the other half of the module that already
writes the run's frames: signature, chunks, `IHDR`, one inflate, and the five
scanline filters undone — `None`, `Sub`, `Up`, `Average`, `Paeth`. A photograph's
encoder chooses a filter per row, so all five are needed; the writer here only
ever emits `None`, which is why reading a capture is not a round trip.

Checked against PIL itself on a real capture — Monty's own
`tests/unit/resources/dataloader_test_images/0_numenta_mug/rgb_0.png`, 640 × 480
RGBA from an iPad — with **all 1 228 800 bytes identical**: `PIL.Image.open` and
`np.array` on this machine (PIL 12.3.0) and this decoder answer the same
SHA-256, `0344E07E…1CCE60`. The committed test carries two fixtures an encoder
chose the filters for (PIL's own choice of `Sub`/`Paeth`/`Up`, and a body forced
to `Average`), so the filters are covered without a photograph in the tree.

What it refuses, it refuses by name: a 16-bit file, a palette PNG, an
interlaced one, a body whose length is not `height × (stride + 1)`, or a stream
that is not deflate. A capture is 8-bit, one image, greyscale or colour with or
without alpha, and anything else is a different picture rather than a smaller
one.

## 2.38 The image world is written; the interface and the world kind are not

Monty's `SaccadeOnImageEnvironment` is a world with no simulator in it: a scene
is a directory holding `rgb_<version>.png` and `depth_<version>.data`, both
captured by an iPad, and an action moves a `patch_size` window over them —
`look_up`/`look_down` along the rows, `turn_left`/`turn_right` along the columns.
`Monty.Frameworks.Environments.TwoDData.SaccadeOnImageEnvironment` is the class,
implementing `Monty.Simulators.Environment`, and its sensor position is not a
pixel index: the whole depth image is unprojected once per scene by Monty's own
`DepthTo3DLocations` — every point, the iPad's 54.201° field of view, anything
past `depth_clip_value` treated as background — and the middle of the patch
answers the point under it, because a model compares positions and a pixel is not
a distance.

Checked against Monty's own capture (`tests/unit/resources/dataloader_test_images/0_numenta_mug`,
640 × 480 RGBA): the colour reads byte-identically to `PIL.Image.open` (§2.37),
the point cloud's middle pixel is `[0.00016, 0.00016, 0.2009, 1.0]` — three
coordinates and "on surface" — and Monty's six integration cases run as written:
the camera's defaults are the iPad's, `look_up` and `turn_right` move the sensor
(0.0036 m and 0.0032 m on that capture), and `move_forward` moves it not at all,
because the four saccades are the only actions this world has.

**Two places the arithmetic is Monty's, not a choice.** A capture's depth can say
"no return" as a NaN, and the BEAM has no NaN to carry (§2.33): a 32-bit word
whose exponent is all ones is therefore read as the world's missing return the
moment the file is read, which is the only place it can be seen — a float
segment cannot even match one. And anything past 40 cm is dropped in
`process_depth_data`, the number Monty hard-codes with a comment saying nobody has
tuned it.

**The interface is written too.** `Monty.Experiment.Environment.SaccadeOnImageInterface`
is Monty's cycle and its name: a config's `scenes` and `versions` say one capture
per episode, the counter wraps at the end, and the episode's target is the scene
directory without the index Monty sorts by (`0_numenta_mug` is `numenta_mug`) at a
fixed pose in the origin. An index the config does not have is refused in Monty's
own words. Two things are this port's rather than Monty's: the world is threaded
through and answered back — an interface here is a value — and the target is the
map the port's other interface uses, not a dataclass.

**The family runs.** `:image` is a world kind beside `:mujoco`, `:ex_mujoco`,
`:synthetic` and `:cad`: it opens the directory a config's `env_init_args.data_path`
names and switches captures by the interface's `scenes`/`versions` (episode 4 of
`world_image_on_scanned_model` is scene 1, version 0), and a machine with no
captures is told which directory is empty rather than stepping an empty scene.
`mix monty.run world_image_on_scanned_model --world image --episodes 1 --steps 25`
steps a real capture at 80–150 ms a step, the model narrowing to `numenta_mug`
with 2 182 hypotheses by the last step; readiness counts the six scanned-model
configs as runnable, 143 of Monty's 157 where it counted 137.

**And a long episode meets the ceiling, as §2.35 said it would.** The same run at
400 steps was stopped at step 66 by the step worker's heap limit: every step
keeps the whole 480 × 640 view finder as nested lists, which is four times the
cost of a MuJoCo sensor's 64 × 64 image. What stopped it was reported, not
silent ("the run stopped at a step: …"). A whole episode is Monty's 387 steps
average, so this family waits on the observation-representation decision in
§2.35 — frames as binaries, or poses without frames — the same decision the surf
config is waiting on.

**What is still missing.** `SaccadeOnImageFromStreamEnvironment`, which reads a
stream of captures from a server this build does not carry, so
`world_image_from_stream_on_scanned_model` stays `not_planned`.

## 2.39 A drawing is a depth the world makes, not one it measures

Monty's Omniglot tutorial is the other 2-D world in the same file
(`frameworks/environments/two_d_data.py::OmniglotEnvironment`), and it is ported
too: `Monty.Frameworks.Environments.TwoDData.OmniglotEnvironment`, with the three
module-level functions the file also holds — `load_img`, `load_motor`,
`space_motor_to_img` — in `Monty.Frameworks.Environments.TwoDData`, and the
interface in `Monty.Experiment.Environment.OmniglotInterface`.

**A character is a path, not a scene.** The dataset records where the pen went —
`strokes_background/…/0709_01.txt`, one `x,y,time` point a line, `START` and
`BREAK` around a stroke — and Monty's world steps _along that path_ instead of
steering a sensor: an action only says how far (`rotation_degrees`, at least one
point), and the sensor reads the path's point at that count, wrapping at the end.
An episode is therefore the character drawn again, a patch at a time.

**The depth is made.** There is no lens in this world: `depth = 1.2 -
gaussian_filter(~patch, sigma=0.5)`, so the ink sits at 0.2 m, the paper at
1.2 m, and the step at the edge of a stroke is smoothed rather than a cliff. The
Gaussian is scipy's, with its defaults: a separable kernel of radius
`int(4σ + 0.5)`, normalised to one, reflected at the patch's edges.
`GetGoodView` smooths with zeros instead (`§1.15`) because Monty's two calls
differ, and this port keeps them apart rather than picking one rule for both.

**A drawing is one bit a pixel.** The dataset's PNGs are 1-bit greyscale, which
the decoder now reads (`§2.37`'s `ExTbpMonty.Core.Png`), writing each pixel out
as eight bits — 0 or 255 — so a caller has one shape to handle whatever the file
holds.

**Measured against Monty.** On the first character of his dataset, his class and
this one agree on all 190 pen positions a 10-pixel patch fits at, on the semantic
map, and on the depth to within one unit in the last place (the separable
Gaussian is summed in the other order). The world's numbers in `mix monty.run`:
`tutorial/omniglot_training --world omniglot` walks its six characters in 6 000
steps, the memory ending with six objects and 904 nodes, in 2.9 s.

**The two configs.** `:omniglot` is a world kind of its own, because a drawing is
neither MuJoCo nor a capture: the environment reads the dataset
(`env_init_args.data_path`, else `data/omniglot/python`), the config's
`alphabets`/`characters`/`versions` name the character of each episode, and the
episodes of the phase are counted from `characters` — an empty list would divide
an epoch by nothing, which is what the image family hit before `§2.38`. The
dataset itself is two entries in the prerequisite manifest (the `python/` folder's
own two zips), so a machine without it is offered the download rather than the
words "put it somewhere". `tutorial/omniglot_training` is runnable with the
dataset; `tutorial/omniglot_inference` runs once that training run has written its
memory.

**What does not match yet: the tutorial's answer.** Monty's own two tutorials were
run here as the oracle (his `run.py`, his venv, his data). Training agrees
exactly in size — his checkpoint holds 904 nodes over the same six objects, and
so does the library this port exports. Inference does not: his run recognises
six of six (`4, 4, 4, 4, 10, 4` steps, evidence at most 14.5), and this port
recognises four — on `Anglo-Saxon_Futhorc_2` and `_3` its evidence falls from
2.35 to −0.27 over four steps until no match is possible. The configs are the
same file for file (his composed snapshot and this port's are byte-identical,
`min_eval_steps: 3` included), so the difference is inside the step the model
takes, not in what the config asks for. Reproduce:

    MONTY_DATA=~/tbp/data mix monty.run tutorial/omniglot_training --world omniglot
    MONTY_DATA=~/tbp/data mix monty.run tutorial/omniglot_inference --world omniglot

    # Monty's side, for the oracle:
    cd ~/src/monty-orig && MONTY_DATA=~/tbp/data .venv/bin/python run.py \
      experiment=tutorial/omniglot_training
    ... experiment=tutorial/omniglot_inference   # then eval_stats.csv

**What the harness already settles.** Both runs write the same
`detailed_run_stats.json` (his handler is ported, and a studio run's logging plan
builds it from the config). Comparing episode 5 step by step:

- the features are identical to the last digit — `pose_vectors`,
  `principal_curvatures_log`, `on_object` at steps 0 and 1 are the same
  numbers, so the observation path and the transform are at parity;
- the sensed locations are identical for all five steps this port took,
  `[32.551, 0.022, 21.887] → [32.551, 0.022, 32.887] → …`;
- the trained graphs are the same geometry: his first nodes are
  `[18.3207, 0.0223, 36.4687]` and this library's are
  `[18.32067, 0.02225, 36.46874]`, float32 against float64.

So the difference is inside the evidence update, not in what it is given: on the
same features and the same graph his evidence rises by exactly 1.5 a step (1.0,
2.5, 4.0 … 14.5) with `Anglo-Saxon_Futhorc_2` leading throughout, and this port's
goes 1.0 → 2.351 → 1.529 (and the leader changes) → 0.727 → −0.273. Three
instruments, in order: a unit case for `EvidenceGraphLM`'s evidence update for one
matching object and one hypothesis; `evidence_omniglot_tutorial`'s knobs against
his (`evidence_update_threshold`, tolerances); and the per-step `evidences` map
both files carry, which is what this comparison read.
