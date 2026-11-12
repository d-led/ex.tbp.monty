#!/usr/bin/env python3
"""What a run's own log says about where its time went.

The twin of `scripts/probe_run_log.exs`, for a machine that has no Elixir — the
desktop build's data directory, a container, a colleague's laptop. Reads only the
run's `run.log`, so it works on a log copied from anywhere.

    python3 scripts/probe_run_log.py priv/studio_runs/<id>
    python3 scripts/probe_run_log.py ~/Library/Application\\ Support/<app>/studio_runs/<id>

Prints the wall between the first step line and the last, the steps' own reported
time, and the gap a step leaves behind — which is everything the studio does
around the model, the world included.
"""

import os
import re
import statistics
import sys

# `07:22:41.637 07:22:41.629 step 7 · percepts patch · … · 89.3ms · …` — the
# first stamp is when the line was written, the number after the last dot is the
# step's own report of itself.
STEP = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d+) .*?step (\d+) .*?· (\d+(?:\.\d+)?)ms ·")


def at(hours: str, minutes: str, seconds: str, frac: str) -> int:
    base = (int(hours) * 3600 + int(minutes) * 60 + int(seconds)) * 1000
    return base + int(frac.ljust(3, "0")[:3])


def steps_of(path: str):
    with open(path, errors="replace") as log:
        for line in log:
            found = STEP.match(line)
            if found:
                yield at(*found.group(1, 2, 3, 4)), float(found.group(6))


def main(directory: str) -> int:
    path = os.path.join(directory, "run.log")
    steps = list(steps_of(path))
    if len(steps) < 2:
        print(f"{path}: no step lines to measure")
        return 1

    wall = steps[-1][0] - steps[0][0]
    own = sum(step[1] for step in steps)
    gaps = [later[0] - earlier[0] - later[1] for earlier, later in zip(steps, steps[1:])]
    gaps.sort()

    def percentile(share: int) -> int:
        return gaps[min(len(gaps) * share // 100, len(gaps) - 1)]

    print(f"run {os.path.basename(directory.rstrip('/'))}")
    print(f"  steps: {len(steps)}")
    print(f"  wall, first step line to last: {wall / 1000:.1f} s")
    print(f"  the steps' own time: {own / 1000:.1f} s, {100 * own / wall:.1f} %")
    print(f"  a step: {wall / len(steps):.1f} ms wall, {own / len(steps):.1f} ms own")
    print(
        "  the gap around a step: "
        f"median {statistics.median(gaps):.0f} ms, 90th {percentile(90)} ms, worst {gaps[-1]} ms"
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(64)
    sys.exit(main(sys.argv[1]))
