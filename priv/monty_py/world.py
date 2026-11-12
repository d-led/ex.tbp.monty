"""Monty's MuJoCo world, and the JSON the BEAM speaks to it.

`tbp/monty/simulators/mujoco/` is what this file mirrors, class for class:
`simulator.py::MuJoCoSimulator` (the MjSpec, its lights, one `Renderer` per
resolution, `add_object` with its mesh loading and semantic-id mapping, and the
`observations` / `states` / `step` / `reset` / `close` surface) and
`agents.py` (the `Embodiment` a body and its cameras are, and the three agents
that answer actions through it). The numbers, the units and the order of the
operations are Monty's; only the *containers* are not, because the copies of
Monty those classes answer in (`Observations`, `AgentState`, `SensorConfig`,
`Rotation`) are exactly the `tbp` package this file replaces.

## Why it is ours and not a copy

Monty's simulator is not a thin layer over a physics engine: it builds a scene
in a spec, compiles it, and drops every renderer when the model changes. Nothing
of that is worth keeping a copy of a whole framework for — and the copy went
stale the moment upstream moved. What is worth keeping is the *behaviour*, so
this file keeps it and answers in plain dicts, which is what the BEAM reads
anyway.

Three packages, and no fourth: `mujoco` for the scene and its images, `numpy`
for the arithmetic, `numpy-quaternion` for the `wxyz` rotations Monty's agent
state carries. `scipy` is gone with the copy — its `Rotation` is used here for
four operations, each of which is two lines of quaternion arithmetic.

## One thread, because a GL context is one thread's

A MuJoCo `Renderer` owns a GL context, and a GL context belongs to the thread
that created it. The BEAM runs successive `Pythonx.eval/2` calls on whichever
scheduler thread is free, so a renderer made during `reset` and used during
`step` is used from the wrong thread — which does not fail, it *blocks*, until
the caller's timeout. So every operation that touches the simulator runs on one
dedicated Python thread (`_on_one_thread`), and the caller waits for the answer.

## What crosses, and how

The BEAM sends JSON: a scene (`World(spec)`), then `reset()` and `step(actions)`
with Monty's action maps — `ActionJSONEncoder`'s `dict(action)`, one key per
parameter. Answers are JSON too, in Monty's own shapes: `wxyz` rotations, metres,
depth / `rgba` / `semantic` images per sensor, and each sensor's pose relative to
its agent.
"""

from __future__ import annotations

import json
import logging
import queue
import threading
from dataclasses import dataclass, fields
from json import JSONDecodeError
from pathlib import Path

import numpy as np
import quaternion as qt
from mujoco import (
    MjData,
    MjSpec,
    Renderer,
    mj_forward,
    mjtGeom,
    mjtJoint,
    mjtLightType,
    mjtTexture,
    mjtTextureRole,
)

logger = logging.getLogger(__name__)

HABITAT_SCALING_FACTOR = (0.1, 0.1, 0.1)
"""Scaling factor to make MuJoCo primitives roughly the same size as their
Habitat counterparts. Determined by trial and error, as in Monty."""

PRIMITIVE_OBJECTS = {
    "box": mjtGeom.mjGEOM_BOX,
    "capsule": mjtGeom.mjGEOM_CAPSULE,
    "cylinder": mjtGeom.mjGEOM_CYLINDER,
    "ellipsoid": mjtGeom.mjGEOM_ELLIPSOID,
    "sphere": mjtGeom.mjGEOM_SPHERE,
}
"""Map of names to MuJoCo primitive object types."""

HABITAT_PRIMITIVE_OBJECTS = {
    "capsule3DSolid": mjtGeom.mjGEOM_CAPSULE,
    "cubeSolid": mjtGeom.mjGEOM_BOX,
    "cylinderSolid": mjtGeom.mjGEOM_CYLINDER,
    # A sphere stands in for a cone, because MuJoCo has no cone primitive.
    "coneSolid": mjtGeom.mjGEOM_SPHERE,
}
"""Habitat's names for the same primitives, kept so a Habitat-era config still
names an object this world can add."""

DEFAULT_RESOLUTION_HEIGHT = 64
DEFAULT_RESOLUTION_WIDTH = 64
"""The off-screen buffer's size when there are no sensors to ask, e.g. in tests."""

IDENTITY_QUATERNION = (1.0, 0.0, 0.0, 0.0)
ONES_VECTOR = (1.0, 1.0, 1.0)
ZERO_VECTOR = (0.0, 0.0, 0.0)

DEFAULT_CAMERA_FOVH = 90.0
"""The horizontal field of view at zoom 1.0. It has to stay in sync with the
value in `DepthTo3DLocations`, which is the transform that undoes the projection."""


class UnknownObjectType(RuntimeError):
    """An unknown object type is requested."""


class MissingObjectModel(RuntimeError):
    """An object type is missing an object model file."""


class MissingObjectTexture(RuntimeError):
    """An object type is missing a texture file."""


class DataPathNotConfigured(RuntimeError):
    """The scene has no data path and a custom object is requested."""


class InvalidObjectMetadata(Exception):
    """The object metadata could not be decoded."""


class ActuateMethodMissing(RuntimeError):
    """The scene applied an action to an agent that lacks that actuate method."""

    def __init__(self, agent_class: type, method_name: str) -> None:
        super().__init__(f"{agent_class.__name__} does not understand '{method_name}'")
        self.agent_class = agent_class
        self.method_name = method_name


