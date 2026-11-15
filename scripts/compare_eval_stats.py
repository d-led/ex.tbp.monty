#!/usr/bin/env python3
"""Compare `eval_stats.csv` files from Monty or from this port.

One file is a run's profile; two or more are compared, each against the first,
episode by episode where the runs share an episode and distribution by
distribution where they do not — so a run of twenty episodes can be read
against a run of a hundred and forty without pretending they share a seed.

The file is Monty's, so the vocabulary is Monty's: `primary_performance` says
what the learning module concluded (`correct`, `confused`, `pose_time_out`,
`no_match`, `patch_off_object`), `TFNP` says whether the target was among the
possible matches, and the step and time columns say what the episode cost.

    scripts/compare_eval_stats.py a.csv
    scripts/compare_eval_stats.py a.csv b.csv
    scripts/compare_eval_stats.py ours.csv monty.csv --json report.json

Only the standard library is used: this runs on whichever machine holds the
CSVs, not on one with a data stack installed.
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

# What a reader wants to know from an outcome, whichever run wrote it. The port
# once wrote `match` for a module that had recognised its target without
# judging it; an older file is still readable, and says so rather than being
# counted as correct.
JUDGEMENTS = {
    "correct": "recognised",
    "correct_mlh": "recognised",
    "confused": "confused",
    "confused_mlh": "confused",
    "pose_time_out": "matched_pose_unfound",
    "no_match": "unrecognised",
    "time_out": "unrecognised",
    "patch_off_object": "left_object",
    "no_label": "unlabelled",
    "match": "matched_unjudged",
}

# Why an episode ended: the recognition policy's own answer, read off the same
# column, because the policy is what ends an episode.
EXITS = {
    "correct": "matched",
    "correct_mlh": "matched",
    "confused": "matched",
    "confused_mlh": "matched",
    "match": "matched",
    "pose_time_out": "pose_not_converged",
    "no_match": "steps_exhausted",
    "time_out": "steps_exhausted",
    "patch_off_object": "no_surface",
    "no_label": "no_label",
}

TARGET_FOUND = {
    "target_in_possible_matches_(TP)": "target_found",
    "target_not_matched_(FN)": "target_missed",
    "unknown_object_in_possible_matches_(FP)": "unknown_object",
}

MPER_FIELDS = {
    "num_steps": "sensor steps",
    "monty_steps": "steps over all modules",
    "monty_matching_steps": "matching steps",
    "time": "seconds",
    "num_possible_matches": "possible matches",
    "symmetry_evidence": "symmetry evidence",
}


def number(row, column):
    """A column as a float, or `None` when it is absent, blank or not a number."""
    raw = (row.get(column) or "").strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def vector(row, column):
    """A numpy-style vector as written into the CSV: `[0.1 0.2 0.3]`."""
    raw = (row.get(column) or "").strip()
    if not raw:
        return None
    inner = raw.strip("[]()")
    parts = [part for part in inner.replace(",", " ").split() if part]
    try:
        return [float(part) for part in parts]
    except ValueError:
        return None


def distance(left, right):
    if left is None or right is None or len(left) != len(right):
        return None
    return sum((a - b) ** 2 for a, b in zip(left, right)) ** 0.5


def judgement(row):
    raw = (row.get("primary_performance") or "").strip()
    return JUDGEMENTS.get(raw, f"other:{raw}" if raw else "unrecorded")


def exit_reason(row):
    raw = (row.get("primary_performance") or "").strip()
    return EXITS.get(raw, f"other:{raw}" if raw else "unrecorded")


def target_found(row):
    raw = (row.get("TFNP") or "").strip()
    return TARGET_FOUND.get(raw, f"other:{raw}" if raw else "unrecorded")


def pose_error(row):
    """How far the recognised pose was from the object's, in the world."""
    return distance(vector(row, "detected_location"), vector(row, "primary_target_position"))


def read_rows(path):
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle))


def seeds_of(rows):
    return {(row.get("episode_seed") or "").strip() for row in rows}


def rows_of(path):
    """The rows of a run: a CSV file, a run folder, or a divided run's folder.

    A divided run reports each part into its own directory while the parts run
    and merges them when they are done, so a folder may hold both. The merged
    file wins when it holds every part's episodes — reading both would count
    each episode twice — and the parts are read when it does not, which is what
    a run still in flight has.
    """
    if not path.is_dir():
        return [path], read_rows(path)

    merged = path / "eval_stats.csv"
    parts = sorted((path / "parts").glob("*/eval_stats.csv"))
    if not parts:
        return ([merged], read_rows(merged)) if merged.exists() else ([], [])

    part_rows = [row for part in parts for row in read_rows(part)]
    if not merged.exists():
        return parts, part_rows
    if seeds_of(part_rows) <= seeds_of(read_rows(merged)):
        return [merged], read_rows(merged)
    return parts, part_rows


