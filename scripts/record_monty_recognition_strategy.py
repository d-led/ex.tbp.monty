"""Record what Monty's recognition policies decide, state by state.

The recognition policy is what turns "the learning modules have said something"
into "this episode is over". It is pure decision logic, so it can be compared
exactly: every policy is asked the same questions of the same states, and the
port must answer the same three booleans.

    MONTY=/path/to/monty-orig
    PYTHONPATH="$MONTY/src" "$CONDA_PREFIX/bin/python" \\
        scripts/record_monty_recognition_policy.py --out test/fixtures/...json

Nothing here needs a simulator or a trained model: a stub model carries the four
things the policies read.

Sections of the output:

    policies:  one entry per policy and its configuration
    refusals:  the ValueError each bad configuration raises, verbatim
    decisions: one line per (policy, state, counter), with Monty's three
               booleans and, for the wrapped policies, the inner policy's answer
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from tbp.monty.experiment.recognition_policy import (
    AnyPolicy,
    MaxTotalSteps,
    MaximumSteps,
    MinEvalMaxTotalSteps,
    MinimumLMs,
    MontyIsDone,
    NaiveScan,
    ObjectRecognition,
    RecognitionCounter,
    StepLimit,
)
from tbp.monty.experiment.recognition_status import (
    RecognitionConclusion,
    RecognitionStatus,
)
from tbp.monty.frameworks.experiments.mode import ExperimentMode


class StubStatus:
    """Just the field `MinimumLMs` reads."""

    def __init__(self, conclusion):
        self.conclusion = conclusion


class StubLM:
    def __init__(self, conclusion):
        self.recognition_status = StubStatus(conclusion)


class StubModel:
    """The four things a recognition policy is allowed to look at."""

    def __init__(self, is_done, is_exploring, matching_steps, matched_lms):
        self.is_done = is_done
        self.is_exploring = is_exploring
        self.matching_steps = matching_steps
        self.learning_modules = [
            StubLM(RecognitionConclusion.MATCH if index < matched_lms else None)
            for index in range(3)
        ]


def _states():
    """The states worth asking about: every branch and every boundary.

    A full product of these dimensions would be thousands of rows that repeat
    each other; these are chosen so that each policy's branches are crossed at
    least once, at the step and count they turn on.
    """
    rows = [
        # (is_done, is_exploring, matching, exploring, step, mode, matched_lms)
        (False, False, 0, 0, 0, "EVAL", 0),
        (False, False, 0, 0, 1, "EVAL", 0),
        (False, False, 5, 0, 19, "EVAL", 0),
        (False, False, 5, 0, 20, "EVAL", 0),
        # The same state while training: a wrapper that holds an episode open
        # for minimum evaluation must not hold a training episode open.
        (False, False, 5, 0, 20, "TRAIN", 0),
        (False, False, 19, 0, 19, "EVAL", 0),
        (False, False, 20, 0, 20, "EVAL", 0),
        (False, False, 499, 0, 499, "EVAL", 0),
        (False, False, 500, 0, 500, "EVAL", 0),
        (False, False, 999, 0, 999, "EVAL", 0),
        (False, False, 1000, 0, 1000, "EVAL", 0),
        (False, False, 10, 0, 72, "EVAL", 0),
        (False, False, 10, 0, 73, "EVAL", 0),
        (False, False, 10, 0, 5999, "EVAL", 0),
        (False, False, 10, 0, 6000, "EVAL", 0),
        (False, False, 10, 0, 8010, "EVAL", 0),
        (False, False, 10, 0, 8011, "EVAL", 0),
        (True, False, 0, 0, 0, "EVAL", 0),
        (True, False, 1, 0, 1, "EVAL", 0),
        (False, False, 19, 0, 19, "TRAIN", 0),
        (False, False, 20, 0, 20, "TRAIN", 0),
        (False, False, 999, 0, 999, "TRAIN", 0),
        (False, False, 1000, 0, 1000, "TRAIN", 0),
        (False, True, 0, 0, 5, "EVAL", 0),
        (False, True, 0, 99, 99, "EVAL", 0),
        (False, True, 0, 100, 100, "EVAL", 0),
        (True, True, 0, 100, 100, "EVAL", 0),
        (False, True, 0, 0, 10, "TRAIN", 0),
        (False, True, 0, 50, 50, "TRAIN", 3),
        (False, False, 10, 0, 10, "EVAL", 1),
        (False, False, 10, 0, 10, "EVAL", 3),
        (True, True, 0, 100, 100, "TRAIN", 3),
    ]

    for is_done, is_exploring, matching, exploring, step, mode, matched in rows:
        yield {
            "model": {
                "is_done": is_done,
                "is_exploring": is_exploring,
                "matching_steps": matching,
                "matched_lms": matched,
            },
            "counter": {
                "step": step,
                "matching_steps": matching,
                "exploring_steps": exploring,
                "mode": mode,
            },
        }


def _policies():
    """The policies the shipped configs use, and the ones they wrap."""
    object_recognition = ObjectRecognition(
        max_train_steps=1000, max_eval_steps=500, max_total_steps=6000
    )
    return {
        "MontyIsDone": MontyIsDone(),
        "MaxTotalSteps(20)": MaxTotalSteps(max_total_steps=20),
        "MaximumSteps(1000, 500)": MaximumSteps(
            max_train_steps=1000, max_eval_steps=500
        ),
        "StepLimit(20, 100, 1000, 500)": StepLimit(
            min_train_steps=20,
            num_exploring_steps=100,
            max_train_steps=1000,
            max_eval_steps=500,
        ),
        "MinimumLMs(1)": MinimumLMs(min_lms=1),
        "MinimumLMs(3)": MinimumLMs(min_lms=3),
        "NaiveScan(1)": NaiveScan(fixed_amount=1),
        "NaiveScan(5)": NaiveScan(fixed_amount=5),
        "NaiveScan(90)": NaiveScan(fixed_amount=90),
        "ObjectRecognition(1000, 500, 6000)": object_recognition,
        "AnyPolicy([MaximumSteps, MaxTotalSteps])": AnyPolicy(
            [MaximumSteps(max_train_steps=1000, max_eval_steps=500), MaxTotalSteps(6000)]
        ),
        "MinEvalMaxTotalSteps(ObjectRecognition, 20, 6000)": MinEvalMaxTotalSteps(
            object_recognition, min_eval_steps=20, max_total_steps=6000
        ),
        "MinEvalMaxTotalSteps(MaxTotalSteps(20), 20, 6000)": MinEvalMaxTotalSteps(
            MaxTotalSteps(max_total_steps=20), min_eval_steps=20, max_total_steps=6000
        ),
        "AnyPolicy([MinEvalMaxTotalSteps, StepLimit])": AnyPolicy(
            [
                MinEvalMaxTotalSteps(
                    object_recognition, min_eval_steps=20, max_total_steps=6000
                ),
                StepLimit(),
            ]
        ),
    }


REFUSALS = [
    ("MaxTotalSteps", lambda: MaxTotalSteps(max_total_steps=0)),
    ("MaximumSteps", lambda: MaximumSteps(max_train_steps=0, max_eval_steps=500)),
    ("MaximumSteps.eval", lambda: MaximumSteps(max_train_steps=1000, max_eval_steps=0)),
    ("MinimumLMs", lambda: MinimumLMs(min_lms=0)),
    ("NaiveScan", lambda: NaiveScan(fixed_amount=0)),
    ("AnyPolicy", lambda: AnyPolicy([])),
    (
        "ObjectRecognition.total",
        lambda: ObjectRecognition(
            max_train_steps=1000, max_eval_steps=500, max_total_steps=0
        ),
    ),
    (
        "StepLimit.min",
        lambda: StepLimit(min_train_steps=-1, max_train_steps=1000, max_eval_steps=500),
    ),
    (
        "StepLimit.exploring",
        lambda: StepLimit(num_exploring_steps=-1, max_train_steps=1000, max_eval_steps=500),
    ),
    (
        "MinEvalMaxTotalSteps.min",
        lambda: MinEvalMaxTotalSteps(MontyIsDone(), min_eval_steps=-1),
    ),
    (
        "MinEvalMaxTotalSteps.total",
        lambda: MinEvalMaxTotalSteps(MontyIsDone(), max_total_steps=0),
    ),
    (
        "MinEvalMaxTotalSteps.order",
        lambda: MinEvalMaxTotalSteps(
            MontyIsDone(), min_eval_steps=500, max_total_steps=20
        ),
    ),
]


def _result(result):
    return {
        "is_done": bool(result.is_done),
        "time_out_lms": bool(result.time_out_lms),
        "start_exploring": bool(result.start_exploring),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()

    policies = _policies()

    decisions = []
    for name, policy in policies.items():
        for state in _states():
            model_state = state["model"]
            model = StubModel(
                is_done=model_state["is_done"],
                is_exploring=model_state["is_exploring"],
                matching_steps=model_state["matching_steps"],
                matched_lms=model_state["matched_lms"],
            )
            counter_state = state["counter"]
            counter = RecognitionCounter(
                step=counter_state["step"],
                matching_steps=counter_state["matching_steps"],
                exploring_steps=counter_state["exploring_steps"],
                mode=ExperimentMode[counter_state["mode"]],
            )
            decisions.append(
                {
                    "policy": name,
                    "model": model_state,
                    "counter": counter_state,
                    "result": _result(policy(model, counter)),
                }
            )

    refusals = {}
    for name, build in REFUSALS:
        try:
            build()
        except ValueError as error:
            refusals[name] = {"raises": "ValueError", "message": str(error)}

    output = {
        "monty": "tbp.monty.experiment.recognition_policy",
        "policies": sorted(policies),
        "recognition_status": {
            "conclusions": [member.value for member in RecognitionConclusion],
            "default": {
                "conclusion": RecognitionStatus().conclusion,
                "telemetry": RecognitionStatus().telemetry,
            },
        },
        "refusals": refusals,
        "decisions": decisions,
    }

    path = Path(arguments.out)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(output, indent=1) + "\n")
    print(f"{len(decisions)} decisions over {len(policies)} policies -> {path}")


if __name__ == "__main__":
    main()
