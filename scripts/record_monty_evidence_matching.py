"""Record what Monty's evidence-slope tracker answers, step by step.

`EvidenceSlopeTracker` is where a learning module decides that a hypothesis is
not merely unconvincing but losing ground. Its numbers come from a sliding
window of evidence, per-channel normalisation, and NaN-aware averaging, and the
Elixir port claims to reproduce all three; this runs Monty's own class over a
scripted history and writes down what it answered, so the port can be held to
it.

    python3 scripts/record_monty_evidence_matching.py

Writes `test/fixtures/monty_evidence_slope_tracker.json`. A `null` slope is
Monty's NaN: a hypothesis with no usable evidence has no slope at all, which is
not the same as a slope of zero.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

from tbp.monty.frameworks.models.evidence_matching.evidence_slope_tracker import (  # noqa: E402
    EvidenceSlopeTracker,
)

OUT = (
    Path(__file__).resolve().parents[1]
    / "test"
    / "fixtures"
    / "monty_evidence_slope_tracker.json"
)


def _numbers(values):
    """NaN has no JSON spelling; it is a missing number."""
    out = []
    for value in np.asarray(values, dtype=np.float64).tolist():
        out.append(None if math.isnan(value) else float(value))
    return out


def _record(window_size, min_age, ops):
    """Runs one scripted history and returns what Monty answered at each step."""
    tracker = EvidenceSlopeTracker(window_size=window_size, min_age=min_age)

    steps = []
    for op in ops:
        name = op[0]
        step = {"op": name}

        if name == "add_hyp":
            _, count = op
            tracker.add_hyp(count)
            step["count"] = count
        elif name == "update":
            _, values, num_channels = op
            tracker.update(np.array(values, dtype=np.float64), num_channels=num_channels)
            step["values"] = [float(value) for value in values]
            step["num_channels"] = num_channels
        elif name == "remove_hyp":
            _, indices = op
            tracker.remove_hyp(np.array(indices, dtype=int))
            step["indices"] = list(indices)
        elif name == "select":
            _, threshold = op
            selection = tracker.select_hypotheses(threshold)
            step["threshold"] = threshold
            step["ids_to_retain"] = [int(index) for index in selection.ids_to_retain]
            step["ids_to_remove"] = [int(index) for index in selection.ids_to_remove]
        elif name == "clear":
            tracker.clear_hyp()
        else:  # pragma: no cover - a scripto typo, not a state of the tracker
            raise ValueError(name)

        step["total_size"] = tracker.total_size()
        step["ages"] = [int(age) for age in tracker.hyp_ages()]
        step["removable"] = [bool(flag) for flag in tracker.removable_indices_mask()]
        step["slopes"] = _numbers(tracker.calculate_slopes())
        steps.append(step)

    return {"window_size": window_size, "min_age": min_age, "steps": steps}


def main():
    histories = [
        # Three hypotheses with different trends: one rising, one flat, one
        # falling. The flat one is the interesting case — it has a slope, and
        # that slope is zero, which is not the same as having none.
        _record(
            window_size=4,
            min_age=2,
            ops=[
                ("add_hyp", 3),
                ("update", [0.0, 1.0, 2.0], 1),
                ("update", [1.0, 1.0, 1.0], 1),
                ("update", [2.0, 1.0, 0.0], 1),
                ("update", [3.0, 1.0, -1.0], 1),
                ("select", 0.5),
            ],
        ),
        # The channel count divides the per-step difference, so the same evidence
        # arriving through three channels is a third of the slope.
        _record(
            window_size=3,
            min_age=1,
            ops=[
                ("add_hyp", 2),
                ("update", [0.0, 0.0], 1),
                ("update", [3.0, 1.0], 3),
                ("update", [6.0, 2.0], 3),
                ("select", 0.5),
            ],
        ),
        # A hypothesis added but never updated has no slope at all, and removal
        # takes the survivors' indices, not the original ones.
        _record(
            window_size=3,
            min_age=1,
            ops=[
                ("add_hyp", 3),
                ("update", [0.0, 0.0, 0.0], 1),
                ("update", [1.0, -1.0, 2.0], 1),
                ("remove_hyp", [1]),
                ("update", [2.0, 3.0], 1),
                ("select", 0.0),
                ("clear",),
            ],
        ),
    ]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"histories": histories}, indent=2) + "\n")
    print(f"wrote {OUT} ({len(histories)} histories)")


if __name__ == "__main__":
    main()
