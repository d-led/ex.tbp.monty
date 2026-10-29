"""Record what Monty's `SalienceSM` proposes over three views, step by step.

This is the one check that covers the whole salience chain rather than its
pieces: the strategy scores the view, `on_object_observation` reshapes it, the
return inhibitor suppresses where the sensor has been, and the module turns what
is left into goals. Everything below the strategy is arithmetic the port claims
to reproduce, and until now nothing compared it with Monty's own answer.

    python3 scripts/record_monty_salience_sm.py

Needs an interpreter with Monty's dependencies. `numpy-quaternion` is the only one
this environment lacks, so a virtualenv built with `--system-site-packages`
(inheriting numpy and OpenCV) plus that one package is enough; the machine's own
interpreter is left untouched.

## Why the sensor moves

The inhibitor counts where the sensor has been. Looking at the same place three
times would record the same visit three times and age nothing, so each step sees
a view whose blob and point cloud have shifted: the goals then differ between
steps for the right reason, and the weights are a claim rather than a constant.

## What is recorded, and what is not

`SalienceSM` draws a dither from the run's random stream before it normalises,
and this port draws from its own stream by design (`docs/monty-bugs.md` §2.1), so
the *confidences* cannot be compared — only their deterministic half. The
recorder therefore patches `_randomize_salience` to the identity, and writes down

  - the goal locations and the on-object count (where the module decided to look),
  - the salience and the inhibitor's weights the step actually used,
  - the decayed salience, `salience - 0.75 * ior`, which is the arithmetic before
    the dither,
  - the region (empty without a segmentation strategy, which is every config).

The identity patch is a recording choice, not a claim about Monty: it is stated
here so nobody reads the fixture as Monty's confidences.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

import numpy as np  # noqa: E402
import quaternion  # noqa: E402

try:
    from tbp.monty.context import RuntimeContext  # noqa: E402
    from tbp.monty.frameworks.models.motor_system_state import SensorState  # noqa: E402
    from tbp.monty.frameworks.models.salience.on_object_observation import (  # noqa: E402
        on_object_observation,
    )
    from tbp.monty.frameworks.models.salience.sensor_module import SalienceSM  # noqa: E402
    from tbp.monty.frameworks.models.salience.strategies.vocus2 import vocus2  # noqa: E402
except ModuleNotFoundError as error:  # pragma: no cover - the wrong interpreter
    raise SystemExit(
        f"{error.name} is missing from {sys.executable}; run this with an "
        "interpreter that has Monty's dependencies (see docs/validation.md)"
    ) from error

OUT = (
    Path(__file__).resolve().parents[1]
    / "test"
    / "fixtures"
    / "monty_salience_sm.json"
)

SIZE = 32
STRATEGY = {
    "center_sigma": 3.0,
    "surround_sigma": 5.0,
    "n_scales": 2,
    "max_octaves": 5,
    "use_depth": True,
    "use_orientation": False,
}

# Where the blob sits, and how far the point cloud has been shifted with it, so
# that each step is a visit to a different place on the surface.
STEPS = [(0, 0), (3, 0), (3, 3)]


def _plain(value):
    return np.asarray(value, dtype=np.float64).tolist()


def _observation(row_offset, column_offset):
    """A view with a bright blob, a dark corner and a step in the depth.

    Only the blob has a semantic id, and one corner of it has no depth, so the
    on-object view is a subset of the pixels rather than the whole frame — the
    subset is what the module actually turns into goals.
    """
    rgba = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    rgba[:, :, 3] = 255

    depth = np.full((SIZE, SIZE), 2.0, dtype=np.float64)
    points = []

    for row in range(SIZE):
        for column in range(SIZE):
            blob_row = row - row_offset
            blob_column = column - column_offset
            on_blob = 8 <= blob_row < 20 and 8 <= blob_column < 20

            if on_blob:
                rgba[row, column, :3] = 230
            elif row < 6 and column < 6:
                rgba[row, column, :3] = 20
            else:
                rgba[row, column, :3] = 120

            if on_blob:
                depth[row, column] = 0.6
            if blob_row in (8, 9) and blob_column in (8, 9):
                depth[row, column] = 0.0

            points.append(
                [
                    column * 0.002 + column_offset * 0.002,
                    row * 0.002 + row_offset * 0.002,
                    -1.0,
                    1.0 if on_blob else 0.0,
                ]
            )

    return {
        "rgba": rgba,
        "depth": depth,
        "semantic_3d": np.array(points, dtype=np.float64),
    }


def main():
    strategy = vocus2.Vocus2.from_config(vocus2.Vocus2SalienceConfig(**STRATEGY))

    module = SalienceSM("view_finder", salience_strategy=strategy)
    # The telemetry hook reads the pose even when it is the no-op one.
    module.state = SensorState(position=np.zeros(3), rotation=np.quaternion(1, 0, 0, 0))

    # The dither is Monty's random stream; see the module docstring.
    module._randomize_salience = lambda ctx, weighted: weighted  # noqa: ARG005

    # The inhibitor ages on every call, so the weights are captured from inside
    # the step rather than asked for again afterwards.
    used = {}
    weight_salience = module._weight_salience

    def recording_weight_salience(ctx, salience, ior_weights):
        used["salience"] = salience
        used["ior_weights"] = ior_weights
        return weight_salience(ctx, salience, ior_weights)

    module._weight_salience = recording_weight_salience

    ctx = RuntimeContext(rng=np.random.RandomState(0))

    observations = []
    steps = []

    for index, (row_offset, column_offset) in enumerate(STEPS):
        observation = _observation(row_offset, column_offset)
        observations.append(observation)

        module.step(ctx, observation)
        goals = module.propose_goals()
        region = module.propose_region()

        on_object = on_object_observation(
            observation, strategy(ctx=ctx, rgba=observation["rgba"], depth=observation["depth"])
        )
        salience = used["salience"]
        ior = used["ior_weights"]

        steps.append(
            {
                "step": index,
                "center_location": (
                    None
                    if on_object.center_location is None
                    else _plain(on_object.center_location)
                ),
                "on_object_count": int(len(on_object.locations)),
                "salience": _plain(salience),
                "ior_weights": _plain(ior),
                "decayed": _plain(module._decay_salience(salience, ior)),
                "goal_locations": _plain([goal.location for goal in goals]),
                "goal_confidences": _plain([goal.confidence for goal in goals]),
                "region_locations": _plain(region.locations),
                "region_weights": _plain(region.weights),
            }
        )

    fixture = {
        "observations": [
            {
                "rgba": observation["rgba"].tolist(),
                "depth": _plain(observation["depth"]),
                "semantic_3d": _plain(observation["semantic_3d"]),
            }
            for observation in observations
        ],
        "strategy": STRATEGY,
        "steps": steps,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixture) + "\n")
    print(
        f"wrote {OUT} ({len(steps)} steps, "
        f"goals {[step['on_object_count'] for step in steps]})"
    )


if __name__ == "__main__":
    main()
