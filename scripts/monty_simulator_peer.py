#!/usr/bin/env python3
"""Monty's own simulator, on the other side of `Monty.Simulators.Port`.

The port's world is Python: `HabitatEnvironment` builds the scene, the
environment interface applies the experiment's transforms, and what comes back
is the observation map a sensor module reads. This is that, speaking the
protocol in `Monty.Simulators.Port.Protocol` — length-prefixed JSON on stdin and
stdout — so the Elixir side can run a Monty experiment against the world the
experiment actually names instead of a stand-in.

It is not part of the port: it runs Monty, in Monty's environment, and the only
thing it knows about Elixir is the framing.

    MONTY=/path/to/monty-orig
    PYTHONPATH="$MONTY/src" \\
        "$CONDA_PREFIX/bin/python" scripts/monty_simulator_peer.py \\
        --experiment base_config_10distinctobj_dist_agent

    # what Monty answers, without the pipe:
    ... --experiment base_config_10distinctobj_dist_agent --self-test

Two things this deliberately does *not* do. It does not choose objects or pose
the agent — that is `pre_episode`, which the experiment drives; a `reset` starts
the next episode exactly as Monty would, with the interface's own positioning
procedure. And it does not touch the model: the actions come from the Elixir
side, which is where Monty's model lives.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import struct
import sys
from pathlib import Path

import numpy as np


def to_json(value):
    """Turns Monty's arrays, dataclasses and dicts into something JSON can carry."""
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.floating):
        return float(value)
    if isinstance(value, np.integer):
        return int(value)
    if isinstance(value, dict):
        return {str(key): to_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_json(item) for item in value]
    # `AgentState` and `SensorState` are dataclasses, and a sensor's rotation is
    # a `quaternion`, which Monty passes around as `wxyz`.
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return to_json(dataclasses.asdict(value))
    if hasattr(value, "components") and hasattr(value, "w"):
        return [to_json(part) for part in value.components]
    if hasattr(value, "value") and not isinstance(value, (str, bytes)):
        return to_json(value.value)
    return value


def action_from(message):
    """One action, as the class Monty's environment interface steps with.

    The port sends Monty's own `dict(action)` — `{"action": "move_forward",
    "agent_id": ..., "distance": ...}` — so the class is the CamelCase of the
    name and the rest are its fields. A rotation crosses as four numbers (`wxyz`)
    and has to be a `quaternion` again before Monty's environment sees it: it
    does arithmetic on the components, not on a list.
    """
    import quaternion

    from tbp.monty.frameworks.actions import actions as action_classes

    fields = dict(message)
    name = fields.pop("action")

    if "rotation_quat" in fields:
        fields["rotation_quat"] = quaternion.quaternion(*fields["rotation_quat"])

    class_name = "".join(part.capitalize() for part in name.split("_"))

    return getattr(action_classes, class_name)(**fields)


class World:
    """Monty's environment interface for one experiment."""

    def __init__(self, experiment: str, overrides: list[str], seed: int | None = None):
        # Importing Monty's hydra module registers its `${monty.class:...}`
        # resolver; without it the config cannot even be composed.
        import tbp.monty.hydra  # noqa: F401

        from hydra import compose, initialize_config_module
        from hydra.utils import instantiate

        from tbp.monty.frameworks.experiments.mode import ExperimentMode
        from tbp.monty.frameworks.experiments.seed import episode_seed
        from tbp.monty.frameworks.run_env import setup_env

        setup_env()

        with initialize_config_module("tbp.monty.conf", version_base=None):
            config = compose(
                config_name="experiment",
                overrides=[f"experiment={experiment}"] + overrides,
            )

        self.config = config.experiment.config

        # Monty's experiment builds the environment from `env_init_func(**
        # env_init_args)` and the interface from the config's class and args;
        # instantiating the blocks first resolves the interpolations and the
        # nested `_target_`s (the transforms) exactly once, the way Hydra does
        # it when it builds the experiment.
        environment = instantiate(self.config.environment)
        self.env = environment["env_init_func"](**environment["env_init_args"])

        interface_class = self.config.eval_env_interface_class
        interface_args = instantiate(self.config.eval_env_interface_args)

        self.seed = seed if seed is not None else int(self.config.seed)
        self.rng = np.random.RandomState(self.seed)
        self.experiment_mode = ExperimentMode.EVAL
        self._episode_seed = episode_seed

        self.interface = interface_class(
            env=self.env,
            transform=environment["transform"],
            experiment_mode=self.experiment_mode,
            rng=self.rng,
            seed=self.seed,
            **interface_args,
        )

        self.steps = 0
        self.episodes = 0

    def reset(self) -> dict:
        """Starts the next episode the way Monty starts one.

        Monty's epoch loop calls `pre_epoch` once — which puts the first object
        in the scene — and then `post_episode` after each episode, which cycles
        to the next one. `pre_episode` is the interface's own positioning
        procedure: it steps the world until the target is in view, exactly as it
        does inside Monty, so the first observation a model sees is the one Monty
        would have seen.

        The rng is reseeded per episode, from `episode_seed`, because that is what
        `MontyExperiment.pre_episode` does: an episode's positioning must not
        depend on how many draws the episode before it took. Keeping one stream
        for the whole epoch gets the first episode right and every later one
        wrong.
        """
        if self.episodes == 0:
            self.interface.pre_epoch()
        else:
            self.interface.post_episode()

        seed = self._episode_seed(self.seed, self.experiment_mode, self.episodes)
        self.rng = np.random.RandomState(seed)

        self.episodes += 1
        self.interface.pre_episode(self.rng)
        self.steps = 0

        # The rotation an object is shown at is the world's choice, not the
        # model's, and it is what makes two runs of "the same episode"
        # comparable — so it goes to the log, on stderr, out of the pipe's way.
        target = self._target()
        if target is not None:
            print(
                f"[peer] episode {self.episodes} (seed {seed}): {target['object']}",
                file=sys.stderr,
                flush=True,
            )

        # The model is told what the episode is about, and only this process
        # knows: it is Monty's interface that samples the object. A reply without
        # it would leave the model scoring itself against nothing.
        return {"ok": True, "primary_target": to_json(target) if target is not None else None}

    def step(self, actions: list[dict]) -> dict:
        self.steps += 1
        observations, proprioceptive_state = self.interface.step(
            [action_from(action) for action in actions]
        )

        return {
            "ok": True,
            "observations": to_json(observations),
            "proprioceptive_state": to_json(proprioceptive_state),
        }

    def _target(self):
        """What the episode is about, when the interface says."""
        return getattr(self.interface, "primary_target", None)


