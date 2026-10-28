# Suspected bugs in Monty, and where this port differs

Two things can make an Elixir run disagree with a Python one: a defect upstream,
and a decision here. This file records both in one place, because anyone
comparing two sets of numbers needs them together.

Every entry says where the code is, what looks wrong, and what this port does
about it. Where Monty's own comments already acknowledge the problem, that is
said too — an acknowledged quirk is a different thing from a defect nobody has
noticed.

Line numbers are for the `monty-orig` checkout this port is written against
(`tbp.monty`, revised 2026-10). They will drift; the function names will not.

## How to read an entry

- **Confirmed** — the behaviour follows from the code alone, with no run needed.
- **Latent** — a real defect, but something else currently stops it being
  reached.
- **Reproduced** — this port deliberately keeps the behaviour, so the numbers
  stay comparable. Pinned by a test.

---

# 1. Suspected bugs in Monty

## 1.1 The sanity check in `_compute_graph_mismatch` cannot fail — Confirmed

`frameworks/models/goal_generation.py:672-682`:

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

The two operands of the subtraction are the same expression, so the difference
is exactly zero, and the transformed value is exactly `second_mlh["location"]`.
The assertion therefore compares a value with itself.

**Why it matters.** This is the only check that the corrective transform — the
one that puts the most likely object's graph into the second object's learned
frame before the two are compared — is the inverse of the transform that built
the graph in the first place. If that ever stopped holding, the two graphs would
be compared in different frames and the chosen "most disagreeing" point would be
arbitrary, with nothing said.

**What this port does.** The transform itself is ported unchanged
(`EvidenceGoalGenerator.into_frame/3`); the assertion is not recomputed, and the
reason is in a comment there. Nothing about the numbers changes.

## 1.2 `np.all` where `np.any` is meant: a single-axis rotation is never a pose change — Confirmed, reproduced

`frameworks/models/goal_generation.py:966-971`, in
`_check_conditions_for_hypothesis_test`:

```python
if self.prev_top_mlhs is not None and np.all(
    top_mlh["rotation"].as_euler("xyz")
    != self.prev_top_mlhs[0]["rotation"].as_euler("xyz")
):
    logger.debug("Hypothesis jump indicated: change in most-likely rotation of MLH")
    return True
```

