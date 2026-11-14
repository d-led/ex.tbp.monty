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
# a run is stepping and the edit should wait.
#
# A run writes its log as each step lands, so the newest `run.log`'s mtime is the
# signal. The window is five minutes by default and not one: a step of a big
# world can take minutes, and a run between two steps writes nothing at all — a
# wrong "quiet" is the answer that costs a run, so the guard errs towards busy.

set -euo pipefail

window=${1:-300}
cd "$(dirname "$0")/.."

# The newest log, without a pipe: `ls -t … | head -1` fails under `pipefail` as
# soon as `head` closes the pipe (SIGPIPE, exit 141), which would read as "a run
# is writing" on a quiet tree — the one mistake this script must not make.
newest=""

for candidate in priv/studio_runs/*/run.log; do
  [[ -e $candidate ]] || continue
  if [[ -z $newest || $candidate -nt $newest ]]; then
    newest=$candidate
  fi
done

if [[ -z $newest ]]; then
  echo "quiet: no run has ever written a log here"
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

echo "quiet: $newest last wrote ${age}s ago (window: ${window}s)"
exit 0
