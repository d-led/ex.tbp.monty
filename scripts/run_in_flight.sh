#!/usr/bin/env bash
# Is a studio run writing right now?
#
# The dev server recompiles a changed module on the next request and purges the
# old version, and a worker stepping through that module dies on the purge
# (`AGENTS.md`: "a run in flight forbids editing lib/"). This is the check that
# rule asks for, in one command:
#
#   scripts/run_in_flight.sh        # exits 0 when nothing has written for 5 min
#   scripts/run_in_flight.sh 60     # ... or for another window, in seconds
#
# Exit status is the answer: 0 means the tree is quiet and safe to edit, 1 means
# a run is stepping and the edit should wait, 2 means the folders a run writes to
# were not found at all — which is not evidence of a quiet tree.
#
# A run writes its log as each step lands, so the newest `run.log`'s mtime is the
# signal. The window is five minutes by default and not one: a step of a big
# world can take minutes, and a run between two steps writes nothing at all — a
# wrong "quiet" is the answer that costs a run, so the guard errs towards busy.
#
# It looks in **every** folder a run's files can be in, because the first version
# of this script looked only in `priv/studio_runs` and answered "no run has ever
# written a log here" while a run was stepping in a node's own folder — and that
# answer was taken as permission to edit `lib/`, which killed the run. Where the
# files are is `Monty.Paths.artifacts/0`:
#
#   `MONTY_ARTIFACTS_DIR` if it is set — the one lever a cluster has;
#   else `<node root>/runs`, where the node root is the application's data
#   folder (`~/Library/Application Support/ex-tbp-monty` on a Mac,
#   `$XDG_DATA_HOME/ex-tbp-monty` on Linux) with one `nodes/<name>/` per named
#   node;
#   plus `priv/studio_runs`, which a test build and older dev configs name.

set -euo pipefail

window=${1:-300}
cd "$(dirname "$0")/.."

data_home=${XDG_DATA_HOME:-"$HOME/Library/Application Support"}
data_home=${data_home%/}
app_root="$data_home/ex-tbp-monty"

roots=()
if [[ -n ${MONTY_ARTIFACTS_DIR:-} ]]; then
  roots+=("$MONTY_ARTIFACTS_DIR")
fi
roots+=("priv/studio_runs" "$app_root/runs")
# One per named node: `nodes/<name>/runs`. The glob is guarded by `-d`, so a
# machine with no named node contributes nothing.
for node in "$app_root"/nodes/*; do
  [[ -d $node ]] && roots+=("$node/runs")
done

# The newest log, without a pipe: `ls -t … | head -1` fails under `pipefail` as
# soon as `head` closes the pipe (SIGPIPE, exit 141), which would read as "a run
# is writing" on a quiet tree — the one mistake this script must not make.
newest=""
looked=""
for root in "${roots[@]}"; do
  if [[ -d $root ]]; then
    looked="$looked $root"
  else
    continue
  fi
  # `*/run.log` is a run's own log; `*/*/run.log` is a part's, which a divided
  # run writes in a folder of its own inside the run's.
  for candidate in "$root"/*/run.log "$root"/*/*/run.log; do
    [[ -e $candidate ]] || continue
    if [[ -z $newest || $candidate -nt $newest ]]; then
      newest=$candidate
    fi
  done
done

if [[ -z $looked ]]; then
  # Said plainly: nothing was read, so this is not evidence of a quiet tree.
  printf 'unknown: none of these run folders exists:'
  printf ' %s' "${roots[@]}"
  echo
  echo "a run may still be stepping somewhere this script cannot see — ask before editing lib/"
  exit 2
fi

if [[ -z $newest ]]; then
  echo "quiet: no run has written a log in$looked"
  exit 0
fi

# `stat` differs between macOS and Linux, and this has to work on both.
modified=$(stat -f %m "$newest" 2>/dev/null || stat -c %Y "$newest")
age=$(( $(date +%s) - modified ))

if (( age < window )); then
  echo "a run is writing: $newest (last step ${age}s ago)"
  echo "do not edit lib/ — see AGENTS.md"
  exit 1
fi

echo "quiet: $newest last wrote ${age}s ago (window: ${window}s; looked in$looked)"
exit 0
