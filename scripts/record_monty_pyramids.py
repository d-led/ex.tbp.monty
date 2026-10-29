"""Record what Monty's pyramids answer, plane by plane.

`pyramids.py` is a multi-scale image structure whose numbers come from blur and
resize applied in a particular order with particular sigmas — the sort of thing
that is easy to get subtly wrong and impossible to spot by eye. This runs
Monty's own functions over small images and writes down what they answered.

    python3 \\
        scripts/record_monty_pyramids.py

Writes `test/fixtures/monty_pyramids.json`.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

import numpy as np  # noqa: E402

try:
    from tbp.monty.frameworks.models.salience.strategies.vocus2 import pyramids  # noqa: E402
except ModuleNotFoundError as error:  # pragma: no cover - the wrong interpreter
    raise SystemExit(
        f"{error.name} is missing from {sys.executable}; run this with Monty's "
        "environment, e.g. python3"
    ) from error

OUT = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "monty_pyramids.json"


def _planes(pyramid):
    """A pyramid as octaves of scales, the way the port stores it."""
    return [
        [np.asarray(pyramid.data[octave, scale], dtype=np.float64).tolist()
         for scale in range(pyramid.shape[1])]
        for octave in range(pyramid.shape[0])
    ]


def _image(rows, columns):
    """A small image with structure at two sizes: a blob and a bright edge."""
    image = np.full((rows, columns), 10.0, dtype=np.float32)
    image[1:3, 1:3] += 90.0
    image[:, -1] += 40.0
    return image


def main():
    image = _image(8, 8)

    gaussian = pyramids.gaussian_pyramid(image, sigma=1.0, n_scales=3)
    center, surround = pyramids.center_surround_pyramids(
        image, center_sigma=1.0, surround_sigma=2.5, n_scales=2
    )
    combined = pyramids.pyramid_combine_max([gaussian, gaussian])
    collapsed = pyramids.pyramid_collapse(gaussian, reduce=lambda imgs: np.sum(imgs, axis=0))

    fixture = {
        "image": image.tolist(),
        "octave_shapes": {
            "8x8": [list(shape) for shape in pyramids.pyramid_octave_shapes((8, 8))],
            "8x8 max 2": [list(shape) for shape in pyramids.pyramid_octave_shapes((8, 8), max_octaves=2)],
            "5x9": [list(shape) for shape in pyramids.pyramid_octave_shapes((5, 9))],
        },
        "gaussian": {
            "sigma": 1.0,
            "n_scales": 3,
            "expected": _planes(gaussian),
        },
        "center_surround": {
            "center_sigma": 1.0,
            "surround_sigma": 2.5,
            "n_scales": 2,
            "center": _planes(center),
            "surround": _planes(surround),
        },
        "laplacian": {
            "expected": _planes(pyramids.laplacian_pyramid(gaussian)),
        },
        "combine_max": {
            "expected": _planes(combined),
        },
        "collapse_sum": {
            "expected": np.asarray(collapsed, dtype=np.float64).tolist(),
        },
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
