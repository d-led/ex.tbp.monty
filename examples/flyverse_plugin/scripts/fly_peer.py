"""A fly body as a simulator on the other side of `Port.Environment`'s port.

    python examples/flyverse_plugin/scripts/fly_peer.py

`Monty.Simulators.Port.Protocol` already says what this must say, so this script
writes nothing new: it reads **length-prefixed JSON** on stdin (four bytes,
big-endian, then that many bytes of UTF-8) and writes the same framing on stdout.

    -> {"id": 1, "command": "reset", "sensor_ids": ["left", "right"]}
    <- {"id": 1, "ok": true, "primary_target": null}

    -> {"id": 2, "command": "step",
        "actions": [{"action": "orient_horizontal", "agent_id": "agent_id_0",
                     "rotation_degrees": 15.0, "left_distance": 0.0,
                     "forward_distance": 0.02}]}
    <- {"id": 2, "observations": {...}, "proprioceptive_state": {...}}

Monty's action names a **turn and a stride**, and the fly body takes a
**descending signal** `[left, right]`; the two are one arithmetic step apart,
with gains measured from the body itself (see `fly_walk.py` and the flyverse
page):

    forward = left + right      ~ 14.6 mm/s at [1.2, 1.2]
    turn    = left - right      ~ 185 deg/s per unit of differential

So a request is turned into `seconds` of body time, and the body is stepped at
its own 0.1 ms for that long. Metres go in and centimetres come out, which is
the port's own convention: an agent's pose is metres everywhere except here.

Needs the interpreter that has `flygym` (see `fly_body.py` — it cannot be the
application's).
"""

import json
import struct
import sys

import numpy as np

from flygym import Simulation
from flygym.anatomy import BodySegment, ContactBodiesPreset
from flygym.compose import FlatGroundWorld
from flygym.utils.math import Rotation3D
from flygym_demo.complex_terrain import (
    HybridControllerObservation,
    HybridTurningController,
    LocomotionAction,
    PreprogrammedSteps,
    apply_locomotion_action,
    make_locomotion_fly,
)

# Measured on the flat-ground fly: at `[1.2, 1.2]` it covers 14.6 mm in a
# second, so a stride of `forward_mm` is that many seconds of body time.
FORWARD_MM_PER_SECOND = 14.6 / 1.2
# The turn is closed on the body's own heading rather than scaled by a gain:
# measured, the same differential turns the body 119 deg/s one way and 352 the
# other (`[1, -1]` -> -23.8 deg in 0.2 s, `[-1, 1]` -> +70.5 deg), so a gain
# would be a fiction. A lean, and a heading to stop at, has no such problem.
TURN_LEAN = 0.6
TURN_TOLERANCE_DEG = 3.0
# How much body time a turn of a degree is budgeted: the slow of the two
# measured rates, so a turn is given long enough to actually arrive.
TURN_SECONDS_PER_DEGREE = 1.0 / 90.0
# Neither a pure turn nor a standstill gets zero seconds: a step of the world
# has to take some time or the model never sees the body move.
MINIMUM_SECONDS = 0.02
MAXIMUM_SECONDS = 0.5