@dataclass
class ObjectMetadata:
    """The metadata a custom object is added with, from its `metadata.json`."""

    refpos: tuple = ZERO_VECTOR
    """Reference position the vertex coordinates are defined against; subtracted."""

    refquat: tuple = IDENTITY_QUATERNION
    """Reference orientation, `wxyz`, the conjugate of which rotates the vertices."""

    scale: tuple = ONES_VECTOR
    """Scaling factor in each direction."""


def load_object_metadata(path: Path, object_type: str) -> ObjectMetadata:
    """Reads an object's `metadata.json`, refusing keys nobody knows.

    A typo in a field name would otherwise be a silently ignored setting, so an
    extra key is an error rather than a default.
    """
    try:
        decoded = json.loads(path.read_text())
    except JSONDecodeError as error:
        raise InvalidObjectMetadata(f"Couldn't decode '{object_type}' metadata.") from error

    expected = {field.name for field in fields(ObjectMetadata)}
    extra = set(decoded) - expected
    if extra:
        raise InvalidObjectMetadata(
            f"Object '{object_type}' metadata has extra fields: {extra}"
        )

    return ObjectMetadata(**decoded)


def zoom_fovy(base_fovh: float, height: int, width: int, zoom: float) -> float:
    """The vertical field of view for a zoom level, in degrees.

    MuJoCo only lets a camera state its *vertical* field of view while
    `DepthTo3DLocations` works in horizontal ones, so this is the conversion the
    two have to agree on.
    """
    ratio = height / width
    base = np.deg2rad(base_fovh)
    return float(np.rad2deg(2 * np.arctan2(ratio * np.tan(base / 2.0), zoom)))


def about_x(degrees: float) -> np.quaternion:
    """A rotation of `degrees` about the x axis, anticlockwise."""
    return qt.from_rotation_vector(np.array([np.deg2rad(degrees), 0.0, 0.0]))


def about_y(degrees: float) -> np.quaternion:
    """A rotation of `degrees` about the y axis, anticlockwise."""
    return qt.from_rotation_vector(np.array([0.0, np.deg2rad(degrees), 0.0]))


def as_euler_xyz(rotation: np.quaternion) -> tuple:
    """`(x, y, z)` radians of the decomposition `R = Rz(z) · Ry(y) · Rx(x)`.

    This is scipy's `Rotation.as_euler("xyz")`, which is what Monty reads a
    sensor's pitch off. Only the x angle is ever used, but the decomposition is
    the whole answer and costs one `atan2` more.
    """
    matrix = qt.as_rotation_matrix(rotation)
    y = np.arcsin(np.clip(-matrix[2][0], -1.0, 1.0))
    x = np.arctan2(matrix[2][1], matrix[2][2])
    z = np.arctan2(matrix[1][0], matrix[0][0])
    return float(x), float(y), float(z)


class Axis:
    """Axes for local movement. Values are indices into a rotation matrix."""

    X = 0
    Y = 1
    Z = 2


class SensorConfig:
    """One sensor's camera: where it sits on the agent, and what it renders."""

    __slots__ = ("height", "width", "zoom", "position", "rotation", "semantic")

    def __init__(self, config: dict) -> None:
        self.height = int(config.get("height", DEFAULT_RESOLUTION_HEIGHT))
        self.width = int(config.get("width", DEFAULT_RESOLUTION_WIDTH))
        self.zoom = float(config.get("zoom", 1.0))
        self.position = _vector(config.get("position") or ZERO_VECTOR)
        self.rotation = _quaternion(config.get("rotation") or IDENTITY_QUATERNION)
        # Monty asks for the semantic image whenever the sensor's config says so;
        # the port asks for it on every sensor, because `on_object` is read from
        # it (`Setup.sensor_specs/1`).
        self.semantic = bool(config.get("semantic", False))


def _vector(values) -> tuple:
    x, y, z = values
    return (float(x), float(y), float(z))


def _quaternion(values) -> tuple:
    w, x, y, z = values
    return (float(w), float(x), float(y), float(z))


class Action:
    """One action as the BEAM sends it: Monty's `dict(action)`.

    Its name is Monty's `name()` — `move_forward`, `orient_horizontal` — and
    every other key is a parameter of that action's class, so this is what
    `action.distance` reads in the `actuate_*` methods below.
    """

    def __init__(self, data: dict) -> None:
        self.name = data["action"]
        self.agent_id = data.get("agent_id")
        self.__dict__.update({key: value for key, value in data.items() if key != "action"})


