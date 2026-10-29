"""Record what Monty's `GetGoodView` decides when it positions the agent.

Every evaluation episode starts by putting the distant agent somewhere it can see
the object: move closer until the object fills enough of the view or is close
enough, then turn until the centre pixel is on it. That decision is a small state
machine over observations, and it is the first thing a run does — so it is the
first thing a port has to get right.

    python3 scripts/record_monty_positioning.py

Needs an interpreter with Monty's dependencies (see `docs/validation.md`); the
smoothing in `find_location_to_look_at` is `scipy.ndimage.gaussian_filter`.

## What is recorded

  - `get_perc_on_obj_semantic` on a two-object image, once counting any object
    and once counting one id.
  - `compute_look_amounts` for a few relative locations and poses.
  - `find_location_to_look_at`: which pixel a view points at, which pins the
    smoothing — `scipy.ndimage.gaussian_filter(image, size // 16, mode="constant")`.
  - `is_on_target_object` where the centre pixel is on the object and where it is
    not.
  - `move_close_enough` on four observations: close enough by percentage, close
    enough by distance, still far away, nothing visible, and no object at all
    (which raises).
  - `__call__` over a scripted episode: move, move, turn, done — plus the extra
    orientation step a multi-object scene asks for first.
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
    from tbp.monty.frameworks.environments.positioning_procedures import (  # noqa: E402
        GetGoodView,
        get_perc_on_obj_semantic,
    )
    from tbp.monty.frameworks.models.motor_system_state import (  # noqa: E402
        AgentState,
        MotorSystemState,
        ProprioceptiveState,
        SensorState,
    )
except ModuleNotFoundError as error:  # pragma: no cover - the wrong interpreter
    raise SystemExit(
        f"{error.name} is missing from {sys.executable}; run this with an "
        "interpreter that has Monty's dependencies (see docs/validation.md)"
    ) from error

OUT = (
    Path(__file__).resolve().parents[1]
    / "test"
    / "fixtures"
    / "monty_positioning.json"
)

AGENT = "agent_id_0"
SENSOR = "view_finder"
SIZE = 16


def _state(agent_position=(0.0, -0.1, 0.0), agent_degrees=(0.0, 0.0, 0.0),
           sensor_position=(0.0, 0.0, 0.0), sensor_degrees=(0.0, 0.0, 0.0)):
    """A motor-system state, with rotations given in degrees about x, y, z."""
    proprioceptive = ProprioceptiveState(
        {
            AGENT: AgentState(
                position=np.array(agent_position, dtype=np.float64),
                rotation=qt.from_rotation_vector(np.deg2rad(np.array(agent_degrees))),
                sensors={
                    SENSOR: SensorState(
                        position=np.array(sensor_position, dtype=np.float64),
                        rotation=qt.from_rotation_vector(
                            np.deg2rad(np.array(sensor_degrees))
                        ),
                    )
                },
            )
        }
    )
    return MotorSystemState(proprioceptive)


def _observation(semantic, depth):
    """An observation as Monty's positioning code reads it: a semantic image and
    a depth image per sensor, with `semantic_3d` flat, one row per pixel."""
    locations = []
    for row in range(SIZE):
        for column in range(SIZE):
            locations.append([column * 0.01, row * 0.01, -1.0, float(semantic[row][column])])

    return {
        AGENT: {
            SENSOR: {
                "depth": np.asarray(depth, dtype=np.float64),
                "semantic_3d": np.asarray(locations, dtype=np.float64),
            }
        }
    }


def _plain(value):
    return np.asarray(value, dtype=np.float64).tolist()


def _quaternion(degrees):
    rotation = qt.from_rotation_vector(np.deg2rad(np.asarray(degrees, dtype=np.float64)))
    return [float(rotation.w), float(rotation.x), float(rotation.y), float(rotation.z)]


def _state_record(
    agent_position=(0.0, -0.1, 0.0),
    agent_degrees=(0.0, 0.0, 0.0),
    sensor_position=(0.0, 0.0, 0.0),
    sensor_degrees=(0.0, 0.0, 0.0),
):
    """The four numbers a state is read for, with rotations as `wxyz`."""
    return {
        "agent_position": [float(value) for value in agent_position],
        "agent_rotation_wxyz": _quaternion(agent_degrees),
        "sensor_position": [float(value) for value in sensor_position],
        "sensor_rotation_wxyz": _quaternion(sensor_degrees),
    }


def _image(pixel_ids):
    """A 16×16 image, one id per row given as {rows: (first, last), ...}."""
    image = np.zeros((SIZE, SIZE), dtype=int)
    for (row_start, row_end), columns, semantic_id in pixel_ids:
        image[row_start:row_end, columns[0]:columns[1]] = semantic_id
    return image


def _notched(image):
    """The object with a bite taken out, so its brightest smoothed pixel is unique."""
    image[7:9, 9:11] = 0
    return image


def _actions(actions):
    return [
        {
            "action": type(action).__name__,
            "rotation_degrees": (
                None if getattr(action, "rotation_degrees", None) is None
                else float(action.rotation_degrees)
            ),
            "distance": (
                None if getattr(action, "distance", None) is None
                else float(action.distance)
            ),
        }
        for action in actions
    ]


def _taken(action):
    return {"actions": [] if action is None else _actions([action])}


def _procedure(multiple_objects=False, allow_translation=True, orientation_attempts=1):
    return GetGoodView(
        agent_id=AGENT,
        good_view_distance=0.03,
        good_view_percentage=0.5,
        multiple_objects_present=multiple_objects,
        sensor_id=SENSOR,
        target_semantic_id=3,
        allow_translation=allow_translation,
        max_orientation_attempts=orientation_attempts,
    )


def main():
    # A small target in the upper left, and another object in the lower right.
    two_objects = _image(
        [
            ((4, 10), (5, 11), 3),
            ((11, 14), (12, 15), 7),
        ]
    )
    corner = _image([((1, 5), (1, 5), 3)])
    centred = _image([((7, 10), (7, 10), 3)])
    # A notched object, not a rectangle: a symmetric one has a *plateau* of
    # equally bright pixels after smoothing, and which of them numpy picks is a
    # fact about summation order rather than about Monty. The notch leaves one
    # clear winner.
    small = _notched(_image([((4, 10), (5, 12), 3)]))
    big = _image([((2, 14), (2, 14), 3)])  # 144 of 256 pixels: 56%
    other_object = _image([((11, 14), (12, 15), 7)])
    two_objects_off_centre = _image(
        [
            ((1, 5), (1, 5), 3),
            ((11, 14), (12, 15), 7),
        ]
    )
    images = {
        "two objects": two_objects,
        "two objects off centre": two_objects_off_centre,
        "small": small,
        "corner": corner,
        "centred": centred,
        "big": big,
        "other object": other_object,
        "empty": _image([]),
    }

    depth_of = lambda image, on_object: np.where(image > 0, on_object, 2.0)  # noqa: E731

    percentages = {
        "any object": float(get_perc_on_obj_semantic(two_objects, semantic_id="any")),
        "target only": float(get_perc_on_obj_semantic(two_objects, semantic_id=3)),
    }

    # -- the turn and the pitch to point at a pixel ------------------------
    procedure = _procedure()
    look_amounts = []
    for relative_location, pose in [
        ([0.0, 0.0, -1.0], {}),
        ([0.3, 0.2, -0.8], {}),
        ([-0.4, -0.1, -0.9], {"sensor_degrees": (20.0, 0.0, 0.0)}),
        ([0.1, 0.5, -0.5], {"agent_degrees": (0.0, 30.0, 0.0), "sensor_degrees": (0.0, 10.0, 0.0)}),
    ]:
        state = _state(**pose)
        down, left = procedure.compute_look_amounts(
            np.array(relative_location, dtype=np.float64), state
        )
        look_amounts.append(
            {
                "relative_location": relative_location,
                "state": _state_record(**pose),
                "down_degrees": float(down),
                "left_degrees": float(left),
            }
        )

    # -- where in the view the procedure looks ------------------------------
    observation = _observation(small, depth_of(small, 1.0))
    location_to_look_at = _plain(
        procedure.find_location_to_look_at(
            observation[AGENT][SENSOR]["semantic_3d"],
            image_shape=(SIZE, SIZE),
            state=_state(),
        )
    )

    # -- is the centre pixel on the object ----------------------------------
    # The centre of a 16×16 view is pixel (8, 8), so an object in the corner is
    # visible but not centred.
    is_on_target = {
        "on object": bool(
            procedure.is_on_target_object(_observation(centred, depth_of(centred, 1.0)))
        ),
        "off object": bool(
            procedure.is_on_target_object(_observation(corner, depth_of(corner, 1.0)))
        ),
    }

    # -- moving closer ------------------------------------------------------
    close_enough_by_percentage = procedure.move_close_enough(
        _observation(big, depth_of(big, 1.0))
    )
    close_enough_by_distance = procedure.move_close_enough(
        _observation(small, depth_of(small, 0.02))
    )
    still_far = procedure.move_close_enough(_observation(small, depth_of(small, 1.0)))

    multi = _procedure(multiple_objects=True)
    nothing_visible = multi.move_close_enough(
        _observation(other_object, depth_of(other_object, 2.0))
    )

    empty = _image([])
    try:
        procedure.move_close_enough(_observation(empty, np.full((SIZE, SIZE), 2.0)))
    except Exception as error:  # noqa: BLE001 - the refusal is the answer
        nothing_at_all = {"raises": type(error).__name__}
    else:  # pragma: no cover - Monty's docstring promises the raise
        raise AssertionError("Monty moved towards an object it cannot see")

    # -- the state machine ---------------------------------------------------
    def run(steps, multiple_objects=False):
        procedure = _procedure(
            multiple_objects=multiple_objects, orientation_attempts=1
        )
        recorded = []
        for label, image_name, on_object in steps:
            image = images[image_name]
            result = procedure(_observation(image, depth_of(image, on_object)), _state())
            recorded.append(
                {
                    "step": label,
                    "image": image_name,
                    "depth_on_object": on_object,
                    "actions": _actions(result.actions),
                    "success": bool(result.success),
                    "terminated": bool(result.terminated),
                    "truncated": bool(result.truncated),
                }
            )
        return recorded

    single_object_episode = run(
        [
            ("a small object, far away", "small", 1.0),
            ("still far away", "small", 1.0),
            ("close, but the centre is off the object", "corner", 0.02),
            ("the centre is on the object", "centred", 0.02),
        ]
    )

    multi_object_episode = run(
        [
            ("two objects, centre off the target", "two objects off centre", 0.02),
            ("now centred on the target", "centred", 0.02),
        ],
        multiple_objects=True,
    )

    fixture = {
        "agent_id": AGENT,
        "default_state": _state_record(),
        "images": {name: image.tolist() for name, image in images.items()},
        "location_step": 0.01,
        "background_depth": 2.0,
        "sensor_id": SENSOR,
        "good_view_distance": 0.03,
        "good_view_percentage": 0.5,
        "target_semantic_id": 3,
        "size": SIZE,
        "percentages": percentages,
        "look_amounts": look_amounts,
        "location_to_look_at": location_to_look_at,
        "is_on_target_object": is_on_target,
        "moving_closer": {
            "close enough by percentage": _taken(close_enough_by_percentage),
            "close enough by distance": _taken(close_enough_by_distance),
            "still far away": _taken(still_far),
            "nothing visible": _taken(nothing_visible),
            "no object at all": nothing_at_all,
        },
        "episodes": {
            "single object": single_object_episode,
            "two objects": multi_object_episode,
        },
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixture, indent=1) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
