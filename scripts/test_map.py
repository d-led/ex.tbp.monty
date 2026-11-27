#!/usr/bin/env python3
"""How much of Monty's own unit suite has this port translated?

    scripts/test_map.py                       # against ../monty-orig
    scripts/test_map.py --source ../tbp.monty # against the live checkout
    scripts/test_map.py --missing             # every untranslated case, by name

Monty's rule for this repository is one case for one case: a `def test_...` in
`tests/unit/**` becomes one ExUnit test that names the case it translates, and a
case that cannot be translated is listed rather than dropped. The name is the
whole record of the translation, so it is greppable: this walks Monty's unit
suite, takes every `def test_*` name, and asks whether that name is *attributed*
in `test/**/*.exs` — on a `# test_...` comment, or in a test's title. A name that
appears only in prose is not counted: a list of the cases that could not be
translated must not read as translations.

What it does NOT claim: a name that is attributed is a translation that is
faithful. It says the case was read and named; the test itself says whether it
asserts the same behaviour. Nor can it separate two files' cases that share a
name — Monty's `test_dict` and `test_json_serialization` recur in a dozen files,
and one attribution answers for all of them — so a file's row is an upper bound
on its translations, and the ones a moduledoc list as untranslatable are still
counted if another file happens to have the same name.
"""

import argparse
import os
import re
import sys

CASE = re.compile(r"def (test_[A-Za-z0-9_]+)")


def monty_cases(source):
    """Every unit case, by the file it is defined in."""
    root = os.path.join(source, "tests", "unit")
    if not os.path.isdir(root):
        sys.exit(f"{root} is not there: point --source at a Monty checkout")

    cases = {}
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = [d for d in subdirectories if d != "__pycache__"]
        for name in sorted(files):
            # Monty names a test module `<thing>_test.py`; older releases used
            # `test_<thing>.py`, so both are read.
            if not (name.endswith("_test.py") or name.startswith("test_")):
                continue
            path = os.path.join(directory, name)
            with open(path, errors="ignore") as handle:
                names = CASE.findall(handle.read())
            if names:
                cases[os.path.relpath(path, root)] = names
    return cases


def port_tests(directory):
    """The lines of this port's tests that attribute a case, as one string.

    An attribution is a comment (`# test_foo` above the test that translates it)
    or a test whose title carries the name. Only those lines are read, because a
    name mentioned in prose is not a translation: a moduledoc that lists the
    cases which could *not* be translated would otherwise count them, and the
    count would flatter the port by exactly the cases it is honest about.
    """
    lines = []
    for root, subdirectories, files in os.walk(directory):
        subdirectories[:] = [d for d in subdirectories if d != "_build"]
        for name in sorted(files):
            if name.endswith(".exs"):
                with open(os.path.join(root, name), errors="ignore") as handle:
                    for line in handle:
                        stripped = line.strip()
                        if stripped.startswith("#") or 'test "' in line or "test '" in line:
                            lines.append(line)
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="../monty-orig")
    parser.add_argument("--tests", default="test")
    parser.add_argument(
        "--missing",
        action="store_true",
        help="name every untranslated case instead of summarising each file",
    )
    options = parser.parse_args()

    cases = monty_cases(options.source)
    attributed = port_tests(options.tests)

    def named(name):
        # A whole name, not a prefix: `test_encode` has a translation only where
        # a test says so, not because `test_encodes_dataclass_instances_...`
        # happens to contain it.
        return re.search(r"\b" + re.escape(name) + r"\b", attributed) is not None

    total = 0
    named_count = 0
    rows = []

    for path, names in sorted(cases.items()):
        here = sum(1 for name in names if named(name))
        total += len(names)
        named_count += here
        rows.append((path, here, len(names), [n for n in names if not named(n)]))

    print(f"monty: {options.source} · tests: {options.tests}")
    print(f"{named_count} of {total} unit cases named in this port's tests\n")

    for path, here, count, missing in rows:
        print(f"{here:>3}/{count:<3} {path}")
        if options.missing:
            for name in missing:
                print(f"        {name}")

    untranslated = total - named_count
    files = sum(1 for _, here, _, _ in rows if here == 0)
    print(f"\n{untranslated} cases not named · {files} of {len(rows)} files with none named")

    if not options.missing:
        print("`--missing` names them.")


if __name__ == "__main__":
    main()