@dataclass
class Run:
    path: Path
    rows: list = field(default_factory=list)
    duplicates: int = 0
    by_seed: dict = field(default_factory=dict)
    seeded: bool = True
    label: str = ""
    files: list = field(default_factory=list)

    @classmethod
    def read(cls, path, label=None):
        files, rows = rows_of(Path(path))
        run = cls(path=Path(path), rows=rows, label=label or cls.short_name(path), files=files)
        seeds = [(row.get("episode_seed") or "").strip() for row in rows]
        run.seeded = all(seed.lstrip("-").isdigit() for seed in seeds) and bool(rows)
        for index, row in enumerate(rows):
            key = int((row.get("episode_seed") or "0").strip() or 0) if run.seeded else index
            if key in run.by_seed:
                run.duplicates += 1
            run.by_seed[key] = row
        return run

    @staticmethod
    def short_name(path):
        name = Path(path).name or Path(path).parent.name
        return name if len(name) <= 28 else name[:25] + "..."

    @property
    def name(self):
        return self.label

    def values(self, column):
        return [value for value in (number(row, column) for row in self.rows) if value is not None]

    def metrics(self):
        found = [pose_error(row) for row in self.rows]
        found = [value for value in found if value is not None]
        stats = {label: describe(self.values(column)) for column, label in MPER_FIELDS.items()}
        stats["pose error (m)"] = describe(found)
        stats["rotation error (deg)"] = describe(self.values("rotation_error"))
        return stats

    def distributions(self):
        return {
            "outcome": Counter(judgement(row) for row in self.rows),
            "exit": Counter(exit_reason(row) for row in self.rows),
            "target": Counter(target_found(row) for row in self.rows),
        }


def describe(values):
    if not values:
        return None
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "mean": statistics.mean(ordered),
        "median": statistics.median(ordered),
        "p90": ordered[min(len(ordered) - 1, int(round(0.9 * (len(ordered) - 1))))],
        "max": ordered[-1],
    }


def format_number(value):
    if value is None:
        return "-"
    if abs(value) >= 1000:
        return f"{value:,.0f}"
    if abs(value) >= 10:
        return f"{value:.1f}"
    return f"{value:.3f}".rstrip("0").rstrip(".") or "0"


def table(header, rows, out):
    widths = [len(cell) for cell in header]
    for row in rows:
        widths = [max(width, len(cell)) for width, cell in zip(widths, row)]
    for row in [header, *rows]:
        out.write("  ".join(cell.ljust(width) for cell, width in zip(row, widths)) + "\n")


def distribution_table(title, counts_by_run, out):
    counts_by_run = {name: counts for name, counts in counts_by_run.items() if counts}
    if not counts_by_run:
        return
    names = list(counts_by_run)
    labels = sorted({label for counts in counts_by_run.values() for label in counts})
    rows = []
    for label in labels:
        row = [label]
        for name in names:
            counts = counts_by_run[name]
            total = sum(counts.values()) or 1
            count = counts.get(label, 0)
            row.append(f"{count} ({100 * count / total:.0f}%)")
        rows.append(row)
    out.write(f"\n{title}\n")
    table(["", *names], rows, out)


def coverage(runs, out):
    out.write("\ncoverage\n")
    rows = []
    for run in runs:
        rows.append(
            [
                run.name,
                str(len(run.rows)),
                str(len(run.by_seed)),
                str(len(run.files)),
                str(run.duplicates),
                "yes" if run.seeded else "no",
            ]
        )
    table(["run", "rows", "episodes", "files", "repeated seeds", "joined on seed"], rows, out)
    if any(len(run.files) > 1 for run in runs):
        out.write(
            "\na run of more than one file is a divided run: its parts stepped at the same\n"
            "time, so its `seconds` column is what a part waited on this machine and not\n"
            "what the experiment costs alone. Step counts are unaffected.\n"
        )


