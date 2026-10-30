#!/usr/bin/env bash
# Export Monty's pretrained models into the libraries this port loads.
#
# The memory is not something this project computes: it is Monty's own
# pretrained model, and it arrives with Monty's prerequisites — the
# `pretrained_ycb_v*` archive unpacked under `$MONTY_MODELS` (see
# `priv/prerequisites.yaml` and `priv/monty/libraries/README.md`). This script
# does the one step that cannot happen at run time: reading those torch pickles
# and writing them out as JSONL, which needs `torch` and therefore Monty's
# Python environment, not the Elixir one.
#
#   scripts/sync_monty_libraries.sh                 # refresh the shipped libraries
#   scripts/sync_monty_libraries.sh --all           # also export every model found
#   scripts/sync_monty_libraries.sh --only <model>  # one model, named
#   scripts/sync_monty_libraries.sh --release pretrained_ycb_v10 --force
#
# With no arguments it refreshes the libraries this repository already ships —
# "keep them current" — and leaves everything else alone.
#
# A library lives under the release it came from,
# `priv/monty/libraries/<release>/<model>.jsonl.gz`, because the same model name
# exists in several Monty releases (`surf_agent_1lm_*` is in v9, v10, v11, v13)
# and they are different memories: a config that names
# `${constants.pretrained_dir}/surf_agent_1lm_10similarobj/pretrained/` means
# whichever release its `pretrained_dir` resolves to, and a run must not quietly
# recognise with another one's graphs.
#
# Nothing is downloaded here. If the models are not unpacked yet, this says so.
#
# Environment:
#   MONTY_MODELS  where Monty's pretrained models live
#                 (default: ~/tbp/results/monty/pretrained_models)
#   PYTHON        the interpreter with `torch` (default: the conda env
#                 `tbp.monty`, Monty's own pinned environment)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models_dir="${MONTY_MODELS:-$HOME/tbp/results/monty/pretrained_models}"
libraries_dir="$root/priv/monty/libraries"

force=0
all=0
only=""
release=""

while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    --all) all=1; shift ;;
    --only) only="${2:?--only needs a model name}"; shift 2 ;;
    --release) release="${2:?--release needs a release name}"; shift 2 ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sync_monty_libraries: unknown argument $1" >&2; exit 2 ;;
  esac
done

# The export needs `torch`, which lives in Monty's own environment. Prefer an
# explicit PYTHON, then the pinned conda env, and say what to do if neither.
if [ -z "${PYTHON:-}" ]; then
  if command -v conda >/dev/null 2>&1 && conda env list | awk '{print $1}' | grep -qx tbp.monty; then
    PYTHON="$(conda info --base)/envs/tbp.monty/bin/python"
  else
    echo "sync_monty_libraries: no interpreter with torch." >&2
    echo "  point PYTHON at Monty's environment, or create it (see docs/validation.md)." >&2
    exit 1
  fi
fi

if [ ! -d "$models_dir" ]; then
  echo "sync_monty_libraries: no pretrained models at $models_dir" >&2
  echo "  download and unpack Monty's archive first (priv/prerequisites.yaml," >&2
  echo "  or docs/how-to-use-monty/getting-started.md in tbp.monty)." >&2
  exit 1
fi

mkdir -p "$libraries_dir"

exported=0
current=0
found=0

# One line per (model, release): a model name in two releases is two memories,
# and both are exported rather than one being picked.
while IFS=$'\t' read -r model release_name pickle; do
  found=$((found + 1))

  if [ -n "$only" ] && [ "$model" != "$only" ]; then continue; fi
  if [ -n "$release" ] && [ "$release_name" != "$release" ]; then continue; fi

  library="$libraries_dir/$release_name/$model.jsonl.gz"
  if [ "$all" -eq 0 ] && [ -z "$only" ] && [ ! -f "$library" ]; then continue; fi

  if [ "$force" -eq 0 ] && [ -f "$library" ] && [ ! "$pickle" -nt "$library" ]; then
    echo "  up to date: $release_name/$model"
    current=$((current + 1))
    continue
  fi

  echo "  exporting: $model (from $release_name)"
  mkdir -p "$(dirname "$library")"
  "$PYTHON" "$root/scripts/export_monty_pretrained.py" --model "$pickle" --out "$library"
  exported=$((exported + 1))
done < <(
  find "$models_dir" -mindepth 4 -maxdepth 4 -path '*/pretrained/model.pt' -print 2>/dev/null |
    while IFS= read -r pickle; do
      # …/<release>/<model>/pretrained/model.pt
      model="$(basename "$(dirname "$(dirname "$pickle")")")"
      release_name="$(basename "$(dirname "$(dirname "$(dirname "$pickle")")")")"
      printf '%s\t%s\t%s\n' "$model" "$release_name" "$pickle"
    done |
    sort -t$'\t' -k1,1 -k2,2
)

if [ "$found" -eq 0 ]; then
  echo "sync_monty_libraries: no models under $models_dir" >&2
  exit 1
fi

echo "sync_monty_libraries: ${exported} exported, ${current} already current, in $libraries_dir"
