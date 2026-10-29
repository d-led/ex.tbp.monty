"""Record how Monty's environment interface steps a world and transforms it.

`Interface` in `tbp/monty/experiment/environment.py` is the layer between a
simulator and everything above it: it steps the environment, then runs the
experiment's transform chain over the observations before any module sees them.
The order matters — a transform may read the next one's output — and `reset`
runs the chain too, which is easy to miss.

    python3 scripts/record_monty_interface.py

Needs an interpreter with Monty's dependencies, including `omegaconf` (which
`experiment/environment.py` imports for Hydra's config types).

## What is recorded

A stub environment that counts what it was asked to do, and two transforms that
tag the observations in order, so the record is the *sequence*: which transform
ran, with which context, and what the interface answered. That is the whole of
what the interface decides — it owns no arithmetic of its own.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

import numpy as np  # noqa: E402

try:
    from tbp.monty.experiment.environment import Interface  # noqa: E402
    from tbp.monty.frameworks.experiments.mode import ExperimentMode  # noqa: E402
except ModuleNotFoundError as error:  # pragma: no cover - the wrong interpreter
    raise SystemExit(
        f"{error.name} is missing from {sys.executable}; run this with an "
        "interpreter that has Monty's dependencies (see docs/validation.md)"
    ) from error

OUT = (
    Path(__file__).resolve().parents[1]
    / "test"
    / "fixtures"
    / "monty_interface.json"
)

AGENT = "agent_id_0"


class StubEnvironment:
    """A world that says what it was asked to do, and answers the same view."""

    def __init__(self):
        self.resets = 0
        self.steps = []

    def reset(self):
        self.resets += 1
        return {"observations": ["from reset"]}, {"state": "reset"}

    def step(self, actions):
        self.steps.append([type(action).__name__ for action in actions])
        return {"observations": [f"after {len(self.steps)} steps"]}, {"state": "stepped"}


class TaggingTransform:
    """Tags the observations, and records the context it was handed."""

    def __init__(self, name, log):
        self.name = name
        self.log = log

    def __call__(self, observations, ctx):
        self.log.append(
            {
                "transform": self.name,
                "saw": list(observations["observations"]),
                "has_state": ctx.state is not None,
                "has_rng": ctx.rng is not None,
            }
        )
        return {**observations, "observations": [*observations["observations"], self.name]}


def main():
    log = []
    environment = StubEnvironment()

    interface = Interface(
        env=environment,
        rng=np.random.RandomState(0),
        seed=0,
        experiment_mode=ExperimentMode.EVAL,
        transform=[TaggingTransform("first", log), TaggingTransform("second", log)],
    )

    # The constructor resets, so the log already has the reset's two transforms.
    resets_on_construction = list(log)
    log.clear()

    observations, state = interface.step([])
    first_step = {
        "calls": list(log),
        "observations": observations["observations"],
        "state": state,
        "environment_steps": list(environment.steps),
    }
    log.clear()
    again, _state_again = interface.step([])

    second = {
        "calls": list(log),
        "observations": again["observations"],
        "environment_steps": list(environment.steps),
    }

    fixture = {
        "reset": {
            "calls": resets_on_construction,
            "environment_resets": 1,
        },
        "step": first_step,
        # A second step shows that the interface keeps stepping the same
        # environment rather than making a new one.
        "second step": second,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixture, indent=1) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
