#!/usr/bin/env python3
"""What kind of thing is each class Monty defines.

A port that counts classes counts the wrong thing. Monty has dataclasses that
carry behaviour, `Protocol`s that are only an interface, `ABC`s whose methods all
raise `NotImplementedError`, `TypedDict`s that are a dict's shape, and `Enum`s
that are a list of names. Only the first is work; the second and third are types,
and pretending they are modules waiting to be written inflates the backlog and
the module map's "planned" count.

This reads Monty's own source with `ast` and says what each class is:

    kind        protocol | abc | dataclass | named_tuple | typed_dict | enum |
                exception | class
    behaviour   none  — nothing to port (an interface, or every method raises)
                some  — at least one method with a real body

Output is JSON, one object per class, keyed by `<file>::<Class>`. `--planned
FILE` narrows it to a JSON list of `{"file": ..., "class": ...}`, which is what
`mix monty.port_census` writes from the module map, so the same script can be
asked "what kind is each class the map still calls planned".

    scripts/classify_monty_classes.py --monty-root ../monty-orig \\
        --planned /tmp/planned.json --summary
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path

# A method body that says nothing: a docstring, `pass`, `...`, or a raise of
# NotImplementedError. Such a method is an interface, not behaviour.
SILENT_METHODS = ("NotImplementedError",)


def base_names(node: ast.ClassDef) -> list[str]:
    """The names of the class's bases, as written (`Protocol`, `ABC`, `Generic`)."""
    names = []
    for base in node.bases:
        target = base.value if isinstance(base, ast.Subscript) else base
        if isinstance(target, ast.Name):
            names.append(target.id)
        elif isinstance(target, ast.Attribute):
            names.append(target.attr)
    return names


def decorator_names(node: ast.ClassDef) -> list[str]:
    names = []
    for decorator in node.decorator_list:
        target = decorator.func if isinstance(decorator, ast.Call) else decorator
        if isinstance(target, ast.Name):
            names.append(target.id)
        elif isinstance(target, ast.Attribute):
            names.append(target.attr)
    return names


def is_silent_body(body: list[ast.stmt]) -> bool:
    """True when the body is only a docstring, `pass`, `...`, or NotImplementedError."""
    for statement in body:
        if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Constant):
            if isinstance(statement.value.value, str):
                continue  # a docstring
            if statement.value.value is Ellipsis:
                continue  # `...`
        if isinstance(statement, ast.Pass):
            continue
        if isinstance(statement, ast.Raise):
            raised = statement.exc
            if isinstance(raised, ast.Call):
                raised = raised.func
            if isinstance(raised, ast.Name) and raised.id in SILENT_METHODS:
                continue
        return False
    return True


def methods_with_bodies(node: ast.ClassDef) -> list[str]:
    return [
        child.name
        for child in node.body
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
        and not is_silent_body(child.body)
    ]


def has_abstract_method(node: ast.ClassDef) -> bool:
    """True when some method is declared abstract: that is an interface too."""
    for child in node.body:
        if not isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for decorator in child.decorator_list:
            target = decorator.func if isinstance(decorator, ast.Call) else decorator
            if isinstance(target, ast.Name) and target.id in ("abstractmethod", "abstractproperty"):
                return True
            if isinstance(target, ast.Attribute) and target.attr in (
                "abstractmethod",
                "abstractproperty",
            ):
                return True
    return False


def kind_of(node: ast.ClassDef) -> str:
    bases = base_names(node)
    decorators = decorator_names(node)

    if "Protocol" in bases or "Protocol" in decorators:
        return "protocol"
    if "TypedDict" in bases:
        return "typed_dict"
    if "NamedTuple" in bases:
        return "named_tuple"
    if "Enum" in bases or "IntEnum" in bases or "StrEnum" in bases:
        return "enum"
    if "dataclass" in decorators:
        return "dataclass"
    if "ABC" in bases or has_abstract_method(node):
        return "abc"
    if any(base.endswith(("Error", "Exception")) for base in bases):
        return "exception"
    return "class"


def describe(path: Path, node: ast.ClassDef, root: Path) -> dict:
    bodies = methods_with_bodies(node)
    fields = [
        child.target.id
        for child in node.body
        if isinstance(child, ast.AnnAssign) and isinstance(child.target, ast.Name)
    ]

    return {
        "file": str(path.relative_to(root)),
        "class": node.name,
        "line": node.lineno,
        "bases": base_names(node),
        "kind": kind_of(node),
        "behaviour": "some" if bodies else "none",
        "methods": bodies,
        "fields": fields,
    }


def classes_in(path: Path) -> list[ast.ClassDef]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    return [node for node in ast.walk(tree) if isinstance(node, ast.ClassDef)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--monty-root", default="../monty-orig")
    parser.add_argument(
        "--planned",
        default=None,
        help="JSON list of {file, class} to narrow the report to, as the map writes it",
    )
    parser.add_argument("--summary", action="store_true", help="print counts instead of every class")
    parser.add_argument("--out", default=None, help="write the JSON here instead of stdout")
    arguments = parser.parse_args()

    root = Path(arguments.monty_root).expanduser().resolve()
    source = root / "src"
    if not source.is_dir():
        print(f"no Monty source at {source}", file=sys.stderr)
        return 1

    # Every package Monty ships (`tbp/monty`, `tbp/teleop`), because the map
    # names classes from both.
    described = {}
    for path in sorted(source.rglob("*.py")):
        if "__pycache__" in path.parts:
            continue
        try:
            nodes = classes_in(path)
        except SyntaxError as error:  # a file this interpreter cannot read
            print(f"skipped {path}: {error}", file=sys.stderr)
            continue
        for node in nodes:
            entry = describe(path, node, source)
            described[f"{entry['file']}::{node.name}"] = entry

    planned = None
    unclassified = {}
    if arguments.planned:
        wanted = json.loads(Path(arguments.planned).read_text(encoding="utf-8"))
        planned = {f"tbp/{item['package']}/{item['file']}::{item['class']}": item for item in wanted}
        described = {key: value for key, value in described.items() if key in planned}
        missing = sorted(set(planned) - set(described))
        # A class from a package this checkout does not have is not a class this
        # script failed to find: it is one nothing here can classify yet.
        for key in missing:
            package = key.split("/")[1]
            present = (source / "tbp" / package).is_dir()
            unclassified.setdefault(package if not present else f"{package} (present, class missing)", []).append(key)
        for package, keys in sorted(unclassified.items()):
            print(f"{len(keys)} planned classes in {package}: not classified", file=sys.stderr)
            for key in keys[:5]:
                print(f"  {key}", file=sys.stderr)

    if arguments.summary:
        counts = {}
        for entry in described.values():
            key = (entry["kind"], entry["behaviour"])
            counts[key] = counts.get(key, 0) + 1
        for (kind, behaviour), count in sorted(counts.items(), key=lambda item: -item[1]):
            print(f"{count:5d}  {kind:12s} behaviour={behaviour}")

        silent = sum(1 for entry in described.values() if entry["behaviour"] == "none")
        print(f"\n{silent} with nothing to port, of {len(described)} classified")
        if unclassified:
            total = sum(len(keys) for keys in unclassified.values())
            print(f"{total} not classified: " + ", ".join(sorted(unclassified)))
        return 0

    payload = json.dumps(described, indent=2, sort_keys=True)
    if arguments.out:
        Path(arguments.out).write_text(payload + "\n", encoding="utf-8")
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