class Embodiment:
    """A body inside the simulator, with the sensors hanging off it.

    This positions the cameras, moves the body and the sensor head, and answers
    what they saw and where they are — which is the whole of what an agent needs
    from a world.
    """

    def __init__(
        self,
        simulator: "MuJoCoSimulator",
        agent_id: str,
        sensor_configs: dict,
        position: tuple = ZERO_VECTOR,
        rotation: tuple = IDENTITY_QUATERNION,
    ) -> None:
        self.id = agent_id
        self.sim = simulator

        self._initial_position = position
        self._initial_rotation = rotation
        self._sensor_configs = sensor_configs

        agent_body = self.sim.spec.worldbody.add_body(
            name=agent_id,
            pos=position,
            quat=rotation,
            # Needed to use joints.
            mass=1.0,
            inertia=(1.0, 1.0, 1.0),
        )
        self.agent_joint = agent_body.add_freejoint()

        self.sensor_body_id = f"{agent_id}.sensor"
        sensor_body = agent_body.add_body(
            name=self.sensor_body_id,
            pos=ZERO_VECTOR,
            quat=IDENTITY_QUATERNION,
            mass=1.0,
            inertia=(1.0, 1.0, 1.0),
        )
        self.pitch_joint = sensor_body.add_joint(type=mjtJoint.mjJNT_HINGE, axis=(1, 0, 0))

        for sensor_id, sensor_config in self._sensor_configs.items():
            sensor_body.add_camera(
                name=f"{self.id}.{sensor_id}",
                pos=sensor_config.position,
                quat=sensor_config.rotation,
                # A camera's resolution is not MuJoCo's business — the renderer's
                # is — so only the field of view is set from it.
                fovy=zoom_fovy(
                    DEFAULT_CAMERA_FOVH, sensor_config.height, sensor_config.width, sensor_config.zoom
                ),
            )

    @property
    def position(self) -> tuple:
        # `sim.model` is replaced whenever the spec is recompiled, e.g. after an
        # object is added, so the joint's address is looked up every time.
        address = self.sim.model.jnt_qposadr[self.agent_joint.id]
        return tuple(float(value) for value in self.sim.data.qpos[address : address + 3])

    @position.setter
    def position(self, position) -> None:
        address = self.sim.model.jnt_qposadr[self.agent_joint.id]
        self.sim.data.qpos[address : address + 3] = np.array(position)

    @property
    def rotation(self) -> tuple:
        address = self.sim.model.jnt_qposadr[self.agent_joint.id]
        return tuple(float(value) for value in self.sim.data.qpos[address + 3 : address + 7])

    @rotation.setter
    def rotation(self, rotation) -> None:
        address = self.sim.model.jnt_qposadr[self.agent_joint.id]
        self.sim.data.qpos[address + 3 : address + 7] = np.array(rotation)

    @property
    def _sensor_pitch(self) -> float:
        address = self.sim.model.jnt_qposadr[self.pitch_joint.id]
        return float(np.rad2deg(self.sim.data.qpos[address]))

    @_sensor_pitch.setter
    def _sensor_pitch(self, pitch_degrees: float) -> None:
        address = self.sim.model.jnt_qposadr[self.pitch_joint.id]
        self.sim.data.qpos[address] = np.deg2rad(pitch_degrees)

    def observations(self, only=None) -> dict:
        """What each sensor saw: depth, `rgba`, and the semantic ids if asked.

        `only` names the sensors to render. A positioning step reads one of them,
        and rendering the other cost half of every one of its seventeen world
        steps: three MuJoCo renders, a 132 kB crossing and a decode, thrown away.
        `None` — what a model's step asks for — renders every sensor in the scene.
        """
        observations = {}
        for sensor_id, sensor_config in self._sensor_configs.items():
            if only is not None and sensor_id not in only:
                continue
            renderer = self.sim.renderer_for_res(sensor_config.height, sensor_config.width)
            renderer.update_scene(self.sim.data, camera=f"{self.id}.{sensor_id}")

            # MuJoCo renders RGB only and Monty expects RGBA, so the alpha channel
            # is added here: a camera always returns opaque pixels.
            rgb = _render(renderer)
            alpha = np.full(rgb.shape[:2], 255, dtype=rgb.dtype)
            rgba = np.dstack([rgb, alpha])

            renderer.enable_depth_rendering()
            depth = _render(renderer)
            renderer.disable_depth_rendering()

            if not sensor_config.semantic:
                observations[sensor_id] = {"depth": depth, "rgba": rgba}
                continue

            renderer.enable_segmentation_rendering()
            segmentation = _render(renderer)
            renderer.disable_segmentation_rendering()

            # Segmentation answers `(object_id, object_type)` per pixel; only the
            # id matters, and it becomes the semantic id the object was added with.
            observations[sensor_id] = {
                "depth": depth,
                "rgba": rgba,
                "semantic": self._semantic_ids(segmentation[:, :, 0]),
            }
        return observations

    def _semantic_ids(self, object_ids: np.ndarray) -> np.ndarray:
        """The id each pixel was added with, for the ids the scene mapped.

        One masked assignment per mapped id, where `np.vectorize` called back
        into Python once per pixel: 0.24 ms a frame became 0.06 ms on the same
        array. The comparison is against `object_ids`, the array as the renderer
        answered it, so a pixel is remapped once — which is what
        `mapping.get(object_id, object_id)` says — and an id the scene never
        mapped keeps its own.
        """
        mapping = self.sim.id_to_semantic_id
        if not mapping:
            return object_ids

        semantic = object_ids.copy()
        for object_id, semantic_id in mapping.items():
            semantic[object_ids == object_id] = semantic_id
        return semantic

    @property
    def state(self) -> dict:
        """Where the agent is, and where each sensor sits relative to it."""
        # The sensor body's pose comes back in world coordinates; what a model
        # reads is the head's rotation relative to the body, because that is what
        # the action vocabulary moves.
        sensor_body_rotation = qt.quaternion(*self.sim.data.body(self.sensor_body_id).xquat)
        relative = qt.quaternion(*self.rotation).inverse() * sensor_body_rotation

        sensors = {}
        for sensor_id, sensor_config in self._sensor_configs.items():
            # This assumes a sensor's pose relative to the agent cannot change,
            # which is Monty's assumption and this scene's design: only the head's
            # pitch moves.
            position = qt.rotate_vectors(relative, np.array(sensor_config.position))
            sensors[sensor_id] = {
                "position": [float(value) for value in position],
                "rotation": _quaternion_list(relative),
            }

        return {
            "position": list(self.position),
            "rotation": list(self.rotation),
            "sensors": sensors,
        }

    def reset(self) -> None:
        self.position = self._initial_position
        self.rotation = self._initial_rotation
        self.set_sensor_rotation(IDENTITY_QUATERNION)

    def move_along_local_axis(self, distance: float, axis: int) -> None:
        """Moves the embodiment along an axis of its own basis."""
        rotation = qt.quaternion(*self.rotation)
        direction = qt.as_rotation_matrix(rotation)[:, axis] * distance
        self.position = np.array(self.position) + direction

    def yaw(self, delta_theta: float) -> None:
        """Yaws the embodiment, in degrees, anticlockwise positive."""
        self.rotation = _quaternion_list(qt.quaternion(*self.rotation) * about_y(delta_theta))

    def pitch(self, delta_phi: float) -> None:
        """Pitches the embodiment, in degrees."""
        self.rotation = _quaternion_list(qt.quaternion(*self.rotation) * about_x(delta_phi))

    def pitch_sensor(self, delta_phi: float, constraint: float | None) -> None:
        """Pitches the sensor head, without turning the embodiment."""
        if constraint is not None:
            # Clamped rather than refused: an action may only take the head as far
            # as the constraint allows, which keeps the head inside its range.
            new_pitch = self._sensor_pitch + delta_phi
            if new_pitch > constraint:
                delta_phi = constraint - self._sensor_pitch
            elif new_pitch < -constraint:
                delta_phi = -constraint - self._sensor_pitch

        self._sensor_pitch = self._sensor_pitch + delta_phi

    def set_pose(self, location, rotation) -> None:
        """Sets the embodiment's location and orientation outright."""
        self.position = location
        self.rotation = rotation

    def set_sensor_rotation(self, rotation_quat) -> None:
        """Sets the sensor head's pitch from a rotation, keeping its x axis only.

        A full quaternion is accepted but only its x angle survives: the head is a
        hinge, so it can pitch and nothing else.
        """
        angles = as_euler_xyz(qt.quaternion(*rotation_quat))
        address = self.sim.model.jnt_qposadr[self.pitch_joint.id]
        self.sim.data.qpos[address] = angles[0]


