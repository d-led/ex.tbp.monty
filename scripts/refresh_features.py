#!/usr/bin/env python3
"""Refresh the measured numbers in docs/features.md.

Every count on that page is read out of this tree; none is remembered. Run this
after anything lands that can move one — a ported module, a Monty pull that
changes the snapshots, a new MCP tool, a test — and the page is true again.

    scripts/refresh_features.py            # rewrite the page, print what moved
    scripts/refresh_features.py --check    # write nothing, exit 1 if it is stale

| Count | Read from |
| --- | --- |
| module-map files, classes, statuses | `lib/monty/module_map/data.ex` |
| the Monty revision the map was made from | `@sources` in the same file |
| snapshots compared by the config gate | `<MONTY_SOURCE>/tests/conf/snapshots/*.yaml` |
| parity tests | `test/**/*parity_test.exs` |
| test cases | `test` declarations under `test/` |
| MCP tools | `"name" => "monty_…"` in `lib/ex_tbp_monty/mcp/tools.ex` |
| prerequisite downloads | `- id:` entries in `priv/prerequisites.yaml` |

`MONTY_SOURCE` names the checkout, default `../monty-orig`. A checkout whose
HEAD is not the commit the map names is reported: the snapshot count is then of
a different tree than the map beside it, and that is worth knowing before
believing either number.

Only the counts move. Prose is never rewritten, so a sentence that gains a new
shape is a loud failure here (`no match`) rather than a silent edit.
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEFAULT_PAGE = REPO / "docs" / "features.md"


class Counters:
    """The numbers, measured once and read by every pattern below."""

    def __init__(self) -> None:
        map_text = (REPO / "lib" / "monty" / "module_map" / "data.ex").read_text()
        self.map = self._module_map(map_text)
        self.revision = self._revision(map_text)
        self.snapshots = self._snapshots()
        self.parity_tests = len(list((REPO / "test").rglob("*parity_test.exs")))
        self.test_cases = self._test_cases()
        self.tools = self._tools()
        self.prerequisites = self._prerequisites()
        self.today = datetime.date.today().isoformat()

    @staticmethod
    def _module_map(text: str) -> dict[str, Counter]:
        files = Counter()
        packages = Counter()
        classes = Counter()
        for block in re.split(r"\n    %\{", text)[1:]:
            status = re.search(r"\n      status: :(\w+)", block)
            if not status:
                continue
            files[status.group(1)] += 1
            package = re.search(r'\n      package: "(\w+)"', block)
            if package:
                packages[package.group(1)] += 1
            classes.update(re.findall(r"\n          status: :(\w+)", block))
        return {"files": files, "packages": packages, "classes": classes}

    @staticmethod
    def _revision(text: str) -> str:
        commit = re.search(
            r'"monty" => %\{\s*\n\s*"commit" => "([0-9a-f]{7,40})"', text
        )
        if not commit:
            raise SystemExit("no monty commit in ModuleMap.Data @sources")
        return commit.group(1)[:8]

    def _snapshots(self) -> int:
        source = Path(os.environ.get("MONTY_SOURCE", REPO.parent / "monty-orig"))
        # SnapshotCheck collects `Path.join(dir, "*.yaml")`: one level, not a walk.
        snapshot_dir = source / "tests" / "conf" / "snapshots"
        if not snapshot_dir.is_dir():
            raise SystemExit(
                f"no snapshots at {snapshot_dir}\n"
                "point MONTY_SOURCE at a tbp.monty checkout (default ../monty-orig)"
            )
        self._warn_on_moved_checkout(source)
        return len(list(Path(snapshot_dir).glob("*.yaml")))

    def _warn_on_moved_checkout(self, source: Path) -> None:
        try:
            head = subprocess.run(
                ["git", "-C", str(source), "rev-parse", "HEAD"],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
        except OSError:
            head = ""
        if head and not head.startswith(self.revision):
            print(
                f"note: {source.name} is at {head[:8]}, the map names "
                f"{self.revision} — the snapshot count is of the newer tree",
                file=sys.stderr,
            )

    @staticmethod
    def _test_cases() -> int:
        count = 0
        for test_file in (REPO / "test").rglob("*_test.exs"):
            # Both shapes `ExUnit` sees: `test "…"` and `test ~s(…)`.
            count += len(re.findall(r'^[ \t]+test [~"]', test_file.read_text(), re.M))
        return count

    @staticmethod
    def _tools() -> int:
        text = (REPO / "lib" / "ex_tbp_monty" / "mcp" / "tools.ex").read_text()
        return len(re.findall(r'"name" => "monty_[a-z_]+"', text))

    @staticmethod
    def _prerequisites() -> int:
        text = (REPO / "priv" / "prerequisites.yaml").read_text()
        return len(re.findall(r"^  - id:", text, re.M))


def substitutions(c: Counters) -> list[tuple[str, str]]:
    """(pattern, replacement), in page order. Each must match exactly once."""
    files, classes, packages = c.map["files"], c.map["classes"], c.map["packages"]
    return [
        (
            r"checked in the tree on \d{4}-\d{2}-\d{2}",
            f"checked in the tree on {c.today}",
        ),
        (
            r"\*\*The map is the contract\.\*\* \d+ Python files "
            r"\(\d+ `tbp\.monty`, \d+ `tbp\.teleop`\),\s+"
            r"\d+ classes\. Implemented: \d+ files / \d+ classes\. "
            r"Planned: \d+ / \d+\. Excluded: \d+ / \d+\.",
            "**The map is the contract.** "
            f"{sum(files.values())} Python files "
            f"({packages['monty']} `tbp.monty`, {packages['teleop']} `tbp.teleop`),\n  "
            f"{sum(classes.values())} classes. "
            f"Implemented: {files['implemented']} files / {classes['implemented']} classes. "
            f"Planned: {files['planned']} / {classes['planned']}. "
            f"Excluded: {files['excluded']} / {classes['excluded']}.",
        ),
        (
            r"\(\d+ files at `monty@[0-9a-f]{7,40}`\)",
            f"({c.snapshots} files at `monty@{c.revision}`)",
        ),
        (
            r", \d+ `\*_parity_test\.exs` files\)",
            f", {c.parity_tests} `*_parity_test.exs` files)",
        ),
        (
            r"\*\*\d+ tools\*\*, all `monty_\*`",
            f"**{c.tools} tools**, all `monty_*`",
        ),
        (
            r"[\d,]+ `test` declarations in the suite\.",
            f"{c.test_cases:,} `test` declarations in the suite.",
        ),
        (
            r"— \d+ entries in\n  \[`priv/prerequisites\.yaml`\]",
            f"— {c.prerequisites} entries in\n  [`priv/prerequisites.yaml`]",
        ),
    ]


def label(page: Path) -> str:
    """How to name the page in output — repo-relative when it is in the repo."""
    try:
        return str(page.relative_to(REPO))
    except ValueError:
        return str(page)


def refresh(page: Path, check: bool) -> int:
    text = page.read_text()
    stale: list[str] = []
    counters = Counters()

    for pattern, replacement in substitutions(counters):
        found = re.findall(pattern, text)
        if len(found) != 1:
            raise SystemExit(
                f"{label(page)}: pattern matched {len(found)} times, "
                f"expected once — the page changed shape:\n  {pattern}"
            )
        updated = re.sub(pattern, replacement.replace("\\", "\\\\"), text, count=1)
        if updated != text:
            stale.append(replacement.splitlines()[0])
        text = updated

    if not stale:
        print(f"{label(page)}: numbers are current")
        return 0
    if check:
        print(f"{label(page)}: out of date", file=sys.stderr)
        for line in stale:
            print(f"  {line}", file=sys.stderr)
        return 1

    page.write_text(text)
    print(f"{label(page)}: refreshed {len(stale)} line(s)")
    for line in stale:
        print(f"  {line}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "page",
        nargs="?",
        type=Path,
        default=DEFAULT_PAGE,
        help="the page to refresh (default docs/features.md)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="write nothing; exit 1 when the page is out of date",
    )
    args = parser.parse_args()
    return refresh(args.page.resolve(), args.check)


if __name__ == "__main__":
    sys.exit(main())
