"""Record how Monty numbers the objects of an experiment.

`OneObjectPerEpisodeInterface` decides which object an episode is about and which
semantic id the world should stamp it with. Every position of the port that had to
guess — "the target is 1", "there are no distractors" — is this class's answer, so
it is worth recording rather than assuming.

    python3 scripts/record_monty_interface_objects.py

Needs an interpreter with Monty's dependencies, including `omegaconf`.

## What is recorded

A stub environment stands in for Habitat: it records the objects it is asked to
add and remove, and answers an object with an id. The interface's arithmetic —
the semantic mapping, which object comes next, which distractors are sampled —
is Monty's own, and that is what is written down:

  - three shapes of `object_names`: a list with a repeated name, a plain list, and
    a mapping with a source list and a distractor count;
  - the semantic mapping in both directions;
  - `change_object_by_idx` as the *calls* it makes and the `primary_target` it
    sets, plus the two ways it refuses an index;
  - the distractor objects sampled for a seeded stream, names and ids;
  - `cycle_object` wrapping past the end of the list.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

MONTY_SRC = Path(__file__).resolve().parents[2] / "monty-orig" / "src"
sys.path.insert(0, str(MONTY_SRC))

import numpy as np  # noqa: E402

try:
    from tbp.monty.experiment.environment import (  # noqa: E402
        OneObjectPerEpisodeInterface,
    )
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
    / "monty_interface_objects.json"
)


class AddedObject:
    """What `env.add_object` answers: something with an object id."""

    def __init__(self, object_id):
        self.object_id = object_id


class StubEnvironment:
    """A scene that records what it is asked to add and remove."""

    def __init__(self):
        self.calls = []
        self.objects = 0

    def reset(self):
        self.calls.append({"call": "reset"})
        return {"observations": {}}, {"state": {}}

    def remove_all_objects(self):
        self.calls.append({"call": "remove_all_objects"})

    def add_object(self, name, position, rotation, scale, semantic_id, primary_target_object=None):
        self.objects += 1
        self.calls.append(
            {
                "call": "add_object",
                "name": name,
                "semantic_id": semantic_id,
                "position": [float(value) for value in position],
                "rotation": [float(value) for value in rotation],
                "scale": [float(value) for value in scale],
                "has_primary_target_object": primary_target_object is not None,
            }
        )
        return AddedObject(self.objects)


def _object_params(seed, mode, epoch, episode):  # noqa: ARG001 - Monty's signature
    """The sampler: a fixed pose, so a recording is about the interface alone."""
    return {"position": [0.1, 0.2, 0.3], "rotation": [0.0, 45.0, 0.0], "scale": [1.0, 1.0, 1.0]}


def _interface(object_names, num_object_seed=0, environment=None):
    return OneObjectPerEpisodeInterface(
        object_names=object_names,
        object_init_sampler=_object_params,
        positioning_procedures=None,
        env=environment or StubEnvironment(),
        rng=np.random.RandomState(num_object_seed),
        seed=0,
        experiment_mode=ExperimentMode.EVAL,
    )


def _mapping(interface):
    return {
        "semantic_label_to_id": {
            label: int(semantic_id)
            for label, semantic_id in interface.semantic_label_to_id.items()
        },
        "semantic_id_to_label": {
            int(semantic_id): label
            for semantic_id, label in interface.semantic_id_to_label.items()
        },
        "object_names": list(interface.object_names),
        "source_object_list": list(interface.source_object_list),
        "num_distractors": int(interface.num_distractors),
        "n_objects": int(interface.n_objects),
    }


def _calls(environment, since):
    return environment.calls[since:]


def main():
    shapes = {}

    # A repeated name: the mapping is over the *deduplicated* list, in the order
    # the names first appear.
    for name, object_names in [
        ("a list with a repeated name", ["cone", "sphere", "cone", "cube"]),
        ("a plain list", ["cone", "sphere", "cube"]),
        (
            "a mapping with distractors",
            {
                "targets_list": ["cone", "sphere"],
                "source_object_list": ["cone", "sphere", "cube", "cylinder"],
                "num_distractors": 2,
            },
        ),
    ]:
        environment = StubEnvironment()
        interface = _interface(object_names, environment=environment)
        shapes[name] = _mapping(interface)

    # -- which object an episode is about ------------------------------------
    environment = StubEnvironment()
    interface = _interface(["cone", "sphere", "cube"], environment=environment)

    since = len(environment.calls)
    interface.change_object_by_idx(1)
    second_object = {
        "calls": _calls(environment, since),
        "primary_target": interface.primary_target,
        "current_object": int(interface.current_object),
    }

    since = len(environment.calls)
    interface.cycle_object()
    cycled = {
        "calls": _calls(environment, since),
        "primary_target": interface.primary_target,
        "current_object": int(interface.current_object),
    }

    # Past the end is a wrap, not an error — `cycle_object` is what moves an
    # episode on.
    interface.change_object_by_idx(2)
    since = len(environment.calls)
    interface.cycle_object()
    wrapped = {"current_object": int(interface.current_object)}

    refusals = {}
    for idx in [-1, 3]:
        try:
            interface.change_object_by_idx(idx)
        except IndexError as error:
            refusals[str(idx)] = {"raises": type(error).__name__, "message": str(error)}

    # -- distractors ---------------------------------------------------------
    environment = StubEnvironment()
    interface = _interface(
        {
            "targets_list": ["cone", "sphere"],
            "source_object_list": ["cone", "sphere", "cube", "cylinder"],
            "num_distractors": 2,
        },
        num_object_seed=7,
        environment=environment,
    )

    since = len(environment.calls)
    interface.change_object_by_idx(0)
    with_distractors = {
        "calls": _calls(environment, since),
        "primary_target": interface.primary_target,
    }

    fixture = {
        "shapes": shapes,
        "second object": second_object,
        "cycled": cycled,
        "wrapped": wrapped,
        "refusals": refusals,
        "with distractors": with_distractors,
        "object_params": _object_params(0, None, 0, 0),
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixture, indent=1) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