class NoopAgent:
    """An agent that responds to no action at all.

    It has no `actuate_*` method, which is the point: the simulator reports the
    missing method and carries on.
    """

    def __init__(self, simulator, agent_id, sensor_configs, position=ZERO_VECTOR, rotation=IDENTITY_QUATERNION):
        self._embodiment = Embodiment(simulator, agent_id, sensor_configs, position, rotation)
        self.id = agent_id

    @property
    def state(self) -> dict:
        return self._embodiment.state

    def observations(self, only=None) -> dict:
        """What each sensor saw, rendering only `only` when one is named."""
        return self._embodiment.observations(only)

    def reset(self) -> None:
        self._embodiment.reset()

    def __repr__(self) -> str:
        return f"{self.__class__.__name__}(id={self.id})"


class DistantAgent:
    """A multi-sensor agent that looks at objects from a distance."""

    def __init__(self, simulator, agent_id, sensor_configs, position=ZERO_VECTOR, rotation=IDENTITY_QUATERNION):
        self._embodiment = Embodiment(simulator, agent_id, sensor_configs, position, rotation)
        self.id = agent_id

    @property
    def state(self) -> dict:
        return self._embodiment.state

    def observations(self, only=None) -> dict:
        """What each sensor saw, rendering only `only` when one is named."""
        return self._embodiment.observations(only)

    def reset(self) -> None:
        self._embodiment.reset()

    def __repr__(self) -> str:
        return f"{self.__class__.__name__}(id={self.id})"

    def actuate_set_agent_pose(self, action: Action) -> None:
        """Sets the agent's position and orientation outright."""
        self._embodiment.set_pose(action.location, action.rotation_quat)

    def actuate_set_sensor_rotation(self, action: Action) -> None:
        """Sets the sensor head's pitch outright."""
        self._embodiment.set_sensor_rotation(action.rotation_quat)

    def actuate_move_forward(self, action: Action) -> None:
        """Moves along the agent's own z axis; a negative distance goes back."""
        # "Forward" is negative z, so the distance is negated.
        self._embodiment.move_along_local_axis(-action.distance, axis=Axis.Z)

    def actuate_turn_right(self, action: Action) -> None:
        """Yaws right; a negative angle turns left."""
        # Yaw is anticlockwise positive, so a right turn is a negation.
        self._embodiment.yaw(-action.rotation_degrees)

    def actuate_turn_left(self, action: Action) -> None:
        """Yaws left; a negative angle turns right."""
        self._embodiment.yaw(action.rotation_degrees)

    def actuate_look_up(self, action: Action) -> None:
        """Pitches the sensors up; a negative angle pitches them down."""
        self._embodiment.pitch_sensor(action.rotation_degrees, action.constraint_degrees)

    def actuate_look_down(self, action: Action) -> None:
        """Pitches the sensors down; a negative angle pitches them up."""
        self._embodiment.pitch_sensor(-action.rotation_degrees, action.constraint_degrees)


