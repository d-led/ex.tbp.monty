#!/usr/bin/env python3
"""How much of Monty's own unit suite has this port translated?

    scripts/test_map.py                       # against ../monty-orig
    scripts/test_map.py --source ../tbp.monty # against the live checkout
    scripts/test_map.py --missing             # every untranslated case, by name

Monty's rule for this repository is one case for one case: a `def test_...` in
`tests/unit/**` becomes one ExUnit test that names the case it translates, and a
case that cannot be translated is listed rather than dropped. The name is the
whole record of the translation, so it is greppable: this walks Monty's unit
suite, takes every `def test_*` name, and asks whether that name appears anywhere
in `test/**/*.exs`.

What it does NOT claim: a name that appears is a translation that is faithful. It
says the case was read and named; the test itself says whether it asserts the same
behaviour.
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
    """Everything the port's tests say, as one string to search."""
    text = []
    for root, subdirectories, files in os.walk(directory):
        subdirectories[:] = [d for d in subdirectories if d != "_build"]
        for name in files:
            if name.endswith(".exs"):
                with open(os.path.join(root, name), errors="ignore") as handle:
                    text.append(handle.read())
    return "\n".join(text)


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
    translated_by = port_tests(options.tests)

    total = 0
    named = 0
    rows = []

    for path, names in sorted(cases.items()):
        here = sum(1 for name in names if name in translated_by)
        total += len(names)
        named += here
        rows.append((path, here, len(names), [n for n in names if n not in translated_by]))

    print(f"monty: {options.source} · tests: {options.tests}")
    print(f"{named} of {total} unit cases named in this port's tests\n")

    for path, here, count, missing in rows:
        print(f"{here:>3}/{count:<3} {path}")
        if options.missing:
            for name in missing:
                print(f"        {name}")

    untranslated = total - named
    files = sum(1 for _, here, _, _ in rows if here == 0)
    print(f"\n{untranslated} cases not named · {files} of {len(rows)} files with none named")

    if not options.missing:
        print("`--missing` names them.")


if __name__ == "__main__":
    main()
