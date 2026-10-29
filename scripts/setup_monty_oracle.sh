#!/bin/sh
# A throwaway Python environment for running Monty's own code as an oracle.
#
# The parity tests in this repository replay answers recorded by running Monty
# itself (see `docs/validation.md`). Recording them needs Monty's dependencies,
# which the Elixir project does not have and should not care about. This script
# builds them in a virtualenv that is gitignored, so nothing about Monty's Python
# stack leaks into the application or into anyone's interpreter.
#
#     PYTHON=/path/to/python3 scripts/setup_monty_oracle.sh
#     WITH_TORCH=1 PYTHON=... scripts/setup_monty_oracle.sh
#
# `PYTHON` must be an interpreter with the pieces Monty shares with the recorders
# — numpy and OpenCV — because the recordings were made with them and a different
# build can move the last digits of a fixture. The venv is built with
# `--system-site-packages` so those are inherited, and only what is missing is
# installed.
#
# `WITH_TORCH=1` adds `torch` and `torch_geometric`, which Monty's object model
# needs (`frameworks/models/object_model.py`). That is a couple of gigabytes of
# download and needs a few gigabytes of free disk; without it, everything except
# Monty's learning modules can be recorded.
set -eu

PYTHON=${PYTHON:-python3}
VENV=${VENV:-.monty-oracle}
WITH_TORCH=${WITH_TORCH:-0}

if [ ! -x "$(command -v "$PYTHON" 2>/dev/null || true)" ] && [ ! -x "$PYTHON" ]; then
  echo "setup_monty_oracle: PYTHON=$PYTHON is not an executable interpreter" >&2
  exit 2
fi

echo "setup_monty_oracle: building $VENV from $PYTHON"
"$PYTHON" -m venv --system-site-packages "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip

# The recorders' missing pieces, one per script that needs it:
#   numpy-quaternion  Monty's SalienceSM imports `quaternion`
#   scipy             `GetGoodView` smooths with `scipy.ndimage`
#   omegaconf         `experiment/environment.py` imports Hydra's config types
#   scikit-learn      Monty's object model builds a k-nearest-neighbour graph
"$VENV/bin/pip" install --quiet numpy-quaternion scipy omegaconf scikit-learn

if [ "$WITH_TORCH" = "1" ]; then
  echo "setup_monty_oracle: installing torch and torch_geometric (this is the big one)"
  "$VENV/bin/pip" install --quiet torch torch_geometric
fi

"$VENV/bin/python" - "$WITH_TORCH" <<'PY'
import importlib
import sys

wanted = ["numpy", "cv2", "quaternion", "scipy", "omegaconf", "sklearn"]
if sys.argv[1] == "1":
    wanted += ["torch", "torch_geometric"]

missing = []
for name in wanted:
    try:
        module = importlib.import_module(name)
        print(f"  {name:16} {getattr(module, '__version__', 'unknown')}")
    except Exception as error:  # noqa: BLE001 - the report is the point
        missing.append(name)
        print(f"  {name:16} MISSING ({type(error).__name__})")

print()
if missing:
    print("setup_monty_oracle: missing " + ", ".join(missing))
    sys.exit(1)

print("setup_monty_oracle: ready. Run a recorder with, for example,")
print("  PYTHONPATH=../monty-orig/src $VIRTUAL_ENV/bin/python scripts/record_monty_vocus2.py")
PY
