"""Record what Monty's salience classes answer, so the port can be held to it.

`ReturnInhibitor` is where the salience machinery becomes numbers: an
exponential in time, an exponential in space, a cutoff, and a maximum over the
visits. The Elixir port claims to reproduce them; this records Monty's own
answers to replay against, in the same spirit as
`record_monty_episode.py` — Monty runs here, and only its results are committed.

    python3 scripts/record_monty_salience.py

Writes `test/fixtures/monty_salience_inhibitor.json`. Each trajectory names the
kernel schedule it was given, the location the sensor looked from on each step
(`null` when the view's middle was not on an object), the points it asked about,
and the weights Monty answered with on that step.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

from tbp.monty.frameworks.models.salience.on_object_observation import (  # noqa: E402
    on_object_observation,
)
from tbp.monty.frameworks.models.salience.return_inhibitor import (  # noqa: E402
    DecayField,
    DecayKernelFactory,
    ReturnInhibitor,
)

OUT = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "monty_salience_inhibitor.json"
OBSERVATIONS_OUT = (
    Path(__file__).resolve().parents[1]
    / "test"
    / "fixtures"
    / "monty_on_object_observation.json"
)


def _walk(kernel_factory, visits, queries):
    """Runs one trajectory and returns Monty's answer on each step."""
    inhibitor = ReturnInhibitor(DecayField(kernel_factory))
    points = np.array(queries, dtype=np.float64)

    steps = []
    for visit in visits:
        location = None if visit is None else np.array(visit, dtype=np.float64)
        weights = inhibitor(visit if visit is None else location, points)
        steps.append(
            {
                "visited_location": visit,
                "weights": [float(weight) for weight in weights],
            }
        )

    return {
        "kernel": {
            "tau_t": kernel_factory._tau_t,
            "tau_s": kernel_factory._tau_s,
            "spatial_cutoff": kernel_factory._spatial_cutoff,
            "w_t_min": kernel_factory._w_t_min,
        },
        "queries": queries,
        "steps": steps,
    }


def _grid(rows, columns, semantic_ids):
    """A view whose every pixel is distinguishable, so a transposition shows.

    The x coordinate counts columns and the y coordinate counts rows, ten times
    over, so reading the grid the wrong way round gives different numbers rather
    than the same ones in a different order.
    """
    points = []
    for row in range(rows):
        for column in range(columns):
            semantic_id = semantic_ids[row][column]
            points.append([float(column), float(row) * 10.0, -1.0, semantic_id])

    return {
        "rgba": np.ones((rows, columns, 4), dtype=np.float64),
        "depth": np.ones((rows, columns), dtype=np.float64),
        "semantic_3d": np.array(points, dtype=np.float64),
        "salience": np.arange(1, rows * columns + 1, dtype=np.float64).reshape(
            rows, columns
        ),
    }


def _observation(view):
    """Runs Monty's reshaping on one view and returns what it made of it."""
    observation = on_object_observation(view, view["salience"])
    return {
        "row_column_shape": [view["rgba"].shape[0], view["rgba"].shape[1]],
        "semantic_3d": view["semantic_3d"].tolist(),
        "salience_map": view["salience"].tolist(),
        "expected": {
            "center_location": (
                None
                if observation.center_location is None
                else observation.center_location.tolist()
            ),
            "locations": observation.locations.tolist(),
            "salience": observation.salience.tolist(),
            "on_object_map": observation.on_object_map.tolist(),
            "location_map": observation.location_map.tolist(),
        },
    }


def main():
    # Four query points around the origin: at a visit, 5 mm away, 15 mm away
    # (past the 20 mm cutoff's reach from a 5 mm visit) and far outside it.
    queries = [
        [0.0, 0.0, 0.0],
        [0.005, 0.0, 0.0],
        [0.015, 0.0, 0.0],
        [0.5, 0.0, 0.0],
    ]

    trajectories = [
        # A short half-life, so the visit decays below `w_t_min` inside the
        # trajectory and the field has to drop it.
        _walk(
            DecayKernelFactory(tau_t=1.0, tau_s=0.01, spatial_cutoff=0.02, w_t_min=0.1),
            [[0.0, 0.0, 0.0], None, [0.005, 0.0, 0.0], None, None, None, None],
            queries,
        ),
        # Two visits close enough that their kernels overlap: the field takes the
        # stronger one at each point rather than their sum.
        _walk(
            DecayKernelFactory(tau_t=10.0, tau_s=0.01, spatial_cutoff=0.02, w_t_min=0.1),
            [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.0, 0.0, 0.0]],
            queries,
        ),
        # No cutoff: the kernel still answers at half a metre away, very faintly.
        _walk(
            DecayKernelFactory(tau_t=10.0, tau_s=0.01, spatial_cutoff=None, w_t_min=0.1),
            [[0.0, 0.0, 0.0], None],
            queries,
        ),
    ]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"trajectories": trajectories}, indent=2) + "\n")
    print(f"wrote {OUT} ({len(trajectories)} trajectories)")

    # A three by four view is not square on purpose: the reshaping reads the flat
    # point cloud row by row, and a square view would look the same either way.
    views = [
        # The middle pixel is on the object, so there is a centre to look from.
        _observation(_grid(3, 4, [[1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1]])),
        # The middle pixel is background, so the salience module gets no centre.
        _observation(_grid(3, 4, [[1, 1, 1, 1], [1, 1, 0, 1], [0, 0, 1, 1]])),
    ]

    OBSERVATIONS_OUT.write_text(json.dumps({"views": views}, indent=2) + "\n")
    print(f"wrote {OBSERVATIONS_OUT} ({len(views)} views)")


if __name__ == "__main__":
    main()
