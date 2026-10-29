"""Record what Monty's feature-evidence calculator answers for a small graph.

`DefaultFeatureEvidenceCalculator` turns a node's stored features into one score
against what was just observed, and it is the number the whole matching search
is built on. The Elixir port claims to reproduce it — numeric, circular and
categorical comparisons, per-feature weights, and NaN for a node with a value
missing — so this runs Monty's own class over a few graphs and writes down what
it answered.

    python3 scripts/record_monty_feature_evidence.py

Writes `test/fixtures/monty_feature_evidence.json`. A `null` is Monty's NaN.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

from tbp.monty.frameworks.models.evidence_matching.feature_evidence.calculator import (  # noqa: E402
    DefaultFeatureEvidenceCalculator,
)

OUT = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "monty_feature_evidence.json"

# hsv carries three columns, one of them circular; object_id is categorical;
# pose_vectors and pose_fully_defined are skipped wherever they appear; curvature
# is a plain number. The columns are laid out in this order.
FEATURE_ORDER = ["hsv", "object_id", "pose_vectors", "pose_fully_defined", "curvature"]
QUERY_FEATURES = {"hsv": [0.2, 0.5, 0.5], "object_id": 3, "curvature": 0.4}
TOLERANCES = {"hsv": [0.1, 0.1, 0.1], "object_id": 1.0, "curvature": 0.5}
WEIGHTS = {"hsv": [0.5, 0.5, 0.5], "object_id": 1.0, "curvature": 1.0}


def _case(rows, *, tolerances=TOLERANCES, weights=WEIGHTS, query=QUERY_FEATURES):
    evidence = DefaultFeatureEvidenceCalculator.calculate(
        np.array(rows, dtype=np.float64),
        FEATURE_ORDER,
        weights,
        query,
        tolerances,
    )

    return {
        "rows": _cells(rows),
        "feature_order": FEATURE_ORDER,
        "query_features": query,
        "tolerances": tolerances,
        "feature_weights": weights,
        "expected": [None if math.isnan(value) else float(value) for value in evidence],
    }


def _cells(rows):
    """NaN has no JSON spelling; a missing stored value is a missing number."""
    return [
        [None if math.isnan(cell) else cell for cell in row]
        for row in rows
    ]


def main():
    cases = [
        # The first node matches exactly, the second is half a tolerance off in
        # every column, and the third is at or beyond the tolerance in all of
        # them — evidence 1, about 0.5, and 0.
        _case(
            [
                [0.2, 0.5, 0.5, 3.0, 0.4],
                [0.25, 0.55, 0.45, 3.0, 0.4],
                [0.35, 0.7, 0.7, 4.0, 1.2],
            ]
        ),
        # Hue is circular: 0.99 and 0.01 are 0.02 apart the short way round, so a
        # stored 0.99 seen as 0.01 is nearly a match rather than nearly the
        # opposite.
        _case([[0.99, 0.5, 0.5, 3.0, 0.4]], query={"hsv": [0.01, 0.5, 0.5], "object_id": 3, "curvature": 0.4}),
        # A feature weighted zero cannot pull the average either way, and a node
        # whose stored value is missing has no evidence at all.
        _case(
            [[0.2, 0.5, 0.5, 3.0, 0.4], [0.9, 0.5, 0.5, 3.0, 0.4], [0.2, 0.5, 0.5, 3.0, float("nan")]],
            weights={"hsv": [0.0, 0.0, 0.0], "object_id": 1.0, "curvature": 1.0},
        ),
    ]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"cases": cases}, indent=2, allow_nan=False) + "\n")
    print(f"wrote {OUT} ({len(cases)} cases)")


if __name__ == "__main__":
    main()