class SurfaceAgent:
    """A multi-sensor agent that senses a surface it is standing on."""

    def __init__(self, simulator, agent_id, sensor_configs, position=ZERO_VECTOR, rotation=IDENTITY_QUATERNION):
        self._embodiment = Embodiment(simulator, agent_id, sensor_configs, position, rotation)
        self.id = agent_id

    @property
    def state(self) -> dict:
        return self._embodiment.state

    def observations(self, only=None) -> dict:
        """What each sensor saw, rendering only `only` when one is named."""
        return self._embodiment.observations(only)

    def reset(self) -> None:
        self._embodiment.reset()

    def __repr__(self) -> str:
        return f"{self.__class__.__name__}(id={self.id})"

    def actuate_move_forward(self, action: Action) -> None:
        """Moves along the agent's own z axis; a negative distance goes back."""
        self._embodiment.move_along_local_axis(-action.distance, axis=Axis.Z)

    def actuate_orient_horizontal(self, action: Action) -> None:
        """Orbits the object horizontally, then faces where the policy aimed.

        The distances are assumed to have been calculated to orbit the object,
        which is the surface policy's job, not this one's.
        """
        self._embodiment.move_along_local_axis(-action.left_distance, axis=Axis.X)
        # The action's angles are clockwise and yaw is anticlockwise.
        self._embodiment.yaw(-action.rotation_degrees)
        self._embodiment.move_along_local_axis(-action.forward_distance, axis=Axis.Z)

    def actuate_orient_vertical(self, action: Action) -> None:
        """Orbits the object vertically, then faces where the policy aimed."""
        self._embodiment.move_along_local_axis(-action.down_distance, axis=Axis.Y)
        self._embodiment.pitch(action.rotation_degrees)
        self._embodiment.move_along_local_axis(-action.forward_distance, axis=Axis.Z)

    def actuate_move_tangentially(self, action: Action) -> None:
        """Moves along a world-space direction tangential to the agent's facing.

        The direction is a unit vector already rotated by the policy, which the
        surface policies do — so it is not rotated again here.
        """
        if action.distance == 0.0:
            return
        direction = np.array(action.direction)
        self._embodiment.position = np.array(self._embodiment.position) + direction * action.distance

    def actuate_set_agent_pose(self, action: Action) -> None:
        """Sets the agent's position and orientation outright."""
        self._embodiment.set_pose(action.location, action.rotation_quat)

    def actuate_set_sensor_rotation(self, action: Action) -> None:
        """Sets the sensor head's pitch outright."""
        self._embodiment.set_sensor_rotation(action.rotation_quat)


AGENTS = {
    "NoopAgent": NoopAgent,
    "DistantAgent": DistantAgent,
    "SurfaceAgent": SurfaceAgent,
}
"""The agent classes a config may name, by Monty's name for each."""