def compare(base, other, out, limit):
    if not base.seeded or not other.seeded:
        out.write("\n(one file has no episode seeds: episodes are compared as a distributions only)\n")
        return {}
    shared = sorted(set(base.by_seed) & set(other.by_seed))
    only_base = sorted(set(base.by_seed) - set(other.by_seed))
    only_other = sorted(set(other.by_seed) - set(base.by_seed))
    out.write(
        f"\n{base.name} vs {other.name}: {len(shared)} shared episodes"
        f", {len(only_base)} only in {base.name}, {len(only_other)} only in {other.name}\n"
    )

    agreed = [seed for seed in shared if judgement(base.by_seed[seed]) == judgement(other.by_seed[seed])]
    conflicts = [seed for seed in shared if judgement(base.by_seed[seed]) != judgement(other.by_seed[seed])]
    found = [seed for seed in shared if target_found(base.by_seed[seed]) == target_found(other.by_seed[seed])]
    out.write(f"outcome agrees on {len(agreed)}/{len(shared)}")
    out.write(f", target found (TFNP) agrees on {len(found)}/{len(shared)}")

    deltas = {}
    for column in ("num_steps", "monty_steps", "time", "rotation_error"):
        pairs = [
            (number(base.by_seed[seed], column), number(other.by_seed[seed], column)) for seed in shared
        ]
        pairs = [(left, right) for left, right in pairs if left is not None and right is not None]
        if not pairs:
            continue
        differences = [left - right for left, right in pairs]
        deltas[column] = {
            "mean": statistics.mean(differences),
            "median": statistics.median(differences),
            "shorter": sum(1 for difference in differences if difference < 0),
            "longer": sum(1 for difference in differences if difference > 0),
            "equal": sum(1 for difference in differences if difference == 0),
        }
        summary = deltas[column]
        out.write(
            f"\n{column}: {base.name} - {other.name} mean {format_number(summary['mean'])}"
            f", median {format_number(summary['median'])}"
            f" · lower in {base.name} {summary['shorter']}"
            f", higher {summary['longer']}, equal {summary['equal']}"
        )

    if conflicts:
        out.write(f"\n\nepisodes whose outcome differs (first {limit} of {len(conflicts)})\n")
        rows = []
        for seed in conflicts[:limit]:
            left, right = base.by_seed[seed], other.by_seed[seed]
            rows.append(
                [
                    str(seed),
                    (left.get("primary_target_object") or "-")[:16],
                    judgement(left),
                    judgement(right),
                    f"{format_number(number(left, 'num_steps'))}/{format_number(number(right, 'num_steps'))}",
                    f"{format_number(number(left, 'monty_steps'))}/{format_number(number(right, 'monty_steps'))}",
                    target_found(left),
                    target_found(right),
                ]
            )
        table(
            ["seed", "target", base.name, other.name, "steps", "monty steps", "TFNP " + base.name, "TFNP " + other.name],
            rows,
            out,
        )
    return deltas


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", help="eval_stats.csv files; the first is the base of the comparison")
    parser.add_argument("--labels", help="comma-separated column names, in the order of the paths")
    parser.add_argument("--json", dest="json_path", help="also write the whole report as JSON here")
    parser.add_argument("--disagreements", type=int, default=20, help="how many differing episodes to list (default 20)")
    args = parser.parse_args(argv)

    labels = args.labels.split(",") if args.labels else []
    runs = [Run.read(path, labels[index] if index < len(labels) else None) for index, path in enumerate(args.paths)]
    out = sys.stdout

    coverage(runs, out)

    names = [run.name for run in runs]
    for run in runs:
        out.write(f"\n{run.name}: {run.path}\n")
        out.write(f"  episodes  {len(run.rows)}\n")
    out.write("\n")

    metrics = {run.name: run.metrics() for run in runs}
    rows = []
    for column in [*MPER_FIELDS.values(), "pose error (m)", "rotation error (deg)"]:
        row = [column]
        for name in names:
            stats = metrics[name].get(column)
            row.append(
                "-"
                if stats is None
                else f"{format_number(stats['mean'])} / {format_number(stats['median'])} / "
                f"{format_number(stats['p90'])} / {format_number(stats['max'])}"
            )
        rows.append(row)
    out.write("per-episode metrics (mean / median / p90 / max)\n")
    table(["metric", *names], rows, out)

    distributions = {run.name: run.distributions() for run in runs}
    distribution_table("outcome", {name: d["outcome"] for name, d in distributions.items()}, out)
    distribution_table("exit", {name: d["exit"] for name, d in distributions.items()}, out)
    distribution_table("target found (TFNP)", {name: d["target"] for name, d in distributions.items()}, out)

    deltas = {}
    base = runs[0]
    for other in runs[1:]:
        deltas[other.name] = compare(base, other, out, args.disagreements)

    if args.json_path:
        report = {
            "runs": [
                {
                    "name": run.name,
                    "path": str(run.path),
                    "episodes": len(run.rows),
                    "repeated_seeds": run.duplicates,
                    "metrics": metrics[run.name],
                    "distributions": {key: dict(value) for key, value in distributions[run.name].items()},
                }
                for run in runs
            ],
            "deltas": deltas,
        }
        Path(args.json_path).write_text(json.dumps(report, indent=2, default=str))
        out.write(f"\nwrote {args.json_path}\n")


if __name__ == "__main__":
    main()