def read_frame(stream):
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack(">I", header)
    return stream.read(length)


def write_frame(stream, body):
    payload = json.dumps(body).encode("utf-8")
    stream.write(struct.pack(">I", len(payload)))
    stream.write(payload)
    stream.flush()


def serve(world: World, stream_in, stream_out) -> None:
    """Answers the protocol until the port closes the pipe."""
    while True:
        body = read_frame(stream_in)
        if body is None:
            return

        request = json.loads(body.decode("utf-8"))
        request_id = request.get("id")

        try:
            if request["command"] == "reset":
                reply = world.reset()
            elif request["command"] == "step":
                reply = world.step(request.get("actions", []))
            else:
                raise ValueError(f"unknown command {request['command']!r}")
        except Exception as error:  # noqa: BLE001 - the port wants a reason, not a traceback
            write_frame(stream_out, {"id": request_id, "error": f"{type(error).__name__}: {error}"})
            continue

        write_frame(stream_out, dict(reply, id=request_id))


def self_test(world: World) -> None:
    """One episode start and one step, printed — no pipe, no BEAM."""
    print("reset:", world.reset())
    print("target:", to_json(world._target()))

    reply = world.step([])
    observations = reply["observations"]
    proprioceptive_state = reply["proprioceptive_state"]

    print("agents:", sorted(observations))
    for agent_id, sensors in sorted(observations.items()):
        for sensor_id, observation in sorted(sensors.items()):
            fields = {
                name: (list(np.shape(value)) if not isinstance(value, (int, float)) else value)
                for name, value in sorted(observation.items())
            }
            print(f"  {agent_id}/{sensor_id}: {fields}")

    print("proprioception:", sorted(proprioceptive_state))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment", required=True, help="Monty experiment to run the world for")
    parser.add_argument(
        "--monty-root",
        default=None,
        help="checkout to run (default: $MONTY_ROOT, or whatever `tbp` is importable)",
    )
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--self-test", action="store_true", help="print one step instead of serving")
    parser.add_argument("overrides", nargs="*", help="Hydra overrides, e.g. constants.pretrained_dir=...")
    arguments = parser.parse_args()

    # The peer imports Monty, so it has to say *which* Monty: a relative or
    # inherited path quietly picks a different checkout.
    root = arguments.monty_root or os.environ.get("MONTY_ROOT")
    if root:
        sys.path.insert(0, str(Path(root).expanduser().resolve() / "src"))

    if arguments.self_test:
        self_test(World(arguments.experiment, arguments.overrides, seed=arguments.seed))
        return

    # Stdout is the frame stream. Monty and Habitat both log to it — Habitat from
    # C++, where a Python-level redirection would not reach — so the protocol
    # keeps its own handle and the file descriptor is pointed at stderr. A single
    # stray byte on this stream is a length prefix nobody meant, and the port
    # waits for a reply that never parses.
    protocol = os.fdopen(os.dup(1), "wb")
    os.dup2(2, 1)

    serve(World(arguments.experiment, arguments.overrides, seed=arguments.seed), sys.stdin.buffer, protocol)


if __name__ == "__main__":
    main()