class MuJoCoSimulator:
    """The scene, its model and its data — Monty's `MuJoCoSimulator`.

    MuJoCo's data model is three parts: a spec that describes a scene, a model
    compiled from it, and the data that is the simulation's state. Because the
    spec can be edited, it is kept and recompiled whenever an object is added —
    and every renderer is dropped with it, because a renderer belongs to a model.
    """

    def __init__(self, agents: list, data_path=None, raise_actuate_missing: bool = True) -> None:
        """Builds the scene from the agents it will hold.

        `agents` is a list of `(class name, agent id, sensor configs, position,
        rotation)` — Monty's partially applied Hydra constructors, as data.
        """
        self.spec = MjSpec()
        self.model = self.spec.compile()
        self.data = MjData(self.model)
        self.id_to_semantic_id = self._default_id_mapping()

        self._data_path = Path(data_path) if data_path else None
        self._loaded_custom_types = {}
        self._raise_actuate_missing = raise_actuate_missing
        self._renderers = {}
        self._agent_specs = agents
        self._agents = {}

        # Gives each added object a unique name in the scene.
        self._object_count = 0

        self._initialize_new_spec()
        self._recompile()

    def _recompile(self) -> None:
        """Recompiles the model, keeping its state, and drops the renderers."""
        self.model, self.data = self.spec.recompile(self.model, self.data)
        self._close_renderers()
        # So every object starts where it was put, rather than where the last
        # step left it.
        mj_forward(self.model, self.data)

    def _initialize_new_spec(self) -> None:
        """Sets the scene's global settings, its lights and its agents."""
        self._configure_spec_settings()
        self._configure_lights()
        self._create_agents()

    def _configure_spec_settings(self) -> None:
        """Sets the spec's global options."""
        self.spec.option.gravity = (0.0, 0.0, 0.0)

        # The off-screen buffer is as large as the largest sensor, so every
        # sensor's image fits in it. Without agents there is nothing to ask, and
        # a default keeps the buffer renderable.
        height, width = DEFAULT_RESOLUTION_HEIGHT, DEFAULT_RESOLUTION_WIDTH
        if self._agent_specs:
            height, width = self._max_sensor_resolution()

        visual = self.spec.visual.global_
        visual.offheight = height
        visual.offwidth = width

        # Habitat used znear 0.01 and zfar 1000. MuJoCo multiplies both by an
        # `extent` that defaults to 2, and matching Habitat's numbers through it
        # loses depth accuracy — so the mapping's values are set to what gives
        # Habitat's *result*, which also avoids near clipping at a 0.01 znear.
        self.spec.visual.map.znear = 0.005
        self.spec.visual.map.zfar = 500.0

    def _configure_lights(self) -> None:
        """Recreates the lighting Habitat gave us: front-lit, ambient behind."""
        # The headlight provides the ambient light on the object's back side; a
        # separate fixed ambient light does not give good results there, but on
        # the headlight it does.
        headlight = self.spec.visual.headlight
        headlight.ambient = (0.5, 0.5, 0.5)
        headlight.diffuse = (0.0, 0.0, 0.0)
        headlight.specular = (0.0, 0.0, 0.0)

        self.spec.worldbody.add_light(
            pos=(0.0, 0.0, 0.2),
            diffuse=(0.6, 0.6, 0.6),
            specular=(0.1, 0.1, 0.1),
            type=mjtLightType.mjLIGHT_DIRECTIONAL,
        )

    def renderer_for_res(self, height: int, width: int) -> Renderer:
        """The renderer of that resolution, made once and kept.

        A camera's resolution is not MuJoCo's, so a sensor asks for a renderer of
        the size its config names; two sensors of one size share it.
        """
        key = (height, width)
        if key not in self._renderers:
            self._renderers[key] = Renderer(height=height, width=width, model=self.model)
        return self._renderers[key]

    def _create_agents(self) -> None:
        self._agents = {}
        for agent_spec in self._agent_specs:
            agent = AGENTS[agent_spec["class"]](self, *agent_spec["arguments"])
            self._agents[agent.id] = agent

    def _max_sensor_resolution(self) -> tuple:
        """The largest height and width any sensor asks for.

        The two may come from different sensors: the buffer only has to be big
        enough for one image at a time.
        """
        height = width = 0
        for agent_spec in self._agent_specs:
            for sensor_config in agent_spec["arguments"][1].values():
                height = max(height, sensor_config.height)
                width = max(width, sensor_config.width)
        return height, width

    def remove_all_objects(self) -> None:
        self.spec = MjSpec()
        self._initialize_new_spec()
        self._recompile()
        self.id_to_semantic_id = self._default_id_mapping()
        self._object_count = 0
        self._loaded_custom_types = {}

    def add_object(
        self,
        name: str,
        position: tuple = ZERO_VECTOR,
        rotation: tuple = IDENTITY_QUATERNION,
        scale: tuple = ONES_VECTOR,
        semantic_id: int | None = None,
    ) -> dict:
        """Adds an object to the scene and answers its ids.

        A primitive is a MuJoCo geom and a custom object is a mesh with its
        texture; either way the object is named after the name it was asked for
        and a counter, so the same object can be added twice.
        """
        object_name = f"{name}_{self._object_count}"

        if name in PRIMITIVE_OBJECTS:
            self._add_primitive_object(object_name, name, position, rotation, scale)
        elif name in HABITAT_PRIMITIVE_OBJECTS:
            # Habitat's primitives are much smaller than MuJoCo's, so the default
            # scale has to be adjusted.
            scaled = tuple(scale[i] * HABITAT_SCALING_FACTOR[i] for i in range(3))
            self._add_primitive_object(object_name, name, position, rotation, scaled)
        else:
            self._add_custom_object(object_name, name, position, rotation, scale)

        self._recompile()
        self._object_count += 1

        added = self.model.geom(object_name)
        # MuJoCo answers an accessor over the model's arrays; `type` is a
        # single-element array, so its first element is the geom's type.
        if semantic_id is None:
            semantic_id = int(added.type[0])

        object_id = int(added.id)
        self.id_to_semantic_id[object_id] = semantic_id

        return {"object_id": object_id, "semantic_id": semantic_id}

    def _add_custom_object(self, object_name, object_type, position, rotation, scale) -> None:
        """Adds a mesh from the data path, with its texture and metadata.

        Each object's files are in a directory named after its type: the model in
        `textured.obj`, the texture in `texture_map.png`, and an optional
        `metadata.json` with the reference pose and scale.
        """
        object_key = (object_type, scale)
        if object_key not in self._loaded_custom_types:
            self._load_custom_object(object_key)

        metadata = self._loaded_custom_types[object_key]
        self.spec.worldbody.add_geom(
            name=object_name,
            type=mjtGeom.mjGEOM_MESH,
            meshname=metadata["mesh_name"],
            material=metadata["material_name"],
            pos=position,
            quat=rotation,
        )

    def _load_custom_object(self, object_key) -> None:
        """Loads one custom object's mesh, texture and material into the spec.

        Done once per object type and scale: MuJoCo stores the scale on the mesh
        and not on the geom, so two scales are two meshes.
        """
        object_type, scale = object_key

        if not self._data_path:
            raise DataPathNotConfigured(
                "Cannot load custom objects in simulator, 'data_path' is not configured."
            )

        path = self._data_path / object_type
        texture_path = path / "texture_map.png"
        model_path = path / "textured.obj"
        metadata_path = path / "metadata.json"

        if not path.exists():
            raise UnknownObjectType(f"Unknown object type: {object_type}")
        if not texture_path.exists():
            raise MissingObjectTexture(f"The {object_type} is missing 'texture_map.png'.")
        if not model_path.exists():
            raise MissingObjectModel(f"The {object_type} is missing 'textured.obj'.")

        metadata = load_object_metadata(metadata_path, object_type) if metadata_path.exists() else ObjectMetadata()
        base = f"{object_type}_{scale[0]}_{scale[1]}_{scale[2]}"

        # MuJoCo cannot load the texture referenced by the `.obj`, so it is added
        # separately and reached through a material the mesh is drawn with.
        texture_name = f"{base}_tex"
        self.spec.add_texture(name=texture_name, type=mjtTexture.mjTEXTURE_2D, file=str(texture_path))

        material_name = f"{base}_mat"
        material = self.spec.add_material(name=material_name)
        material.textures[mjtTextureRole.mjTEXROLE_RGB] = texture_name

        scale_in_metadata = (
            scale[0] * metadata.scale[0],
            scale[1] * metadata.scale[1],
            scale[2] * metadata.scale[2],
        )

        mesh_name = f"{base}_mesh"
        self.spec.add_mesh(
            name=mesh_name,
            file=str(model_path),
            refquat=metadata.refquat,
            refpos=metadata.refpos,
            scale=scale_in_metadata,
        )

        self._loaded_custom_types[object_key] = {
            "mesh_name": mesh_name,
            "material_name": material_name,
        }

    def _add_primitive_object(self, object_name, object_type, position, rotation, scale) -> None:
        """Adds a built-in MuJoCo geom."""
        # Habitat's capsule lies along the vertical y axis while MuJoCo's points
        # along z, so every primitive is corrected by the same -90° about x. The
        # correction is Monty's for all of them, not only the capsule.
        rotation_quat = _quaternion_list(qt.quaternion(*rotation) * about_x(-90))

        geom_type = PRIMITIVE_OBJECTS.get(object_type) or HABITAT_PRIMITIVE_OBJECTS[object_type]

        if geom_type == mjtGeom.mjGEOM_CAPSULE:
            # A capsule uses only the first two scale parts, for the end spheres'
            # radius and the cylinder's half-length; 0.75 matches Habitat.
            scale = (scale[0], scale[1] * 0.75, scale[2])

        self.spec.worldbody.add_geom(
            name=object_name,
            type=geom_type,
            size=scale,
            pos=position,
            quat=rotation_quat,
        )

    def observations(self, only=None) -> dict:
        """What every agent's sensors saw, rendering only `only` when named."""
        return {agent.id: agent.observations(only) for agent in self._agents.values()}

    @property
    def states(self) -> dict:
        return {agent.id: agent.state for agent in self._agents.values()}

    def step(self, actions, only=None) -> tuple:
        """Applies `actions`, then answers what the sensors see afterwards."""
        for action in actions:
            agent = self._agents[action.agent_id]
            method = getattr(agent, f"actuate_{action.name}", None)

            if method is None:
                if self._raise_actuate_missing:
                    raise ActuateMethodMissing(type(agent), f"actuate_{action.name}")
                # A world that refuses an action it has no method for is a world
                # that stops; Monty reports and carries on, and so does this.
                logger.warning("%r does not understand actuate_%s", agent, action.name)
                continue

            method(action)

        mj_forward(self.model, self.data)
        return self.observations(only), self.states

    def reset(self) -> tuple:
        """Puts every agent back where it started, then looks again."""
        for agent in self._agents.values():
            agent.reset()
        mj_forward(self.model, self.data)
        return self.observations(), self.states

    def close(self) -> None:
        self._close_renderers()

    def _close_renderers(self) -> None:
        for renderer in self._renderers.values():
            # `Renderer.close` frees GL objects, and those belong to whichever
            # context is current — not necessarily this renderer's. Closing a
            # world while another was mid-run deleted the *other* world's
            # framebuffer, and its next two segmentation passes read rubbish
            # (`IndexError: index 399387 is out of bounds for axis 0 with size 2`).
            context = getattr(renderer, "_gl_context", None)
            if context is not None:
                context.make_current()
            renderer.close()
        self._renderers = {}

    @staticmethod
    def _default_id_mapping() -> dict:
        """The background, which Habitat calls 0 and MuJoCo calls -1."""
        return {-1: 0}


