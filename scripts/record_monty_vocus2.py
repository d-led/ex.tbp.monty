"""Record what Monty's VOCUS2 attention model answers, pixel by pixel.

`vocus2.py` is the strategy a salience-configured experiment names: colour
channels, depth and orientation each produce a feature map, and the maps are
combined into one salience map. Its parts are small, but their numbers come from
the pyramids and from Gabor filtering, and a mistake anywhere shows up only as a
map that looks plausible.

    python3 scripts/record_monty_vocus2.py

Needs an interpreter with Monty's dependencies installed; see
`docs/validation.md`.

Writes `test/fixtures/monty_vocus2.json`.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

import numpy as np  # noqa: E402

try:
    from tbp.monty.context import RuntimeContext  # noqa: E402
    from tbp.monty.frameworks.models.salience.strategies.vocus2 import vocus2  # noqa: E402
except ModuleNotFoundError as error:  # pragma: no cover - the wrong interpreter
    raise SystemExit(
        f"{error.name} is missing from {sys.executable}; run this with an "
        "interpreter that has Monty's dependencies (see docs/validation.md)"
    ) from error

OUT = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "monty_vocus2.json"


def _plain(value):
    return np.asarray(value, dtype=np.float64).tolist()


def _context():
    return RuntimeContext(rng=np.random.RandomState(0), suppress_runtime_errors=False)


def _image(size):
    """A 32x32 view: a bright blob, a dark corner and a hard edge down the middle."""
    image = np.full((size, size), 0.5, dtype=np.float32)
    image[4:10, 4:10] = 0.95
    image[20:28, 20:28] = 0.05
    image[:, size // 2 :] += 0.25
    return image


def _depth(size):
    """A depth map with a near step in it, and a pixel with nothing in it."""
    depth = np.full((size, size), 2.0, dtype=np.float32)
    depth[8:16, 8:24] = 0.75
    depth[0, 0] = 0.0
    return depth


def main():
    size = 32
    channel = _image(size)
    depth = _depth(size)

    no_limits = vocus2.NoOperatingLimits()

    color = vocus2.ColorChannelSalience(
        center_sigma=2.0, surround_sigma=3.0, n_scales=2, operating_limits=no_limits
    )
    depth_salience = vocus2.DepthSalience(
        center_sigma=2.0, surround_sigma=3.0, n_scales=2, operating_limits=no_limits
    )
    orientation = vocus2.OrientationSalience(period=4.0)

    color_map, center = color.process(_context(), channel)
    depth_map = depth_salience.process(_context(), depth)
    orientation_map = orientation.process(_context(), center)

    rgba = np.zeros((size, size, 4), dtype=np.uint8)
    rgba[:, :, 0] = (channel * 255).astype(np.uint8)
    rgba[:, :, 1] = ((1.0 - channel) * 255).astype(np.uint8)
    rgba[:, :, 2] = 128
    rgba[:, :, 3] = 255

    strategy = vocus2.Vocus2(color=color, depth=depth_salience, orientation=orientation)
    salience_map = strategy(_context(), rgba, depth.astype(np.float64))

    # The limits are pure arithmetic, so every answer is worth pinning, including
    # the ones that are rejections.
    limits = vocus2.SafeOperatingLimits()
    limit_cases = [
        {"min_image_dim_size": size, "center_sigma": c, "surround_sigma": s}
        for size, c, s in [
            (64, 2.0, 4.0),
            (64, 0.5, 4.0),
            (64, 2.0, 2.1),
            (64, 8.0, 9.0),
            (64, 2.0, 40.0),
            (32, 2.0, 3.0),
        ]
    ]
    for case in limit_cases:
        error = limits.validate(
            case["min_image_dim_size"], case["center_sigma"], case["surround_sigma"]
        )
        case["error"] = None if error is None else str(error)

    fixture = {
        "color": {
            "image": _plain(channel),
            "center_sigma": 2.0,
            "surround_sigma": 3.0,
            "n_scales": 2,
            "map": _plain(color_map),
            "center_pyramid": [
                [_plain(center.data[octave, scale]) for scale in range(center.shape[1])]
                for octave in range(center.shape[0])
            ],
        },
        "depth": {
            "image": _plain(depth),
            "center_sigma": 2.0,
            "surround_sigma": 3.0,
            "n_scales": 2,
            "map": _plain(depth_map),
        },
        "orientation": {
            "period": 4.0,
            "kernels": {name: _plain(kernel) for name, kernel in orientation._kernels.items()},
            "map": _plain(orientation_map),
            "pyramid": {
                "octaves": [
                    [_plain(center.data[octave, scale]) for scale in range(center.shape[1])]
                    for octave in range(center.shape[0])
                ]
            },
        },
        "strategy": {
            "rgba": rgba.tolist(),
            "depth": _plain(depth),
            "map": _plain(salience_map),
        },
        "limits": limit_cases,
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
