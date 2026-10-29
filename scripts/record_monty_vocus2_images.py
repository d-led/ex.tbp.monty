"""Record what OpenCV answers for VOCUS2's colour and blur operations.

`vocus2/images.py` is arithmetic wrapped around OpenCV: two of its colour spaces
are pure float maths, the third is `cv2.cvtColor`, and the blur is
`cv2.GaussianBlur` with `BORDER_REPLICATE`. The port reproduces the arithmetic
exactly and had to measure the rest, so this writes down what OpenCV answered.

    python3 scripts/record_monty_vocus2_images.py

Needs an interpreter with OpenCV and numpy — Monty's own environment:

    python3 scripts/record_monty_vocus2_images.py

Needs an interpreter with Monty's dependencies, OpenCV included; see
`docs/validation.md`.

Writes `test/fixtures/monty_vocus2_images.json`.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

import numpy as np  # noqa: E402

import cv2  # noqa: E402

try:
    from tbp.monty.frameworks.models.salience.strategies.vocus2 import images  # noqa: E402
except ModuleNotFoundError as error:  # pragma: no cover - the wrong interpreter
    raise SystemExit(
        f"{error.name} is missing from {sys.executable}; run this with an "
        "interpreter that has Monty's dependencies, OpenCV included "
        "(see docs/validation.md)"
    ) from error

OUT = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "monty_vocus2_images.json"


def _plain(value):
    return np.asarray(value, dtype=np.float64).tolist()


def _colour_case(name, convert, rgba):
    image = np.array(rgba, dtype=np.uint8)
    return {"name": name, "rgba": rgba, "expected": _plain(convert(image))}


def _blur_case(name, plane, sigma, truncate=None):
    image = np.array(plane, dtype=np.float32)
    expected = images.gaussian_blur(image, sigma) if truncate is None else images.gaussian_blur(
        image, sigma, truncate
    )
    return {
        "name": name,
        "plane": plane,
        "sigma": sigma,
        "truncate": truncate,
        "expected": _plain(expected),
    }


def _resize_case(name, plane, shape, interpolation):
    """`interpolation` is "area" or "cubic", as the port spells them."""
    image = np.array(plane, dtype=np.float32)
    constant = cv2.INTER_AREA if interpolation == "area" else cv2.INTER_CUBIC

    return {
        "name": name,
        "plane": plane,
        "shape": list(shape),
        "interpolation": interpolation,
        "expected": _plain(images.resize(image, (shape[0], shape[1]), interpolation=constant)),
    }


def main():
    # Nine colours that between them cover the black corner, the grey axis, all
    # three primaries and a colour outside the sRGB gamut's hue range.
    rgba = [
        [[0, 0, 0], [255, 255, 255], [128, 128, 128]],
        [[255, 0, 0], [0, 255, 0], [0, 0, 255]],
        [[12, 200, 41], [250, 3, 199], [77, 77, 200]],
    ]

    colour_cases = [
        _colour_case("lab", images.rgb_to_lab, rgba),
        _colour_case("opponent", images.rgb_to_opponent, rgba),
        _colour_case("opponent_codi", images.rgb_to_opponent_codi, rgba),
    ]

    # A five by five plane with a bright cell in it, blurred at three sigmas:
    # one whose kernel is three pixels wide, one at the default truncation, and
    # one with a wider truncation than OpenCV's.
    plane = [
        [10.0, 10.0, 10.0, 10.0, 10.0],
        [10.0, 200.0, 10.0, 10.0, 10.0],
        [10.0, 10.0, 10.0, 10.0, 10.0],
        [10.0, 10.0, 10.0, 120.0, 10.0],
        [10.0, 10.0, 10.0, 10.0, 10.0],
    ]

    blur_cases = [
        _blur_case("sigma 0.5", plane, 0.5),
        _blur_case("sigma 1.0", plane, 1.0),
        _blur_case("sigma 2.0", plane, 2.0),
        _blur_case("sigma 1.0, truncate 4", plane, 1.0, 4.0),
    ]

    # The pyramids only ever shrink by area and enlarge by cubic, which is what
    # these cover: a halving (an octave), a non-integer shrink, and a cubic
    # enlargement that also moves off the pixel grid.
    resize_cases = [
        _resize_case("area half", plane, (3, 3), "area"),
        _resize_case(
            "area 8 to 3",
            [[float(value) for value in range(8)] for _ in range(6)],
            (3, 3),
            "area",
        ),
        _resize_case("cubic double", plane, (10, 10), "cubic"),
        _resize_case("cubic 3 to 7", plane, (7, 7), "cubic"),
        _resize_case("cubic 5 to 2", plane, (2, 2), "cubic"),
    ]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps(
            {"colour": colour_cases, "blur": blur_cases, "resize": resize_cases}, indent=2
        )
        + "\n"
    )
    print(
        f"wrote {OUT} ({len(colour_cases)} colour, {len(blur_cases)} blur, "
        f"{len(resize_cases)} resize cases)"
    )


if __name__ == "__main__":
    main()