`np.all` over three elementwise comparisons is true only when *all three* Euler
angles differ. A rotation about a single axis changes exactly one angle, so it
is never seen as a change of pose — including the case the comment above it
names ("we didn't find the mug handle following a previous jump, and have
therefore eliminated a pose").

**Why it matters.** It changes *when* the agent spends a hypothesis-testing
jump: some pose changes that should prompt a jump do not. The number of jumps,
and therefore the path, differs from what the documented intent describes.

**Monty's own notes.** The TODOs above this block ask for an angle *threshold*
"rather than it needing to be identical", which suggests the authors meant "any
difference counts". They do not mention `np.all`.

**What this port does.** Reproduced exactly, and pinned by the test
"does not treat a turn about one axis as a new pose" in
`test/monty/frameworks/models/goal_generation/evidence_goal_generator_test.exs`.
Correcting it here would make our runs diverge from Monty's, which is the one
thing a comparison cannot afford.

## 1.3 `np.all` on the top-two ids: stricter than its own comment — Confirmed, reproduced, acknowledged upstream

`frameworks/models/goal_generation.py:944-954`:

```python
# If the identities or *order* (i.e. which one is most likely)
# of the top two MLH changes, perform a new jump test, as this
# is a reasonable heuristic for us having a new interesting
# place to test
# TODO when optimizing, consider using np.any rather than np.all, i.e. as long
# as there is any change in the top two MLH
if self.prev_top_mlhs is not None and np.all([...] != [top_id, second_id]):
```

The comment describes "a change or shuffle", and the log line below repeats
"change or shuffle in top-two MLH IDs". The code fires only when *both* ids have
changed. A new runner-up, with the leader unchanged, is not a change as far as
this condition is concerned.

**Monty's own notes.** The TODO immediately above acknowledges it and names the
fix (`np.any`). So this is a known, deliberate-if-reluctant state rather than an
oversight.

**What this port does.** Reproduced, pinned by "does not jump when only one of
the top two changes".

## 1.4 `argsort(...)[-2]` on a single hypothesis — Latent

`frameworks/models/evidence_matching/learning_module.py:758-763`:

```python
def get_top_two_pose_hypotheses_for_graph_id(self, graph_id):
    """Return top two hypotheses for a given graph_id."""
    mlh_for_graph = self._calculate_most_likely_hypothesis(graph_id)
    second_mlh_id = np.argsort(self._hypotheses[graph_id].evidence)[-2]
    ...
```

With one hypothesis the array is length one, and `[-2]` raises `IndexError:
index -2 is out of bounds`.

**Why it is latent.** Its only caller is
`EvidenceGoalGenerator._compute_graph_mismatch`, and that is reached with
`focus_on_pose` set only after a check that the object has more than one
hypothesis (`goal_generation.py`, the two `if len(self.parent_lm._hypotheses[
top_id].evidence) == 1: return False` guards). Nothing updates the hypothesis
space between the guard and the call, so the crash is not reachable today. It
becomes reachable as soon as those two pieces of code are separated — for
example by computing goals in a later step than the gating decision.

**What this port does.** `EvidenceGraphLM.get_top_two_pose_hypotheses_for_graph_id/2`
answers `{best, nil}` for a single hypothesis instead of raising, and says so in
its doc: "Monty's `argsort(...)[-2]` would fail on it". This is a divergence —
but one that turns an exception into a value the caller must handle, so it is
listed again in §2.6.

## 1.5 `first_sensor` is only bound inside the loop — Latent

`frameworks/models/motor_policies.py:905-907` (the same pattern again at
633-635, in `JumpToGoal`):

```python
for ii, current_sensor in enumerate(self._pre_jump_state.sensors):
    if ii == 0:
        first_sensor = current_sensor
    assert np.all(
        self._pre_jump_state.sensors[current_sensor].rotation
        == self._pre_jump_state.sensors[first_sensor].rotation
    ), "Sensors are not identical in pose"
```

If an agent reports no sensors, the loop body never runs, `first_sensor` is
unbound, and the failure is an `UnboundLocalError` several lines later (in the
undo-action construction) rather than the message the code intends. An agent
with no sensors is itself nonsense, so this is a diagnostics defect, not a
behavioural one.

**What this port does.** `InformedPolicy` asks for the sensors' shared rotation
with an explicit empty case (`shared_sensor_rotation/1` answers the identity
when there are none), so the failure mode is a value rather than an unbound
name.

## Checked and found consistent

Worth recording so the next reader does not repeat the audit. The first two are
claims made in Monty's documentation; the rest are claims the code makes about
itself.

- `docs/how-monty-works/motor-system.md`: a selector chooses among policies, the
  selector is what goals reach, and policies are the only things that produce
  actions. That is the shape of `MotorPolicySelectors` and `MotorSystem` here,
  and of the documented two selectors (`SinglePolicySelector`,
  `DistantPolicySelector`).
- `docs/how-monty-works/motor-system/policy.md`: "if the sensor patch moves off
  the object, the previous action is reversed to make sure we stay on the
  object" — that is exactly `InformedPolicy.__call__`, and its momentum
  parameter `alpha` belongs to `InformedPolicyRandomWalk` (still planned, and
  the default of `DistantPolicySelector`).
- `get_output()` returns a `Message`, so `parent_lm.get_output().confidence` in
  the evidence goal generator is correct *(see §2.4 for this port's divergence)*.
- `threshold_possible_matches`, `x_percent_threshold` and the
  `x_percent_scale_factor` application agree with their own comments.
- `MotorSystem` stores each step's actions with the motor-system state they were
  chosen in, resets that record per episode, and keeps the selector's own record
  for `state_dict` — as its comments say.

---

# 2. Where this port deliberately differs

These are decisions, not defects. Each one is a place where two runs can differ
without either being wrong — read them before diffing a Python run against an
Elixir one.

## 2.1 Random streams: the one most likely to change your numbers

Monty threads a single mutable `RandomState` (`ctx.rng`) through every module in
step order, so the numbers a module draws depend on how many draws every module
before it made. This port derives a stream per module from the episode seed, the
module id and the step (`Monty.Context.rng_for/2`), so modules cannot influence
each other's draws and a step can be replayed alone.

**Consequence.** With the same seed, an Elixir run and a Python run draw
*different* random actions. Every policy that samples — `BasePolicy`,
`InformedPolicy`, and `SurfacePolicy`'s `sample_move_forward` — will therefore
walk a different path, and object recognition rates and step counts will differ
even when the arithmetic is identical.

**What to compare instead.** The deterministic parts: matching evidence given the
same percept sequence (that is what the pretrained replay does, to `5.5e-7`),
hypothesis counts, and aggregate statistics over many episodes. A per-step,
per-seed comparison needs a Monty-compatible single-stream mode, which is not
built.

Code site: `lib/monty/context.ex` (`rng_for/2`), whose moduledoc says the same.

## 2.2 `motor_only_step` travels in the result

Monty hands the motor system to the selector (`fixme_provide_motor_system`) so a
policy can set `motor_only_step` on it. Here the policy says it in the
`MotorPolicyResult` and the motor system carries it. Same effect on the step; no
shared mutable object.

Code sites: `lib/monty/frameworks/models/motor_policies/motor_policy_result.ex`,
`lib/monty/frameworks/models/motor_system.ex`.

## 2.3 The motor system answers with itself

`MotorSystem.call/6` answers `{actions, motor_system}` rather than only the
actions, because the record of what was decided has to live somewhere and a
struct cannot be changed in place. The same holds for the selectors and policies.

Code sites: `lib/monty/frameworks/models/motor_system.ex`,
`lib/monty/frameworks/models/motor_policy_selectors.ex`.

## 2.4 `get_output/1` answers `{message, lm}`

Monty's returns the `Message` alone. Ours answers it with the module, like every
other step in this port. A caller that wants the confidence reads
`elem(result, 0).confidence`.

Code site: `lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex`,
`get_output/1`.

## 2.5 A sampler answers the stream it leaves behind

Monty writes `self.action_sampler.sample(self.agent_id, ctx.rng)` and mutates
`ctx.rng` in place, so one stream advances across the episode. Elixir has no
mutable stream, so `ActionSampler.sample/3` answers `{action, rng}` and the
caller threads it; the policies own the stream, starting it from the context on
their first draw (`ActionSampler.stream/3`), and `reset/1` forgets it so the next
episode starts where its step says.

**Consequence.** Nothing about which actions are drawn differs from Monty's
arithmetic for a given stream — but the stream itself differs, for the reason in
§2.1. A policy that samples twice in one step sees two different actions, as it
does in Monty; this is why the state has to be threaded rather than rederived
from the step, and `scripts/bench_samplers.exs` records that threading is also
the cheaper of the two.

Code sites: `lib/monty/frameworks/actions/action_samplers/action_sampler.ex`,
`lib/monty/frameworks/models/motor_policies/base_policy.ex`,
`lib/monty/frameworks/models/motor_policies/informed_policy.ex`.

## 2.6 `get_top_two_pose_hypotheses_for_graph_id/2` answers `{best, nil}`

See §1.4. Monty raises where this port returns a value.

Code site: `lib/monty/frameworks/models/evidence_matching/learning_module/evidence_graph_lm.ex`,
`get_top_two_pose_hypotheses_for_graph_id/2`.

## 2.7 `depth_at_center` lives in the policy

Monty keeps it in `frameworks/environments/positioning_procedures.py`. Here it is
a private function in `InformedPolicy`, reading the same shape
(`observations[agent_id][sensor_id]["depth"]`, centre pixel), until an
environment is ported and it can move to its mapped home.

Code site: `lib/monty/frameworks/models/motor_policies/informed_policy.ex`, whose
moduledoc says the same.

## 2.8 Small vocabulary differences

- `PolicyStatus` is `:ready | :in_progress` here, `"ready" | "in_progress"`
  upstream; the strings appear only on a wire.
- `rotation_quat` is a `{w, x, y, z}` tuple here and a `quaternion` object there;
  `ActionJSONDecoder` converts on the way in from JSON lists.
- `undo_last_action/1` raises `ArgumentError` where Monty raises `TypeError`, for
  the same reason and with the action named.
- Actions keep Monty's units (degrees, metres, `wxyz`), deliberately: an action
  built here must be the same object an environment there would perform.

Code sites: `lib/monty/frameworks/models/motor_policies/policy_status.ex`,
`lib/monty/frameworks/actions/action_json_decoder.ex`,
`lib/monty/frameworks/models/motor_policies.ex` (`undo_last_action/1`), and every
module under `lib/monty/frameworks/actions/`, whose moduledocs state the units.