def _render(renderer: Renderer):
    """One frame, through this renderer's own GL context.

    MuJoCo makes a renderer's context current when it is built and never again,
    so a process with two worlds renders both through whichever context was built
    last: the read-back pixels belong to the other world — the segmentation pass
    came back as the RGB image, whose bytes read as ids, and
    `IndexError: index 399387 is out of bounds for axis 0 with size 2` is what a
    run of four parts died of as soon as one part finished and freed the context
    that was current.

    `Renderer` takes no context argument and exposes no `make_current`, so the
    call goes to the context it created; it is what MuJoCo's own `__init__` does.
    """
    context = getattr(renderer, "_gl_context", None)
    if context is not None:
        context.make_current()

    return renderer.render()


def _quaternion_list(rotation: np.quaternion) -> list:
    """A `wxyz` quaternion as the list JSON carries."""
    return [float(rotation.w), float(rotation.x), float(rotation.y), float(rotation.z)]


def _json_default(value):
    """The one thing `json` cannot carry by itself: an array.

    Handed to `json.dumps` rather than walked beforehand: `ndarray.tolist()` is
    where the conversion happens (in C, once per image) instead of a
    walk over fifty thousand Python objects per step.

    Only the spec that comes *in* takes this path: an answer's arrays travel as
    bytes (`_answer`), never as JSON.
    """
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.integer):
        return int(value)
    if isinstance(value, np.floating):
        return float(value)
    raise TypeError(f"{type(value).__name__} does not cross as JSON")


_ARRAY = "__array__"


