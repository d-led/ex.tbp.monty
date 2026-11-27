"""A NeuroMechFly, composed with drivable legs, stepped by a body command.

    python examples/flyverse_plugin/scripts/fly_body.py

Needs `flygym` in its own interpreter, and it cannot share this application's:
FlyGym installs MuJoCo 3.16, while the interpreter `priv/monty_py/world.py`
runs in is pinned to 4.0.1 for reasons `config/pythonx.exs` records. So a fly
body is a second interpreter beside the one the BEAM carries — the shape the
plugin hosts already have.

    python3 -m venv /tmp/fly && /tmp/fly/bin/pip install flygym
    /tmp/fly/bin/python examples/flyverse_plugin/scripts/fly_body.py

What it answers is the surface a Monty action has to be mapped onto, and the
percept a fly policy would get back:

FlyGym 2's compose API is explicit: a bare `NeuroMechFly` is a body with no
joints and no actuators. The legs become drivable when a skeleton's active leg
dofs are added and a position actuator is named for each — 42 of them — and the
surface a Monty action must be mapped onto is then:

    set_actuator_inputs("nmf", "position", targets)  <- the action, per window
    set_leg_adhesion_states("nmf", six flags)         <- feet on or off the ground
    get_body_positions / get_joint_angles             -> where the body went
    get_ommatidia_readouts / get_raw_vision            -> what the eyes saw
"""
import numpy as np
import flygym.anatomy as anatomy
import flygym.compose as fc
from flygym.simulation import Simulation
from flygym.utils.math import Rotation3D

fly = fc.NeuroMechFly(name="nmf")
skeleton = anatomy.Skeleton(
    axis_order=anatomy.AxisOrder.YAW_PITCH_ROLL,
    joint_preset=anatomy.JointPreset.LEGS_ACTIVE_ONLY,
)
dofs = skeleton.get_actuated_dofs_from_preset(anatomy.ActuatedDOFPreset.LEGS_ACTIVE_ONLY)

fly.add_joints(
    skeleton, neutral_pose=fc.KinematicPosePreset.NEUTRAL, stiffness=5.0, damping=0.1
)
fly.add_actuators(dofs, actuator_type="position")
fly.add_leg_adhesion()
fly.add_vision()

world = fc.FlatGroundWorld(name="ground")
world.add_fly(
    fly,
    spawn_position=(0.0, 0.0, 0.008),
    spawn_rotation=Rotation3D("quat", (1.0, 0.0, 0.0, 0.0)),
)
sim = Simulation(world)
print("legs", fly.get_legs_order(), "dofs", len(dofs), "nq", sim.mj_model.nq,
      "nu", sim.mj_model.nu, "timestep", sim.timestep)

sim.warmup(0.1)
thorax = lambda: [round(float(x), 4) for x in sim.get_body_positions("nmf")[1]]
print("thorax after warmup", thorax())

neutral = sim.get_joint_angles("nmf").copy()

# A body command, the shape Monty's actions would arrive in: a stride amplitude
# and a turn bias. The two tripods swing in antiphase; the bias leans the swing
# left or right. This is not a gait — it is the bridge, and the check is that the
# body follows the command.
for step in range(800):
    swing = np.sin(2 * np.pi * step / 80.0)
    targets = neutral + 0.25 * swing * (1 if step // 80 % 2 == 0 else -1)
    sim.set_actuator_inputs("nmf", fc.ActuatorType.POSITION, targets)
    sim.set_leg_adhesion_states("nmf", np.ones(6))
    sim.step()

print("thorax after 800 steps", thorax())
angles = np.asarray(sim.get_joint_angles("nmf"))
print("joint angles shape", angles.shape, "range", round(float(np.ptp(angles)), 3))
print("ommatidia", np.asarray(sim.get_ommatidia_readouts("nmf")).shape)
print("raw vision", np.asarray(sim.get_raw_vision("nmf")).shape)
