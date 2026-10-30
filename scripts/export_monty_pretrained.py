"""Export Monty's pretrained object models as data the port can load.

Monty stores a pretrained learning module as a torch pickle, which the Elixir
port cannot read and should not try to: what a model *is* here is a position per
node and a row of features per node, and both are plain numbers. This script
pulls exactly those out — the columns the evidence-based learning module matches
on, and nothing else — and writes one object per line, gzipped.

    python scripts/export_monty_pretrained.py \\
        --model ~/tbp/results/monty/pretrained_models/pretrained_ycb_v10/\\
surf_agent_1lm_10distinctobj/pretrained/model.pt \\
        --out priv/monty/libraries/pretrained_ycb_v10/surf_agent_1lm_10distinctobj.jsonl.gz

Each line is one object and input channel:

    {"object_id": "mug", "input_channel": "patch",
     "positions": [[x, y, z], ...],
     "features": {"hsv": [[h, s, v], ...], ...}}

Features are the ones the learning module compares — `hsv`, `pose_vectors`,
`pose_fully_defined` and `principal_curvatures_log` — because a graph the port
only ever matches against does not need the rest, and fifteen numbers per node
keeps a ten-object model small enough to commit.

Every number is written at full precision, so the port reads the same 64 bits
Monty holds. Rounding was tried and measured: at six decimals a node's frame
off by `5e-7` is a pose off by `5e-7`, which is a displacement rotated a
millionth of a metre wrong each step, and — on a sphere, where many nodes match
the observation equally well — a different node chosen at the cut-off. The
rounding doubled nothing and cost `8 %` of one object's evidence; full precision
costs 2.3 times the file size and nothing else.

The pretrained models in `pretrained_ycb_v10` were trained with the older
feature-graph learning module, so they store `GraphObjectModel`s; the evidence
module loads them as they are (`use_original_graph`), which is why exporting the
stored graph rather than rebuilding one is the faithful thing to do.
"""

from __future__ import annotations

import argparse
import gzip
import json

import torch

FEATURES = ["hsv", "pose_vectors", "pose_fully_defined", "principal_curvatures_log"]


def _column(graph, feature_mapping, name):
    """The columns of `graph.x` holding one feature, as a list of numbers."""
    try:
        first, last = feature_mapping[name]
    except KeyError:
        raise SystemExit(f"the model has no {name!r} feature") from None

    return [[float(value) for value in row] for row in graph.x[:, first:last]]


def _objects(model_path):
    state = torch.load(model_path, map_location="cpu", weights_only=False)
    return state["lm_dict"][0]["graph_memory"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="a pretrained model.pt")
    parser.add_argument("--out", required=True, help="where to write the JSONL file")
    arguments = parser.parse_args()

    with gzip.open(arguments.out, "wt") as out:
        for object_id, channels in sorted(_objects(arguments.model).items()):
            for input_channel, channel_model in sorted(channels.items()):
                graph = channel_model._graph

                record = {
                    "object_id": object_id,
                    "input_channel": input_channel,
                    "positions": [
                        [float(value) for value in position] for position in graph.pos
                    ],
                    "features": {
                        name: _column(graph, graph.feature_mapping, name) for name in FEATURES
                    },
                }

                out.write(json.dumps(record) + "\n")
                print(f"{object_id}/{input_channel}: {len(record['positions'])} nodes")


if __name__ == "__main__":
    main()
