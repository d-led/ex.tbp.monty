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
# With no arguments it touches only the models this repository already ships a
# library for — "keep them current" — and leaves everything else alone.
#
# The same model name exists in several Monty releases (`surf_agent_1lm_*` is in
# v9, v10 and v11), and which release a library came from is provenance, not a
# detail: the README records it per file. So a name found in more than one
# release is never guessed at — writing it needs `--release`.
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
ambiguous=0
found=0

# One line per model: name, the releases it appears in, and one pickle per
# release — `surf_agent_1lm_10distinctobj  pretrained_ycb_v9 pretrained_ycb_v10 …`.
while IFS=$'\t' read -r model releases pickles; do
  found=$((found + 1))

  if [ -n "$only" ] && [ "$model" != "$only" ]; then continue; fi

  library="$libraries_dir/$model.jsonl.gz"
  if [ "$all" -eq 0 ] && [ -z "$only" ] && [ ! -f "$library" ]; then continue; fi

  # The pickle of the release asked for, when one was asked for.
  chosen=""
  if [ -n "$release" ]; then
    for pickle in $pickles; do
      case "$pickle" in *"/$release/"*) chosen="$pickle" ;; esac
    done
    if [ -z "$chosen" ]; then
      echo "  not in $release: $model (it is in $releases)"
      continue
    fi
  fi

  # Up to date: the library is newer than every candidate pickle, so nothing
  # would be written and which release it came from does not matter here.
  if [ "$force" -eq 0 ] && [ -f "$library" ]; then
    stale=0
    for pickle in $pickles; do
      if [ "$pickle" -nt "$library" ]; then stale=1; fi
    done
    if [ "$stale" -eq 0 ]; then
      echo "  up to date: $model"
      current=$((current + 1))
      continue
    fi
  fi

  # Writing it means choosing a release, and a name in several releases is not a
  # choice this script makes on someone's behalf.
  if [ -z "$chosen" ]; then
    if [ "$(printf '%s' "$releases" | wc -w | tr -d ' ')" -gt 1 ]; then
      echo "  ambiguous: $model is in $(printf '%s' "$releases" | tr ' ' ', ') — pass --release" >&2
      ambiguous=$((ambiguous + 1))
      continue
    fi
    chosen="$pickles"
  fi

  echo "  exporting: $model (from "$(basename "$(dirname "$(dirname "$(dirname "$chosen")")")")")"
  "$PYTHON" "$root/scripts/export_monty_pretrained.py" --model "$chosen" --out "$library"
  exported=$((exported + 1))
done < <(
  find "$models_dir" -mindepth 4 -maxdepth 4 -path '*/pretrained/model.pt' -print 2>/dev/null |
    while IFS= read -r pickle; do
      # …/<release>/<model>/pretrained/model.pt
      model="$(basename "$(dirname "$(dirname "$pickle")")")"
      release_name="$(basename "$(dirname "$(dirname "$(dirname "$pickle")")")")"
      printf '%s\t%s\t%s\n' "$model" "$release_name" "$pickle"
    done |
    sort -t$'\t' -k1,1 -k2,2 |
    awk -F'\t' '
      $1 != name {
        if (name != "") print name "\t" releases "\t" pickles
        name = $1; releases = ""; pickles = ""
      }
      { releases = releases (releases == "" ? "" : " ") $2
        pickles = pickles (pickles == "" ? "" : " ") $3 }
      END { if (name != "") print name "\t" releases "\t" pickles }
    '
)

if [ "$found" -eq 0 ]; then
  echo "sync_monty_libraries: no models under $models_dir" >&2
  exit 1
fi

if [ "$ambiguous" -gt 0 ]; then
  echo "sync_monty_libraries: ${ambiguous} ambiguous model(s) left alone" >&2
fi

echo "sync_monty_libraries: ${exported} exported, ${current} already current, in $libraries_dir"