class Body:
    """The fly, held between requests, in the units the port speaks."""

    def __init__(self, sensor_ids):
        self.sensor_ids = sensor_ids
        self.fly = make_locomotion_fly(name="nmf", add_adhesion=True, colorize=False)
        self.fly.add_vision()

        world = FlatGroundWorld()
        world.add_fly(
            self.fly,
            [0, 0, 0.8],
            Rotation3D("quat", [1, 0, 0, 0]),
            bodysegs_with_ground_contact=ContactBodiesPreset.TIBIA_TARSUS_ONLY,
            add_ground_contact_sensors=False,
        )
        self.simulation = Simulation(world)

        self.steps = PreprogrammedSteps()
        self.dofs = self.fly.get_actuated_jointdofs_order("position")
        self.controller = HybridTurningController(
            timestep=self.simulation.timestep,
            preprogrammed_steps=self.steps,
            output_dof_order=self.dofs,
        )
        self.thorax = self.fly.get_bodysegs_order().index(BodySegment("c_thorax"))
        self.reset()

    def reset(self):
        self.simulation.reset()
        self.controller.reset(seed=0)
        apply_locomotion_action(
            self.simulation,
            self.fly.name,
            LocomotionAction(
                joint_angles=self.steps.default_pose_by_dof_order(self.dofs),
                adhesion_onoff=np.ones(6, dtype=bool),
            ),
        )
        self.simulation.warmup()

    def yaw(self):
        """The body's heading, in degrees, counter-clockwise from +x."""
        w, x, y, z = np.asarray(
            self.simulation.get_body_rotations(self.fly.name)[self.thorax]
        ).reshape(-1)[:4]
        return float(np.degrees(np.arctan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))))

    def step(self, actions):
        """Run the body for the time the actions ask for, then say what happened.

        A turn is an instruction to *arrive at* a heading, so it is closed on the
        heading: each body step asks how far the body still is from where the
        action wanted it and leans the differential that way. The measured sign
        is the body's own — `left - right` above zero turns the heading down —
        so the lean is applied with the opposite sign.
        """
        turn, forward_mm = 0.0, 0.0
        for action in actions:
            if action.get("action") == "orient_horizontal":
                turn += float(action.get("rotation_degrees") or 0.0)
                forward_mm += float(action.get("forward_distance") or 0.0) * 1000.0

        # The stride needs its time and the turn needs its own: a pure turn has
        # no distance to divide by, and a lean that runs out of body time stops
        # short of the heading the action asked for.
        seconds = min(
            max(
                abs(forward_mm) / FORWARD_MM_PER_SECOND,
                abs(turn) * TURN_SECONDS_PER_DEGREE,
                MINIMUM_SECONDS,
            ),
            MAXIMUM_SECONDS,
        )
        # A stride of the action's length spread over those seconds, capped at
        # the command the gait was measured at.
        forward_units = min(max(forward_mm / (FORWARD_MM_PER_SECOND * seconds), 0.0), 1.2)
        target = normalise(self.yaw() + turn)

        for _ in range(max(int(seconds / self.simulation.timestep), 1)):
            remaining = normalise(target - self.yaw())
            lean = 0.0
            if abs(remaining) > TURN_TOLERANCE_DEG:
                lean = -TURN_LEAN if remaining > 0 else TURN_LEAN
            descending = np.asarray([forward_units + lean, forward_units - lean], dtype=float)

            observation = HybridControllerObservation.from_sim(self.simulation, self.fly.name)
            commanded = self.controller.step(descending, observation)
            apply_locomotion_action(self.simulation, self.fly.name, commanded)
            self.simulation.step()

        return self.observations(), self.proprioceptive_state()

    def proprioceptive_state(self):
        """Where the body is: metres and a `wxyz` quaternion, as the port wants."""
        position = np.asarray(self.simulation.get_body_positions(self.fly.name)[self.thorax])
        rotation = np.asarray(self.simulation.get_body_rotations(self.fly.name)[self.thorax])
        w, x, y, z = rotation.reshape(-1)[:4]
        pose = {
            "position": [float(v) / 1000.0 for v in position],
            "rotation": [float(w), float(x), float(y), float(z)],
        }
        return {"agent_id_0": dict(pose, sensors={sid: pose for sid in self.sensor_ids})}

    def observations(self):
        """What each named sensor sees: the compound eye's own readout.

        A fly does not have a patch of RGBA, it has 721 ommatidia per eye, each
        reading one of two photoreceptor types — yellow and pale — with a zero in
        the other column. That is 1442 numbers per eye instead of 691,200 pixels,
        and it is the fly's percept rather than a camera's, so a sensor module
        reading this body reads what the body has.
        """
        readouts = np.asarray(self.simulation.get_ommatidia_readouts(self.fly.name))
        observations = {}
        for index, sensor_id in enumerate(self.sensor_ids):
            if index >= len(readouts):
                continue
            observations[sensor_id] = {
                "what": "ommatidia",
                "channels": ["yellow", "pale"],
                "ommatidia": np.round(readouts[index], 4).tolist(),
            }
        return {"agent_id_0": observations}


# -- the framing ------------------------------------------------------------


def normalise(degrees):
    """An angle in degrees, as the shortest turn between -180 and 180."""
    return (degrees + 180.0) % 360.0 - 180.0


def read_request(stream):
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack(">I", header)
    return json.loads(stream.read(length).decode("utf-8"))


def write_reply(stream, body):
    payload = json.dumps(body).encode("utf-8")
    stream.write(struct.pack(">I", len(payload)) + payload)
    stream.flush()


def main():
    stream_in, stream_out = sys.stdin.buffer, sys.stdout.buffer
    body = None

    while True:
        request = read_request(stream_in)
        if request is None:
            return
        identifier = request.get("id")
        command = request.get("command")

        if command == "reset":
            if body is None:
                body = Body(request.get("sensor_ids") or [])
            else:
                body.sensor_ids = request.get("sensor_ids") or body.sensor_ids
                body.reset()
            write_reply(stream_out, {"id": identifier, "ok": True})
            continue

        if command == "step" and body is not None:
            observations, state = body.step(request.get("actions") or [])
            write_reply(
                stream_out,
                {"id": identifier, "observations": observations, "proprioceptive_state": state},
            )
            continue

        write_reply(stream_out, {"id": identifier, "error": f"cannot: {command!r}"})


if __name__ == "__main__":
    main()
