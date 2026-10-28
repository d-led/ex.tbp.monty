"""Record what a Monty experiment shows its learning module, step by step.

This is not part of the port: it is how the port gets a reference to compare
against. Monty runs in its own process against its own world, and this hook
writes down every message a learning module was given and what the module made
of it, so the Elixir implementation can be handed the same observations and
held to the same answers.

    python scripts/record_monty_episode.py \\
        experiment=base_config_10distinctobj_surf_agent \\
        +experiment.config.n_train_epochs=0 \\
        +experiment.config.n_eval_epochs=1 \\
        +experiment.config.step_hook={_target_: record_monty_episode.Recorder,out:recordings/eval.jsonl}

The script runs inside the Monty checkout's environment (`conda activate
tbp.monty`) with that checkout's `run.py` on the path, and adds its own
directory to `sys.path` so Hydra can import `Recorder` by name.

Each line of the output is one step:

    {"episode_step": 0, "total_step": 0, "step_type": "matching_step",
     "mode": "eval",
     "learning_modules": {"learning_module_0": {"inputs": [...], "state": {...}}}}

`inputs` are the messages the module was given on that step, in order, in the
shape the cortical messaging protocol defines. `state` is what it concluded
afterwards: the terminal state, the possible matches, and the most likely
hypothesis. A new episode starts wherever `episode_step` is zero.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))


def _plain(value):
    """Turns the arrays and enums Monty uses into JSON."""
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.floating):
        return float(value)
    if isinstance(value, np.integer):
        return int(value)
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _plain(item) for key, item in value.items()}
    if hasattr(value, "value") and not isinstance(value, (str, bytes)):
        return _plain(value.value)
    return value


def _message(percept):
    """One CMP message, in the fields the receiving module reads."""
    features = {}

    for name, value in (percept.morphological_features or {}).items():
        features[name] = _plain(getattr(value, "value", value))

    return {
        "sender_id": percept.sender_id,
        "sender_type": percept.sender_type,
        "location": _plain(percept.location),
        "confidence": _plain(percept.confidence),
        "pass_message": percept.pass_message,
        "process_features_in_lm": percept.process_features_in_lm,
        "morphological_features": features,
        "non_morphological_features": _plain(percept.non_morphological_features or {}),
    }


def _state(module):
    """What the module concluded after the step, and how sure it is."""
    mlh = dict(module.current_mlh)
    evidence = {}

    for graph_id, hypotheses in getattr(module, "_hypotheses", {}).items():
        if len(hypotheses.evidence):
            evidence[graph_id] = {
                "hypotheses": int(len(hypotheses.evidence)),
                "max_evidence": _plain(np.max(hypotheses.evidence)),
            }

    return {
        "terminal_state": module.terminal_state,
        "possible_matches": _plain(list(module.get_possible_matches())),
        "detected_object": module.detected_object,
        "mlh": {
            "graph_id": mlh.get("graph_id"),
            "mlh_id": _plain(mlh.get("mlh_id")),
            "location": _plain(mlh.get("location")),
            "rotation_quaternion": _plain(mlh["rotation"].as_quat()),
            "evidence": _plain(mlh.get("evidence")),
        },
        "graphs": evidence,
    }


class Recorder:
    """A Monty step hook that writes down what every module was given."""

    def __init__(self, out: str) -> None:
        self._out = Path(out)
        self._out.parent.mkdir(parents=True, exist_ok=True)
        self._handle = self._out.open("w")
        self._seen = {}

    def __call__(self, ctx, monty, supervised_lm_ids, step, observations, actions):
        record = {
            "episode_step": int(monty.episode_steps),
            "total_step": int(monty.total_steps),
            "step_type": monty.step_type,
            "mode": None if monty.experiment_mode is None else str(monty.experiment_mode),
            "learning_modules": {},
        }

        for index, module in enumerate(monty.learning_modules):
            module_id = getattr(module, "learning_module_id", f"learning_module_{index}")
            percepts = list(module.buffer.input_percepts)
            # The buffer keeps every percept of the episode; only the ones since
            # the last step belong to this record. A step's percepts are stored
            # as the list it was given, so both shapes are flattened here.
            seen = self._seen.get(module_id, 0)
            self._seen[module_id] = len(percepts)
            step_percepts = [
                percept
                for entry in percepts[seen:]
                for percept in (entry if isinstance(entry, list) else [entry])
            ]

            record["learning_modules"][module_id] = {
                "inputs": [_message(percept) for percept in step_percepts],
                "state": _state(module),
            }

        self._handle.write(json.dumps(record) + "\n")
        self._handle.flush()
        return actions

    def close(self) -> None:
        self._handle.close()


def main() -> None:
    """Runs the experiment named on the command line, through Monty's runner."""
    from hydra import compose, initialize_config_module
    from omegaconf import OmegaConf

    # Monty's configs read paths from the environment (`MONTY_DATA`,
    # `MONTY_MODELS`, `MONTY_LOGS`), and its runner sets them before anything
    # else touches a config.
    from tbp.monty.frameworks.run_env import setup_env
    from tbp.monty.hydra import instantiate_experiment

    setup_env()

    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, help="where the recording goes")
    parser.add_argument("overrides", nargs="*", help="Hydra overrides, e.g. experiment=...")
    arguments = parser.parse_args()

    with initialize_config_module("tbp.monty.conf", version_base=None):
        cfg = compose(config_name="experiment", overrides=arguments.overrides)

    # The hook is not a config group: Monty reads it off the experiment config
    # if it is there, so it is added after composition.
    OmegaConf.set_struct(cfg, False)
    cfg.experiment.config.step_hook = {
        "_target_": "record_monty_episode.Recorder",
        "out": arguments.out,
    }

    experiment = instantiate_experiment(cfg.experiment)
    with experiment:
        experiment.run()


if __name__ == "__main__":
    main()
