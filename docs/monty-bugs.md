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

**What has actually been compared with Monty, and how closely it agreed, is in
[`validation.md`](validation.md)** — this file records the differences the port
keeps on purpose or suspects in Monty, that one records the agreements.

## At a glance

| § | What | Status | What this port does |
|---|------|--------|---------------------|
| [1.1](#11-the-sanity-check-in-_compute_graph_mismatch-cannot-fail) | A sanity check that compares a value with itself | Confirmed | Ports the transform, drops the check |
| [1.2](#12-npall-over-euler-angles-a-single-axis-rotation-is-never-a-pose-change) | `np.all` over the three Euler angles | Confirmed, `np.any` is what the comments describe | Reproduced on purpose, pinned by a test |
| [1.3](#13-npall-on-the-top-two-ids-stricter-than-its-own-comment) | Same, over the top-two ids | Confirmed, and Monty's TODO names the fix | Reproduced on purpose, pinned by a test |
| [1.4](#14-argsort-2-on-a-single-hypothesis) | `argsort(...)[-2]` on one hypothesis | Latent | Answers `{best, nil}` instead |
| [1.5](#15-first_sensor-is-only-bound-inside-the-loop) | A name bound after its first read | Latent | Answers a value, not an unbound name |
| [1.6](#16-jumptogo-saves-one-name-and-restores-another) | A checkpoint saves one attribute and restores a different one | Confirmed, only bites a resumed run | No checkpoint loading here |
| [1.7](#17-a-depth-of-zero-is-read-as-an-object-a-metre-away) | A depth of 0 (nothing there) read as "object within a metre" | Suspected, masked by the configured transform | Ports the transform that masks it, and applies it before any module reads |
| [1.8](#18-the-pixel-grid-is-not-a-cameras-pixel-grid) | Unprojection samples the image's edges, not its pixel centres | Suspected, sub-millimetre at Monty's scale | Reproduced, and the stand-in world renders the same grid |
| [1.9](#19-the-mean-is-divided-by-the-count-twice-in-the-plane-fit) | A mean divided by the count twice inflates the plane fit's scatter matrix | Suspected, nil for a centred neighbourhood | Reproduced on purpose, recorded at the code site |
| [1.10](#110-the-pose-not-defined-flag-is-written-where-nothing-reads-it) | A "pose not defined" flag written to the wrong features dict | Suspected, needs a percept to be visible | Reproduced on purpose, pinned by a test |
| [1.11](#111-the-rgb-blur-comment-names-the-wrong-kernel-size) | A comment says OpenCV picks `6*sigma + 1`; measured, it picks `8*sigma + 1` | Confirmed by measurement | Follows the code (OpenCV), not the comment |
| [1.12](#112-lab-goes-through-opencvs-8-bit-tables) | `cvtColor` on a `uint8` image answers 8-bit Lab, so it quantises | Confirmed by measurement over every 8-bit colour | Floats; agrees to 2.67 of 255 |
| [1.13](#113-cv2s-area-resize-does-something-else-when-only-one-axis-enlarges) | `INTER_AREA` with one axis enlarging is neither area nor linear | Confirmed by measurement; unreachable from Monty's pyramids | Answers the area average |
| [1.14](#114-a-pixel-with-no-depth-becomes-the-nearest-patch-in-the-view) | A depth of zero, mapped to log-depth zero, is *above* every real depth | Suspected; masked by the depth transforms real configs use | Reproduced on purpose, pinned by a test |
| [2.1](#21-random-streams-the-one-that-changes-your-numbers) | One mutable RNG vs a stream per module | Decision | Per-module streams |
| [2.2](#22-motor_only_step-travels-in-the-result) | A policy sets a flag on the motor system | Decision | The flag travels in the result |
| [2.3](#23-the-motor-system-answers-with-itself) | The motor system mutates itself | Decision | It answers with its next version |
| [2.4](#24-get_output1-answers-message-lm) | `get_output` answers a bare `Message` | Decision | `{message, module}`, like every step |
| [2.5](#25-a-sampler-answers-the-stream-it-leaves-behind) | A sampler needs the stream it just used | Decision | Samplers answer `{action, rng}` |
| [2.6](#26-get_top_two_pose_hypotheses_for_graph_id2-answers-best-nil) | The top-two lookup raises | Decision | Answers `{best, nil}` |
| [2.7](#27-depth_at_center-lives-in-the-policy-namespace) | A 530-line module for one centre pixel | Decision | The read lives in the policy namespace |
| [2.8](#28-small-vocabulary-differences) | Python's strings, objects, units | Decision | Atoms, tuples, Monty's units |
| [2.9](#29-inheritance-becomes-public-functions-and-a-module-dispatched-hook) | Subclassing | Decision | Public function + module-dispatched hook |
| [2.10](#210-missing-coverage-counts-as-zero) | `features["object_coverage"]` raises when it was not asked for | Decision | A missing coverage is zero |
| [2.11](#211-a-sensor-with-no-surface-answers-nil) | A sensor's step always answers a percept | Decision | No surface to see is `nil`, not a made-up location |
| [2.12](#212-the-sensors-pose-is-composed-once) | Two classes compose a sensor's world pose | Decision | One function, two callers |
| [2.13](#213-two-protocols-and-a-mutable-transform-become-one-behaviour-and-a-threaded-value) | Protocols for `isinstance`, and transforms that mutate themselves | Decision | The port's one sensor behaviour; a transform answers itself |

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

## 1.8 The pixel grid is not a camera's pixel grid

**What's wrong.** A depth image is unprojected with a grid that runs from −1 to
+1 over the *pixels*, not over the pixel *centres*:

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

**What's wrong.** A sensor module computes whether the curvature directions are
meaningful — two principal curvatures that differ by less than
`pc1_is_pc2_threshold` leave the directions arbitrary — and reports that as the
morphological feature `pose_fully_defined`. When it could *not* do the fit at all
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
-0.69 here, so an empty pixel arrives 0.69 *nearer than everything else in the
view*, and the centre/surround difference that follows is a strong positive
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

---

# 2. Where this port deliberately differs

Decisions, not suspected defects. Each is a place where two runs can differ
without either being wrong.

## 1.15 Monty's two Gaussians are not the same Gaussian

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

**A plateau is not a specification.** On a *symmetric* object the smoothed mask
has a flat maximum, and which pixel NumPy's `argmax` returns is then a fact about
summation order, not about Monty: two faithful implementations can disagree by a
pixel. The fixture therefore uses a notched object, whose brightest pixel is
clear of the runner-up by `0.02` of the mask's height.

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

## 2.7 `depth_at_center` is a function, and the policies delegate to it

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

## 2.10 Missing coverage counts as zero

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
  reason); a sensor module *is* something with `update_state/2`, `step/4` and
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

**What Monty does.** A policy is `__call__(self, model: MontyBase, count)`: it is
handed the model object and reads whatever it likes off it — `model.is_done`,
`model.is_exploring`, `model.matching_steps`, and
`lm.recognition_status.conclusion` for each learning module. It also logs and
telemeters every terminal decision through `logger.info` and `telemeter.info`.

**What this port does.**
[`Monty.Experiment.RecognitionPolicy`](../lib/monty/experiment/recognition_policy.ex)
declares a model *view* — a map with exactly those four readings, the modules'
conclusions flattened to a list — and each policy is a `{module, state}` pair
dispatched by `RecognitionPolicy.call/3`. Constructors answer `{:ok, policy}` or
`{:error, message}`, carrying Monty's `ValueError` sentences.

**Why.** The decision is what has to be compared with Monty's, and a decision
that can reach into live processes is a decision that cannot be recorded and
replayed. `scripts/record_monty_recognition_policy.py` asks Monty's real classes
448 questions over the same view; the port answers every one of them the same
way.

**What is therefore not compared.** The log lines and telemetry events Monty
emits when a policy fires. They are the experiment's reporting, not its
arithmetic; when the episode loop is wired to these policies, what it reports is
its own concern.

**And the mode.** `ExperimentMode` is an enum of the strings `"eval"` and
`"train"` in Monty; here it is `:eval` and `:train`
([`ExperimentMode`](../lib/monty/frameworks/experiments/mode/experiment_mode.ex))
with `to_string/1` and `from_string/1` for the places a config or a log needs the
string.



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
