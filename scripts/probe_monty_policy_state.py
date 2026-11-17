"""Record what the surface policy's heading was, step by step, in Monty's run.

Not part of the port: it is how the port gets the one number a comparison of
actions cannot recover. The port's replay of a recorded episode agrees with
Monty's actions to one step and then differs, and every candidate on the port's
side has been ruled out — the branch taken, the curvature rule, the four angle
helpers, the draw itself. What is left is the heading the policy blended from,
and no recording carries it: `record_monty_episode.py` writes what a learning
module was given and what the model answered, not what the policy was holding.

So this wraps `SurfacePolicyCurvatureInformed.tangential_direction`, writes the
heading (and the previous one) before and after each call, the direction it
answered, and the stream's position beside it — a call that drew and a call that
did not are told apart by the position, and whether the two runs stood in the
same place is then a comparison of two integers rather than an argument.

It has to import the Monty checkout it is recording, so both path entries are
absolute — a relative `src` resolves against the working directory and quietly
picks whichever Monty the interpreter's own site-packages installed:

    MONTY=/path/to/monty-orig PORT=/path/to/ex.tbp.monty
    MONTY_DATA="$HOME/tbp/data" \\
    MONTY_MODELS="$HOME/tbp/results/monty/pretrained_models" \\
    PYTHONPATH="$MONTY/src:$PORT/scripts" \\
        "$MONTY/.venv/bin/python" "$PORT/scripts/probe_monty_policy_state.py" \\
        --out /tmp/monty-policy.jsonl --steps 32 \\
        experiment=base_10simobj_surf_agent \\
        logging=basic_info_monty_runs \\
        constants.pretrained_dir="$MONTY_MODELS/pretrained_ycb_v10" \\
        experiment.config.n_train_epochs=0 \\
        experiment.config.n_eval_epochs=1 \\
        experiment.config.logging.output_dir=/tmp/monty-policy/rec

The first episode is the one whose steps are written; `--steps` abandons it
rather than finishing it, which is what keeps a measurement of thirty steps
cheap. Each line is one event:

    {"kind": "tangential", "call": 12, "step": 11, "before": {...},
     "after": {...}, "direction": [0.12, -0.98, -0.06], "rng": 624}

`step` is the episode step the call belongs to, counted from one as the
recording counts, so a line here and a line of the recording name the same step.
"""

import argparse
import json
from pathlib import Path

# The policy's state that decides a heading, as Monty names it. A name that is
# not there is not an error: the policy has moved its flags between itself and
# the motor system's state over its life, and a recording that insists on a name
# would break on a checkout that spelled it elsewhere.
_WATCHED = (
    "tangential_angle",
    "prev_angle",
    "tangential_vec",
    "using_pc_guide",
    "ignoring_pc_counter",
    "following_heading_counter",
    "continuous_pc_steps",
    "min_general_steps",
    "min_heading_steps",
    "alpha",
    "pc_alpha",
    "pc_alpha_active",
    "episode_step",
)


class _Finished(Exception):
    """Raised to leave the run once the steps asked for have been taken."""


# The heading steps a surface policy can take, in the order it tests them. A call
# writes the ones it enters, so the route to a direction is read rather than
# guessed from the direction itself.
_TRACED = (
    "continue_along_curvature",
    "perform_standard_tang_step",
    "pc_guided_step",
    "pc_moving_average",
    "avoid_revisiting_locations",
    "search_for_heading",
    "reset_pc_buffers",
)


def _plain(value):
    """A number, a list of numbers, or a string — what JSON can carry."""
    if value is None or isinstance(value, (bool, int, str)):
        return value

    if hasattr(value, "tolist"):
        return value.tolist()

    if isinstance(value, float):
        return value

    try:
        return float(value)
    except (TypeError, ValueError):
        return str(value)


def _watched(policy):
    """The watched attributes the policy actually has, as plain values."""
    return {
        name: _plain(getattr(policy, name))
        for name in _WATCHED
        if hasattr(policy, name)
    }


def _rotation(state, policy):
    """The agent's orientation as the policy saw it, in Monty's `wxyz` order.

    A direction is answered in the agent's frame and recorded in the world's, so
    two runs whose headings agree and whose directions do not are two runs whose
    bodies stand differently — which is the world's answer, not the policy's. The
    rotation is what tells the two apart.
    """
    try:
        agent = state[policy.agent_id]
    except (KeyError, AttributeError, TypeError):
        return None

    rotation = getattr(agent, "rotation", None)

    if rotation is None:
        return None

    if hasattr(rotation, "components"):
        return [float(part) for part in rotation.components]

    return str(rotation)


