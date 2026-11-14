#!/usr/bin/env python3
"""How much of a part's memory maps onto itself under a half turn.

Recognition concludes only when one orientation is left. A part with a
symmetry cannot reach that: half of its orientations are the same picture, and
`unique_pose?/4` allows 20 degrees of disagreement, not 180. This asks a
written memory how much of it has a twin, which is the difference between a
part whose pose can be named and a part whose pose cannot — see
`docs/cad.md`, "why the blend never concludes".

For each of the part's three principal axes (the box's own axes, from the
point set's covariance) it turns every node by a half turn and asks whether the
turned point has a partner in the memory that agrees with it on

  * position, within two sampling spacings;
  * surface normal, within 15 degrees;
  * both principal curvatures in log space, within 1.0 (the matcher's own
    tolerance).

Position alone is not enough: a memory is sampled densely, so a turned point is
always near *some* node. What matters is whether the node it finds is the same
kind of surface, which is what the normal and the curvatures say.

    scripts/probe_part_symmetry.py /tmp/cad-experiment/blend
    scripts/probe_part_symmetry.py /tmp/cad-experiment/plate --object plate

Needs numpy and scipy: `~/src/monty-orig/.venv/bin/python scripts/probe_part_symmetry.py …`
"""

import argparse
import gzip
import json
import sys
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree

# The memory's file name, under a folder that holds `pretrained_ycb_v14/`.
LIBRARY = "pretrained_ycb_v14/surf_agent_1lm_10distinctobj.jsonl.gz"

NORMAL_TOLERANCE_DEGREES = 15.0
CURVATURE_TOLERANCE = 1.0
DRIFT_IN_SPACINGS = 2.0


def memory_path(where):
    """The memory file a folder or a file names."""
    path = Path(where)
    if path.is_file():
        return path
    return path / LIBRARY


def records(path):
    with gzip.open(path, "rt") as handle:
        for line in handle:
            yield json.loads(line)


def half_turn(axis):
    """A half turn about `axis` — a rotation, not a reflection."""
    axis = axis / np.linalg.norm(axis)
    return 2.0 * np.outer(axis, axis) - np.eye(3)


def twins(positions, normals, curvatures, axis):
    """Which nodes keep a partner under this half turn.

    Answered as a mask, because one axis is not the question: a node that keeps a
    partner under the first half turn may have none under the second, and only a
    node that keeps none under *any* of them can tell the placements apart.
    """
    centre = positions.mean(axis=0)
    turned = (positions - centre) @ half_turn(axis).T + centre
    turned_normals = normals @ half_turn(axis).T

    tree = cKDTree(positions)
    spacing = float(np.median(tree.query(positions, k=2)[0][:, 1]))

    nearest = tree.query(turned, k=1)[1]
    drift = np.linalg.norm(turned - positions[nearest], axis=1)
    same_normal = np.einsum("ij,ij->i", turned_normals, normals[nearest]) > np.cos(
        np.deg2rad(NORMAL_TOLERANCE_DEGREES)
    )
    same_curvature = (np.abs(curvatures - curvatures[nearest]) <= CURVATURE_TOLERANCE).all(
        axis=1
    )

    return same_normal & same_curvature & (drift <= DRIFT_IN_SPACINGS * spacing), spacing


def describe(path, wanted=None):
    for record in records(path):
        object_id = record["object_id"]
        if wanted and object_id not in wanted:
            continue

        features = record["features"]
        positions = np.array(record["positions"], dtype=float)
        # A pose vector is nine numbers: three rows of three, the surface normal first.
        normals = np.array(features["pose_vectors"], dtype=float)[:, 0:3]
        curvatures = np.array(features["principal_curvatures_log"], dtype=float)

        # The part's own axes are the eigenvectors of its point set's covariance.
        centred = positions - positions.mean(axis=0)
        _, axes = np.linalg.eigh(centred.T @ centred)

        shares = []
        twinned = np.zeros(len(positions), dtype=bool)
        for index in range(3):
            keeps, spacing = twins(positions, normals, curvatures, axes[:, index])
            # A node is not discriminating if *any* half turn gives it a partner.
            twinned |= keeps
            shares.append(100.0 * keeps.mean())

        extent = float(np.max(np.ptp(positions, axis=0)))
        print(
            f"{object_id}: {len(positions)} nodes, {spacing * 1000:.2f} mm apart, "
            f"{extent * 1000:.0f} mm across"
        )
        print(
            "   keeps a partner under each half turn: "
            + ", ".join(f"{share:.1f} %" for share in shares)
        )
        discriminating = int((~twinned).sum())
        plural = "" if discriminating == 1 else "s"
        print(
            f"   keeps none under any: {discriminating} node{plural} "
            f"({100.0 * (~twinned).mean():.1f} %) — the ones that can tell the others apart"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("memory", help="a memory file, or a folder holding one")
    parser.add_argument(
        "--object",
        action="append",
        default=None,
        help="only this object id (repeatable); every object by default",
    )
    arguments = parser.parse_args()

    path = memory_path(arguments.memory)
    if not path.exists():
        sys.exit(f"no memory at {path}")

    describe(path, set(arguments.object) if arguments.object else None)


if __name__ == "__main__":
    main()