def _answer(payload) -> bytes:
    """An answer, as the BEAM reads it: a JSON header, then the arrays' bytes.

    Everything in an answer is small enough for JSON except what the sensors
    saw: two 64×64 images and their semantic mask. Written out as nested lists
    they were a megabyte of decimal text a step — built by `json.dumps` in
    Python and parsed again by `Jason` in Elixir, to arrive at the same numbers.

    So each array is replaced by its index and its bytes follow the header, in
    the order the header names them. `Elixir.Monty.Simulators.Mujoco.Answer`
    puts them back; nothing downstream of it sees a difference.
    """
    arrays: list[np.ndarray] = []

    def replaced(value):
        if isinstance(value, np.ndarray):
            arrays.append(value)
            return {_ARRAY: len(arrays) - 1}
        if isinstance(value, dict):
            return {key: replaced(item) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [replaced(item) for item in value]
        if isinstance(value, np.integer):
            return int(value)
        if isinstance(value, np.floating):
            return float(value)
        if isinstance(value, np.bool_):
            return bool(value)
        return value

    body = replaced(payload)
    header = json.dumps(
        {
            "payload": body,
            "arrays": [
                {"dtype": array.dtype.str, "shape": list(array.shape)}
                for array in arrays
            ],
        }
    ).encode("utf-8")

    # C order, which is the order `tolist()` would have nested them in.
    blob = b"".join(np.ascontiguousarray(array).tobytes() for array in arrays)

    return header + b"\n" + blob


# -- one thread, because a GL context is one thread's ------------------------

_JOBS: queue.Queue = queue.Queue()
_WORKER: threading.Thread | None = None
_WORKER_LOCK = threading.Lock()


def _worker_loop() -> None:
    while True:
        job, done = _JOBS.get()
        try:
            done["result"] = job()
        except BaseException as error:  # noqa: BLE001 - re-raised in the caller
            done["error"] = error
        finally:
            done["event"].set()


def _ensure_worker() -> None:
    global _WORKER
    with _WORKER_LOCK:
        if _WORKER is None or not _WORKER.is_alive():
            _WORKER = threading.Thread(target=_worker_loop, name="monty-mujoco", daemon=True)
            _WORKER.start()


def _on_one_thread(function):
    """Runs `function` on the one thread that owns this process's GL context."""
    if threading.current_thread() is _WORKER:
        return function()

    _ensure_worker()
    done = {"event": threading.Event(), "result": None, "error": None}
    _JOBS.put((function, done))
    done["event"].wait()

    if done["error"] is not None:
        raise done["error"]
    return done["result"]


# -- the world, as the BEAM sees it -----------------------------------------


class World:
    """One scene, built from the JSON an experiment's config names.

    `spec` is the scene: the path the meshes load from, the agents that live in
    it and the objects that are in it. `reset/0` and `step/1` answer a JSON
    header with the arrays' bytes behind it (`_answer`), which is what the BEAM
    reads back.
    """

    def __init__(self, spec) -> None:
        config = json.loads(spec) if isinstance(spec, (str, bytes)) else spec
        self._objects = []
        self._simulator = _on_one_thread(lambda: self._build(config))

    def _build(self, config: dict) -> MuJoCoSimulator:
        simulator = MuJoCoSimulator(
            agents=[_agent_spec(agent) for agent in config.get("agents") or []],
            data_path=config.get("data_path"),
            raise_actuate_missing=bool(config.get("raise_actuate_missing", False)),
        )

        for index, obj in enumerate(config.get("objects") or []):
            position = _vector(obj.get("position") or ZERO_VECTOR)
            rotation = _quaternion(obj.get("rotation") or IDENTITY_QUATERNION)
            scale = _vector(obj.get("scale") or ONES_VECTOR)
            # Monty's interface numbers a scene's objects from one, so that an
            # on-object id is never the background's zero.
            semantic_id = obj.get("semantic_id", index + 1)
            added = simulator.add_object(
                name=obj["name"],
                position=position,
                rotation=rotation,
                scale=scale,
                semantic_id=semantic_id,
            )
            # Monty's `primary_target` is `PrimaryTarget` — `object_name`,
            # `semantic_id`, and every parameter the object init sampler produced —
            # (`experiment/primary_target.py`): the supervision a pretraining
            # experiment states reads `euler_rotation` and `quat_rotation` off it.
            self._objects.append(
                {
                    "object_name": obj["name"],
                    "semantic_id": added["semantic_id"],
                    "position": list(position),
                    "rotation": list(rotation),
                    "scale": list(scale),
                    **{
                        key: obj[key]
                        for key in ("euler_rotation", "quat_rotation")
                        if key in obj
                    },
                }
            )

        return simulator

    def reset(self) -> bytes:
        """Starts an episode: every agent back at its start pose."""
        return _on_one_thread(self._reset)

    def _reset(self) -> bytes:
        observations, states = self._simulator.reset()
        return _answer(
            {
                "observations": observations,
                "proprioceptive_state": states,
                "primary_target": self._objects[0] if self._objects else None,
                "semantic_id_to_label": {
                    obj["semantic_id"]: obj["object_name"] for obj in self._objects
                },
            }
        )

    def step(self, actions, sensors=None) -> bytes:
        """Takes the actions the model chose, and answers what came back.

        `sensors` is the JSON the BEAM sent: `null` to render every sensor, or a
        list naming the ones this step's transforms will read.
        """
        return _on_one_thread(lambda: self._step(actions, sensors))

    def _step(self, actions, sensors) -> bytes:
        # Monty's `ActionJSONDecoder` decoded one action, which is why the glue
        # used to decode a list one element at a time. These are our own actions,
        # so the list is decoded once.
        decoded = [Action(action) for action in json.loads(actions)]
        only = json.loads(sensors) if sensors else None
        observations, states = self._simulator.step(decoded, only)
        return _answer({"observations": observations, "proprioceptive_state": states})

    def close(self) -> None:
        _on_one_thread(self._simulator.close)


def _agent_spec(agent: dict) -> dict:
    """One agent, as `MuJoCoSimulator` builds it: its class and its arguments."""
    sensor_configs = {
        sensor_id: SensorConfig(config)
        for sensor_id, config in (agent.get("sensor_configs") or {}).items()
    }

    return {
        "class": agent.get("class") or "SurfaceAgent",
        "arguments": (
            agent.get("agent_id") or "agent_id_0",
            sensor_configs,
            _vector(agent.get("position") or ZERO_VECTOR),
            _quaternion(agent.get("rotation") or IDENTITY_QUATERNION),
        ),
    }
