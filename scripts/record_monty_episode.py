"""Record what a Monty experiment shows its learning module, step by step.

This is not part of the port: it is how the port gets a reference to compare
against. Monty runs in its own process against its own world, and this hook
writes down every message a learning module was given and what the module made
of it, so the Elixir implementation can be handed the same observations and
held to the same answers.

It has to import the Monty checkout it is recording, so both path entries are
absolute — a relative `src` resolves against the working directory and quietly
picks whichever Monty the interpreter's own site-packages installed:

    MONTY=/path/to/monty-orig PORT=/path/to/ex.tbp.monty
    PYTHONPATH="$MONTY/src:$PORT/scripts" \\
        "$CONDA_PREFIX/bin/python" "$PORT/scripts/record_monty_episode.py" \\
        --out /tmp/monty-episode/recording.jsonl \\
        experiment=base_config_10distinctobj_dist_agent \\
        logging=basic_info_monty_runs \\
        constants.pretrained_dir="$MONTY_MODELS/pretrained_ycb_v10" \\
        experiment.config.n_eval_epochs=1 \\
        experiment.config.logging.output_dir=/tmp/monty-episode/rec

Recorded against Monty at 9130364 in its pinned environment (Python 3.8.20,
`torch` 1.13.1, `habitat_sim` 0.2.2): ten episodes of
`base_config_10distinctobj_dist_agent`, 338 steps, every episode `correct` in
21-38 matching steps.

Each line of the output is one step:

    {"episode_step": 4, "total_step": 4, "step_type": "matching_step",
     "mode": "ExperimentModes.EVAL",
     "learning_modules": {"learning_module_0": {"inputs": [...], "state": {...}}}}

`inputs` are the messages the module was given on that step, in order, in the
shape the cortical messaging protocol defines. `state` is what it concluded
afterwards: the terminal state, the possible matches, and the most likely
hypothesis. A new episode starts wherever `episode_step` goes backwards.

Two environment variables widen it, and both are off by default because the
usual recording is already the whole of what a replay needs:

* `MONTY_RECORD_EVIDENCE=1` adds, per graph, the evidence of every hypothesis
  and where each one sits — for the comparison that has to go inside a graph
  rather than stop at its best number.
* `MONTY_RECORD_STEPS=N` keeps only the first `N` steps of each episode. The
  run still finishes; what changes is how much of it is written.
"""

from __future__ import annotations

import argparse
import json
import os
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
    # A rotation is a `quaternion`, which JSON has no word for; the four
    # components in Monty's `wxyz` order are the word it does have.
    if hasattr(value, "components") and hasattr(value, "w"):
        return [_plain(part) for part in value.components]
    if hasattr(value, "value") and not isinstance(value, (str, bytes)):
        return _plain(value.value)
    return value


def _action(action):
    """One action, as the map it crosses a boundary as — Monty's own encoder."""
    from tbp.monty.frameworks.actions.actions import ActionJSONEncoder

    return _plain(ActionJSONEncoder().default(action))


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
    # How many of a graph's hypotheses are inside `x_percent_threshold` of its
    # best one: exactly the set the pose test is given, so a port whose pose
    # count differs can be told whether its evidence does.
    x_percent = getattr(module, "x_percent_threshold", 20)

    for graph_id, hypotheses in getattr(module, "_hypotheses", {}).items():
        if len(hypotheses.evidence):
            scores = np.asarray(hypotheses.evidence, dtype=float)
            best = float(np.max(scores))
            evidence[graph_id] = {
                "hypotheses": int(len(scores)),
                "max_evidence": _plain(best),
                "within_x_percent": int(np.sum(scores > best - best / 100 * x_percent))
                if best > 0
                else 0,
                "top_evidence": _plain(np.sort(scores)[-5:][::-1]),
            }

            # Where the difference is *inside* a graph: the evidence of every
            # hypothesis, and where each of them sits. Off unless asked for, as
            # a graph can carry thousands of hypotheses a step and the four
            # numbers above are enough to see that two implementations differ
            # before one of them has to be taken apart.
            if os.environ.get("MONTY_RECORD_EVIDENCE"):
                evidence[graph_id]["evidence_all"] = _plain(scores)
                evidence[graph_id]["locations_all"] = _plain(
                    np.asarray(hypotheses.locations, dtype=float)
                )
                # Monty keeps each hypothesis' pose as a rotation matrix, so the
                # array itself is what is written — its layout is the port's
                # business, not the recording's.
                evidence[graph_id]["poses_all"] = _plain(
                    np.asarray(hypotheses.poses, dtype=float)
                )

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
        # The pose-uniqueness test is why an episode ends when it ends: one
        # object left is not enough if its pose is still ambiguous. These are
        # the numbers it turned on, so a reimplementation can be held to them
        # and not only to the conclusion that followed.
        "symmetry_evidence": int(getattr(module, "symmetry_evidence", 0)),
        "unique_poses": getattr(module, "_recorded_unique_poses", None),
    }