def _stream(ctx):
    """Where the episode's stream stands: its position and its first key words.

    A position on its own is a residue: a stream that has drawn nothing and one
    that has drawn a whole block both read the same, and the two are different
    streams. The key words say which block it is, so a comparison of two runs can
    tell "stood in the same place" from "read the same number".
    """
    state = ctx.rng.get_state()

    return {"pos": int(state[2]), "keys": [int(key) for key in state[1][:3]]}


def _write(out):
    """A writer that appends one JSON line per event and flushes as it goes."""

    def write(record):
        out.write(json.dumps(record) + "\n")
        out.flush()

    return write


class Probe:
    """A Monty step hook that writes the policy's heading and the stream's place.

    The step hook runs after the policy has answered, so `calls` is the number of
    `tangential_direction` calls the episode has made: that is the step a
    `tangential` line belongs to, and it is what lets the two kinds of line be
    read as one sequence.
    """

    def __init__(self, write, steps, original):
        self._write = write
        self._steps = steps
        self._original = original
        self._calls = 0
        self._episode_step = 0

    def tangential_direction(self, policy, ctx, state, percept):
        self._calls += 1
        before = _watched(policy)
        direction = self._original(policy, ctx, state, percept)

        self._write(
            {
                "kind": "tangential",
                "call": self._calls,
                "step": self._episode_step + 1,
                "before": before,
                "after": _watched(policy),
                "rotation": _rotation(state, policy),
                "direction": _plain(direction),
                "rng": _stream(ctx),
            }
        )

        return direction

    def __call__(self, ctx, monty, supervised_lm_ids, step, observations, actions):
        self._episode_step = int(step) + 1

        self._write(
            {
                "kind": "step",
                "step": self._episode_step,
                "calls": self._calls,
                "mode": None
                if monty.experiment_mode is None
                else str(monty.experiment_mode),
                "rng": _stream(ctx),
                "actions": [type(action).__name__ for action in actions],
                "policy": _watched(monty.motor_system._policy_selector._policy),
            }
        )

        if self._episode_step >= self._steps:
            raise _Finished()

        return actions

    def enter(self, name, policy):
        """Writes a method the policy is about to take, with what it is holding."""
        self._write(
            {
                "kind": "method",
                "method": name,
                "call": self._calls,
                "step": self._episode_step + 1,
                "heading": _plain(getattr(policy, "tangential_angle", None)),
                "prev": _plain(getattr(policy, "prev_angle", None)),
            }
        )

    def close(self) -> None:
        """Monty closes its hook when the experiment closes; there is nothing to do."""


def main() -> None:
    """Runs the experiment named on the command line, through Monty's runner."""
    from hydra import compose, initialize_config_module

    # Monty's configs read paths from the environment (`MONTY_DATA`,
    # `MONTY_MODELS`, `MONTY_LOGS`), and its runner sets them before anything
    # else touches a config.
    from tbp.monty.frameworks.run_env import setup_env
    from tbp.monty.hydra import instantiate_experiment

    setup_env()

    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, help="where the lines go")
    parser.add_argument(
        "--steps", type=int, default=32, help="steps of the first episode to keep"
    )
    parser.add_argument("overrides", nargs="*", help="Hydra overrides, e.g. experiment=...")
    arguments = parser.parse_args()

    with initialize_config_module("tbp.monty.conf", version_base=None):
        cfg = compose(config_name="experiment", overrides=arguments.overrides)

    out = Path(arguments.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    handle = out.open("w")

    experiment = instantiate_experiment(cfg.experiment)

    # The hook is a config key Monty pops into `_step_hook` at instantiation, so
    # the one that runs is the experiment's own attribute rather than a second
    # hook built alongside it.
    experiment._step_hook = _install(arguments.steps, _write(handle))

    try:
        with experiment:
            experiment.run()
    except _Finished:
        pass
    finally:
        handle.close()


def _install(steps, write):
    """Wraps the policy's heading step in a probe, and answers the probe."""
    from tbp.monty.frameworks.models.motor_policies import (
        SurfacePolicyCurvatureInformed,
    )

    probe = Probe(write, steps, SurfacePolicyCurvatureInformed.tangential_direction)

    # Assigned as a plain function so it is bound to the policy that answers,
    # which a bound method of the probe would not be.
    def wrapped(policy, ctx, state, percept):
        return probe.tangential_direction(policy, ctx, state, percept)

    SurfacePolicyCurvatureInformed.tangential_direction = wrapped

    # Which of the heading steps the call took is the question, and the methods
    # answer it themselves: a name per method, written on entry, is enough to
    # read a step's route without a debugger.
    for name in _TRACED:
        original = getattr(SurfacePolicyCurvatureInformed, name, None)

        if original is None:
            continue

        def traced(policy, *args, _name=name, _original=original, **kwargs):
            probe.enter(_name, policy)
            return _original(policy, *args, **kwargs)

        setattr(SurfacePolicyCurvatureInformed, name, traced)

    return probe


if __name__ == "__main__":
    main()
