"""Drive a NeuroMechFly with a descending command shaped like a Monty action.

    python examples/flyverse_plugin/scripts/fly_walk.py

The bridge this proves is one function wide. FlyGym's turning controller takes
a two-channel *descending signal*

    descending = [left, right]      forward = left + right, turn = left - right

and answers with joint targets and adhesion states for the six legs. Monty's
motor policy says the same kind of thing in its own units — a yaw and a
distance — so the mapping is one arithmetic step, and the body does the rest.

`fly_body.py` beside this one composes a fly by hand and says what the leg
surface is; this one uses FlyGym's own locomotion fly, so it needs the
interpreter that has `flygym` (not the application's — see `fly_body.py`).
"""

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

# One second of the body's own command, per direction: what it costs to walk.
SECONDS = 1.0


def build():
    """A locomotion fly on flat ground, with eyes and a controller."""
    fly = make_locomotion_fly(name="nmf", add_adhesion=True, colorize=False)
    fly.add_vision()

    world = FlatGroundWorld()
    world.add_fly(
        fly,
        [0, 0, 0.8],
        Rotation3D("quat", [1, 0, 0, 0]),
        bodysegs_with_ground_contact=ContactBodiesPreset.TIBIA_TARSUS_ONLY,
        add_ground_contact_sensors=False,
    )
    simulation = Simulation(world)

    steps = PreprogrammedSteps()
    dofs = fly.get_actuated_jointdofs_order("position")
    controller = HybridTurningController(
        timestep=simulation.timestep, preprogrammed_steps=steps, output_dof_order=dofs
    )

    simulation.reset()
    controller.reset(seed=0)
    apply_locomotion_action(
        simulation,
        fly.name,
        LocomotionAction(
            joint_angles=steps.default_pose_by_dof_order(dofs),
            adhesion_onoff=np.ones(6, dtype=bool),
        ),
    )
    simulation.warmup()

    return fly, simulation, controller, steps, dofs


def yaw(simulation, fly, thorax):
    """The body's heading in degrees, from MuJoCo's (w, x, y, z) quaternion."""
    w, x, y, z = np.asarray(simulation.get_body_rotations(fly.name)[thorax]).reshape(-1)[:4]
    return float(np.degrees(np.arctan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))))


def drive(simulation, fly, controller, descending, seconds=SECONDS):
    """Step the body under one descending command; say where it went."""
    thorax = fly.get_bodysegs_order().index(BodySegment("c_thorax"))
    before = np.asarray(simulation.get_body_positions(fly.name)[thorax]).copy()
    heading_before = yaw(simulation, fly, thorax)

    for _ in range(int(seconds / simulation.timestep)):
        observation = HybridControllerObservation.from_sim(simulation, fly.name)
        action = controller.step(np.asarray(descending, dtype=float), observation)
        apply_locomotion_action(simulation, fly.name, action)
        simulation.step()

    moved = np.asarray(simulation.get_body_positions(fly.name)[thorax]) - before
    return np.round(moved, 2), round(yaw(simulation, fly, thorax) - heading_before, 1)


def main():
    fly, simulation, controller, steps, dofs = build()
    thorax = fly.get_bodysegs_order().index(BodySegment("c_thorax"))
    print("legs", steps.legs, "leg dofs", len(dofs), "timestep", simulation.timestep)
    print("thorax at rest", np.round(simulation.get_body_positions(fly.name)[thorax], 3))

    for name, descending in [
        ("forward [1.2, 1.2]", [1.2, 1.2]),
        ("left    [0.4, 1.2]", [0.4, 1.2]),
        ("right   [1.2, 0.4]", [1.2, 0.4]),
    ]:
        moved, turned = drive(simulation, fly, controller, descending)
        print(f"{name} {SECONDS} s -> moved {moved} mm, heading {turned} deg")

    print("ommatidia", np.asarray(simulation.get_ommatidia_readouts(fly.name)).shape)
    print("raw vision", np.asarray(simulation.get_raw_vision(fly.name)).shape)


if __name__ == "__main__":
    main()