def _record_unique_poses() -> None:
    """Wraps Monty's pose-uniqueness test so its two numbers can be recorded.

    `EvidenceGraphLM._check_for_unique_poses` answers one boolean; whether the
    possible locations are close enough and whether the possible rotations are
    close enough are two separate questions, and a port that disagrees with
    Monty needs to know which one. The wrapper computes the same two maxima
    with Monty's own arrays and thresholds and records them beside the verdict.
    """
    from tbp.monty.frameworks.models.evidence_matching.learning_module import (
        EvidenceGraphLM,
    )

    original = EvidenceGraphLM._check_for_unique_poses
    if getattr(original, "_records_unique_poses", False):
        return

    def wrapped(self, graph_id, possible_object_hypotheses_ids, most_likely_r):
        unique = original(self, graph_id, possible_object_hypotheses_ids, most_likely_r)
        ids = np.asarray(possible_object_hypotheses_ids, dtype=np.int64)
        hypotheses = self._hypotheses[graph_id]

        recorded = {
            "poses": int(len(ids)),
            "ids": _plain(ids) if len(ids) <= 32 else None,
            "unique": bool(unique),
            "path_similarity_threshold": self.path_similarity_threshold,
            "pose_similarity_threshold": self.pose_similarity_threshold,
        }

        if len(ids):
            locations = np.array(hypotheses.locations)[ids]
            centre = np.mean(locations, axis=0)
            rotations = np.array(hypotheses.poses)[ids]
            trace = np.trace(
                most_likely_r.as_matrix().T @ rotations, axis1=1, axis2=2
            )
            turns = np.arccos(np.clip((trace - 1) / 2, -1, 1))

            recorded["spread"] = float(
                np.max(np.linalg.norm(locations - centre, axis=1))
            )
            recorded["turn"] = float(np.max(np.nan_to_num(turns)))

        self._recorded_unique_poses = recorded
        return unique

    wrapped._records_unique_poses = True
    EvidenceGraphLM._check_for_unique_poses = wrapped


class Recorder:
    """A Monty step hook that writes down what every module was given."""

    def __init__(self, out: str) -> None:
        self._out = Path(out)
        self._out.parent.mkdir(parents=True, exist_ok=True)
        self._handle = self._out.open("w")
        self._seen = {}

    def __call__(self, ctx, monty, supervised_lm_ids, step, observations, actions):
        # A new episode resets the buffer every module keeps, so the cursor into
        # it has to go too. Without this the episode's first percept is read as
        # "already seen" — it is the one step of a new episode whose count is
        # smaller than the previous episode's, and it is the step a replay needs
        # most.
        if monty.episode_steps == 1:
            self._seen = {}

        # An episode is stopped being written, not stopped: `MONTY_RECORD_STEPS`
        # keeps the first N steps of each episode, which is what a comparison of
        # one increment needs, and leaves the run to finish on its own.
        limit = int(os.environ.get("MONTY_RECORD_STEPS") or 0)
        if limit and monty.episode_steps > limit:
            return actions

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

        # What the model asked the world for after this step's percepts. The
        # world answers a step's actions with the next step's observations, so
        # this is the other half of a comparison: two runs that see the same
        # things and choose different actions disagree in the model, and two
        # that agree here and diverge later disagree in the world.
        record["actions"] = [_action(action) for action in actions]

        # Where the episode's one random stream stands after this step, so a port
        # that draws its own numbers can be told the step it stopped drawing the
        # same *number* of them: the position is the word the next draw reads.
        stream_state = ctx.rng.get_state()
        record["rng"] = {"pos": int(stream_state[2]), "gauss": int(stream_state[3])}

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

    _record_unique_poses()

    experiment = instantiate_experiment(cfg.experiment)
    with experiment:
        experiment.run()


if __name__ == "__main__":
    main()
