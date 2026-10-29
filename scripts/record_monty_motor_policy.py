"""Record what Monty's motor half decides: goals ranked, and actions out.

The salience fixture covers where the view finder wants to look; this covers what
the motor system does with those goals. `LookAtGoal` turns a goal into a yaw and a
pitch, `highest_confidence_goal` decides which of many goals is pursued, and
`DistantPolicySelector` decides which policy runs at all. Those three are the
whole of the motor half of a distant-agent step, and their numbers become the
actions a run sends to its body.

    python3 scripts/record_monty_motor_policy.py

Needs an interpreter with Monty's dependencies (see `docs/validation.md`).

## What is recorded

  - `highest_confidence_goal` over lists with distinct confidences, with a tie,
    and with one goal — Monty's docstring promises the first of a tie wins.
  - `LookAtGoal` over a grid of agent poses and goal locations, including a goal
    sitting on the sensor (which Monty refuses) and one behind the agent.
  - `SinglePolicySelector`, which pursues the most confident goal whatever its
    sender.
  - `DistantPolicySelector`' where it routes an SM goal to `LookAtGoal`, and where
    it falls back to the default policy when there is no goal at all.

## The stub, and why it is in the recorder

The default policy of a distant agent is `InformedPolicy`, which needs a percept
full of hypotheses to say anything, and those live behind Monty's learning
modules — the part of Monty that needs `torch`. So the fallback is recorded with
a stub whose only job is to say *that it was consulted, with no goal*. That
records the selector's routing, not the default policy's arithmetic; the port's
own default policy is tested where it lives.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

import numpy as np  # noqa: E402
import quaternion as qt  # noqa: E402

try:
    from tbp.monty.cmp import Goal, Message  # noqa: E402
    from tbp.monty.context import RuntimeContext  # noqa: E402
    from tbp.monty.frameworks.models.motor_policies import (  # noqa: E402
        JumpToGoal,
        MotorPolicy,
        MotorPolicyResult,
        fixme_undo_last_action,
    )
    from tbp.monty.frameworks.models.motor_policy_selectors import (  # noqa: E402
        DistantPolicySelector,
        SinglePolicySelector,
        highest_confidence_goal,
    )
    from tbp.monty.frameworks.models.motor_system_state import (  # noqa: E402
        AgentState,
        MotorSystemState,
        ProprioceptiveState,
        SensorState,
    )
    from tbp.monty.frameworks.models.salience.motor_policy import (  # noqa: E402
        LookAtGoal,
    )
except ModuleNotFoundError as error:  # pragma: no cover - the wrong interpreter
    raise SystemExit(
        f"{error.name} is missing from {sys.executable}; run this with an "
        "interpreter that has Monty's dependencies (see docs/validation.md)"
    ) from error

OUT = (
    Path(__file__).resolve().parents[1] / "test" / "fixtures" / "monty_motor_policy.json"
)

AGENT = "agent_id_0"
SENSOR = "camera_id_0"

# A pose is the agent's position and rotation, and its sensor's position and
# rotation relative to the agent — the four things `LookAtGoal` reads.
POSES = [
    {
        "name": "looking straight ahead",
        "agent_position": [0.0, -0.1, 0.0],
        "agent_rotation": [0.0, 0.0, 0.0],
        "sensor_position": [0.0, 0.0, 0.0],
        "sensor_rotation": [0.0, 0.0, 0.0],
    },
    {
        "name": "turned thirty degrees",
        "agent_position": [0.0, -0.1, 0.0],
        "agent_rotation": [0.0, 30.0, 0.0],
        "sensor_position": [0.0, 0.0, 0.0],
        "sensor_rotation": [0.0, 0.0, 0.0],
    },
    {
        "name": "turned a hundred and twenty, sensor pitched up",
        "agent_position": [0.3, -0.2, -0.4],
        "agent_rotation": [0.0, 120.0, 0.0],
        "sensor_position": [0.0, 0.05, 0.0],
        "sensor_rotation": [20.0, 0.0, 0.0],
    },
    {
        "name": "sensor pitched up, agent tilted forward",
        "agent_position": [-0.2, 0.1, 0.5],
        "agent_rotation": [15.0, -40.0, 0.0],
        "sensor_position": [0.0, 0.0, 0.1],
        "sensor_rotation": [25.0, 0.0, 0.0],
    },
]

GOALS = [
    [0.0, 0.0, -1.0],
    [0.5, 0.0, -1.0],
    [-0.3, 0.4, -0.8],
    [0.2, -0.5, -1.2],
    [0.0, 0.0, 1.0],
]


def _quaternion(degrees_xyz):
    """The quaternion of a rotation given as degrees about x, y, z.

    Recorded as `wxyz`, because a rotation *vector* and a sequence of Euler
    angles are different rotations in general, and the comparison here is of
    `LookAtGoal`'s arithmetic, not of two ways of reading a pose.
    """
    rotation = qt.from_rotation_vector(np.deg2rad(np.asarray(degrees_xyz, dtype=np.float64)))
    return [float(rotation.w), float(rotation.x), float(rotation.y), float(rotation.z)]


def _with_quaternions(pose):
    return {
        **pose,
        "agent_rotation_wxyz": _quaternion(pose["agent_rotation"]),
        "sensor_rotation_wxyz": _quaternion(pose["sensor_rotation"]),
    }


def _state(pose):
    proprioceptive = ProprioceptiveState(
        {
            AGENT: AgentState(
                position=np.array(pose["agent_position"], dtype=np.float64),
                rotation=qt.quaternion(*pose["agent_rotation_wxyz"]),
                sensors={
                    SENSOR: SensorState(
                        position=np.array(pose["sensor_position"], dtype=np.float64),
                        rotation=qt.quaternion(*pose["sensor_rotation_wxyz"]),
                    )
                },
            )
        }
    )

    return MotorSystemState(proprioceptive)


def _goal(location, confidence=0.5, sender_type="SM", sender_id="view_finder"):
    return Goal(
        location=None if location is None else np.array(location, dtype=np.float64),
        morphological_features=None,
        non_morphological_features=None,
        confidence=confidence,
        pass_message=False,
        sender_id=sender_id,
        sender_type=sender_type,
        process_features_in_lm=False,
        goal_tolerances=None,
    )


def _actions(result):
    return [
        {"action": type(action).__name__, "rotation_degrees": float(action.rotation_degrees)}
        for action in result.actions
    ]


def _goals(goals):
    return [
        {
            "location": [float(coordinate) for coordinate in goal.location],
            "confidence": float(goal.confidence),
            "sender_type": goal.sender_type,
        }
        for goal in goals
    ]


def _undo_record(action):
    return None if action is None else _action_record(action)


def _percept(on_object):
    """The percept an informed policy reads: whether the sensor is on the object."""
    return Message(
        location=None,
        morphological_features={"on_object": on_object},
        non_morphological_features={},
        confidence=1.0,
        pass_message=True,
        sender_id="patch",
        sender_type="SM",
        process_features_in_lm=False,
    )


def _action_record(action):
    return {
        "action": type(action).__name__,
        "agent_id": action.agent_id,
        "rotation_degrees": getattr(action, "rotation_degrees", None),
        "constraint_degrees": getattr(action, "constraint_degrees", None),
        "distance": getattr(action, "distance", None),
        "direction": (
            None if getattr(action, "direction", None) is None
            else [float(coordinate) for coordinate in action.direction]
        ),
    }


class RecordingDefault(MotorPolicy):
    """Says only that the selector fell back to it, and with what goal."""

    def __init__(self):
        self.calls = []

    def fixme_provide_motor_system(self, motor_system):
        pass

    def reset(self):
        self.calls = []

    def load_state_dict(self, memento):
        self.calls = list(memento.get("calls", [])) if isinstance(memento, dict) else []

    def state_dict(self):
        return {"calls": len(self.calls)}

    def __call__(self, ctx, observations, state, percept, goal):  # noqa: ARG002
        self.calls.append(goal)
        return MotorPolicyResult([])


def _look_at_goal(policy, pose, goals):
    """What the policy answers for this pose, or that it refused."""
    ctx = RuntimeContext(rng=np.random.RandomState(0))
    state = _state(pose)
    goal = _goal(goals[0]) if goals else None

    try:
        result = policy(ctx, {}, state, None, goal)
    except Exception as error:  # noqa: BLE001 - the refusal is the answer
        return {"raises": type(error).__name__}

    return {"actions": _actions(result), "motor_only_step": bool(result.motor_only_step)}


def main():
    ctx = RuntimeContext(rng=np.random.RandomState(0))
    poses = [_with_quaternions(pose) for pose in POSES]

    # -- the walk an informed policy makes on and off the object ------------
    from tbp.monty.frameworks.actions.action_samplers import ConstantSampler  # noqa: PLC0415
    from tbp.monty.frameworks.actions.actions import MoveForward  # noqa: PLC0415
    from tbp.monty.frameworks.models.motor_policies import (  # noqa: PLC0415
        InformedPolicyRandomWalk,
    )

    walk = InformedPolicyRandomWalk(
        agent_id=AGENT,
        action_sampler=ConstantSampler(
            actions=[MoveForward], translation_distance=0.05
        ),
    )

    # Off the object with nothing to undo, twice on it, then off it twice: the
    # remembered action is inverted every time it is used.
    walk_steps = []
    for on_object in [False, True, True, False, False]:
        result = walk(
            RuntimeContext(rng=np.random.RandomState(0)),
            {},
            _state(poses[0]),
            _percept(on_object),
            None,
        )
        walk_steps.append(
            {
                "on_object": on_object,
                "actions": [_action_record(action) for action in result.actions],
                "undo_action": _undo_record(walk.state_dict()["undo_action"]),
            }
        )

    # -- the six actions an informed policy can take back -------------------
    from tbp.monty.frameworks.actions.actions import (  # noqa: PLC0415
        LookDown,
        LookUp,
        MoveForward,
        MoveTangentially,
        OrientHorizontal,
        TurnLeft,
        TurnRight,
    )

    undoable = [
        LookDown(agent_id=AGENT, rotation_degrees=5.0, constraint_degrees=45.0),
        LookUp(agent_id=AGENT, rotation_degrees=-12.5, constraint_degrees=10.0),
        TurnLeft(agent_id=AGENT, rotation_degrees=30.0),
        TurnRight(agent_id=AGENT, rotation_degrees=-7.0),
        MoveForward(agent_id=AGENT, distance=0.05),
        MoveTangentially(agent_id=AGENT, distance=0.03, direction=(1.0, 0.0, 0.0)),
    ]

    undo = [
        {"action": _action_record(action), "undo": _action_record(fixme_undo_last_action(action))}
        for action in undoable
    ]

    # The policy samples only those six, so anything else has no inverse.
    not_undoable = OrientHorizontal(agent_id=AGENT, rotation_degrees=5.0,
                                   left_distance=0.004, forward_distance=0.004)
    try:
        fixme_undo_last_action(not_undoable)
    except TypeError:
        not_undoable_record = _action_record(not_undoable)
    else:  # pragma: no cover - Monty's docstring promises the TypeError
        raise AssertionError("Monty undid an action its docstring says it cannot")

    # -- which goal wins ---------------------------------------------------
    ranked = [
        {
            "confidences": [0.2, 0.9, 0.5],
            "chosen": 1,
        },
        {
            "confidences": [0.4, 0.4, 0.1],
            "chosen": 0,
        },
        {
            "confidences": [0.7],
            "chosen": 0,
        },
    ]

    for case in ranked:
        goals = [_goal([0.0, 0.0, -1.0], confidence=c) for c in case["confidences"]]
        assert goals.index(highest_confidence_goal(goals)) == case["chosen"]

    # -- the turn and the pitch -------------------------------------------
    policy = LookAtGoal(agent_id=AGENT, sensor_id=SENSOR)

    look_at = []
    for pose in poses:
        for goal in GOALS:
            look_at.append(
                {"pose": pose["name"], "goal": goal, **_look_at_goal(policy, pose, [goal])}
            )

    # A goal on the sensor: there is no azimuth to turn to.
    collocated = poses[0]
    at_sensor = [
        collocated["agent_position"][0] + collocated["sensor_position"][0],
        collocated["agent_position"][1] + collocated["sensor_position"][1],
        collocated["agent_position"][2] + collocated["sensor_position"][2],
    ]
    refused = {"pose": collocated["name"], "goal": at_sensor, **_look_at_goal(policy, collocated, [at_sensor])}
    assert refused.get("raises") == "GoalCollocatedWithSensor", refused

    # -- a selector that takes the most confident goal whatever its sender --
    single = SinglePolicySelector(LookAtGoal(agent_id=AGENT, sensor_id=SENSOR))
    mixed = [
        _goal([0.5, 0.0, -1.0], confidence=0.3, sender_type="SM"),
        _goal([-0.3, 0.4, -0.8], confidence=0.8, sender_type="LM", sender_id="LM_0"),
        _goal([0.2, -0.5, -1.2], confidence=0.6, sender_type="SM"),
    ]
    single_result = single(ctx, {}, _state(poses[0]), None, mixed)

    # -- the distant agent's routing ---------------------------------------
    default = RecordingDefault()
    distant = DistantPolicySelector(
        jump_to_goal=JumpToGoal(agent_id=AGENT, sensor_id=SENSOR),
        look_at_goal=LookAtGoal(agent_id=AGENT, sensor_id=SENSOR),
        default=default,
    )

    sm_goals = [
        _goal([0.5, 0.0, -1.0], confidence=0.1),
        _goal([-0.3, 0.4, -0.8], confidence=0.9),
    ]
    routed = distant(ctx, {}, _state(poses[1]), None, sm_goals)
    assert not default.calls, "an SM goal should not reach the default policy"

    fallback = distant(ctx, {}, _state(poses[1]), None, [])
    assert len(default.calls) == 1, "no goals should reach the default policy exactly once"
    assert default.calls[0] is None, "the default policy is consulted with no goal"

    fixture = {
        "agent_id": AGENT,
        "sensor_id": SENSOR,
        "poses": poses,
        "random_walk": {
            "translation_distance": 0.05,
            "steps": walk_steps,
        },
        "undo": undo,
        "not_undoable": not_undoable_record,
        "highest_confidence_goal": ranked,
        "look_at_goal": look_at,
        "collocated": refused,
        "single_policy_selector": {
            "goals": _goals(mixed),
            "actions": _actions(single_result),
        },
        "distant_policy_selector": {
            "sm_goals": {
                "goals": _goals(sm_goals),
                "actions": _actions(routed),
            },
            "no_goals": {"consulted_default": len(default.calls), "actions": _actions(fallback)},
        },
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixture, indent=1) + "\n")
    print(f"wrote {OUT} ({len(look_at)} look-at cases, {len(poses)} poses)")


if __name__ == "__main__":
    main()
