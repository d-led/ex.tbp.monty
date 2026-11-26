#!/usr/bin/env bash
# Time this tree against another commit, and make each arm prove it is itself.
#
#   scripts/compare_builds.sh <ref> [pairs] [-- <mix monty.run args>]
#
# The trap this exists for: a comparison worktree's `mix run` happily reuses a
# `_build` left from another checkout, so the "old" arm reports the new tree's
# numbers and a whole campaign reads as having bought nothing. A worktree's
# `_build` is therefore recompiled before it is timed, and the sha it compiled is
# printed beside the reading.
#
# Both arms run the same experiment, same seed, interleaved — pair 1 old, pair 1
# new, pair 2 old, pair 2 new — because a single reading on this box resolves
# nothing (docs/speed.md, "How to measure, and what lies").
#
# `deps/` is symlinked from this tree when the worktree has none: Hex is not
# reachable from this box, and the dependency versions are pinned in mix.lock.

set -euo pipefail

ref=${1:?usage: compare_builds.sh <ref> [pairs] [-- mix monty.run args]}
pairs=${2:-2}
shift 2 || true
[ "${1:-}" = "--" ] && shift

here=$(cd "$(dirname "$0")/.." && pwd)
run_args=("$@")
[ ${#run_args[@]} -eq 0 ] && run_args=(base_infer_cows_small_compositional --episodes 1 --steps 12 --no-record --quiet --world ex_mujoco)

"$here/scripts/run_in_flight.sh" >/dev/null || {
  echo "a run is stepping — comparing now would measure it, not the code" >&2
  exit 1
}

worktree=$(mktemp -d "${TMPDIR:-/tmp}/monty-compare.XXXXXX")
trap 'git -C "$here" worktree remove --force "$worktree" 2>/dev/null || true' EXIT

git -C "$here" worktree add --detach "$worktree" "$ref" >/dev/null
[ -e "$worktree/deps" ] || ln -s "$here/deps" "$worktree/deps"

# The old arm must be the old code. `mix deps.compile --force` rebuilds the path
# package under comparison; `mix compile --force` rebuilds the app around it.
(
  cd "$worktree"
  env MIX_ENV=test mix deps.compile ex_tbp_monty_core --force >/dev/null
  env MIX_ENV=test mix compile --force >/dev/null
)

reading() {
  local tree=$1 label=$2
  local line
  line=$(cd "$tree" && env MIX_ENV=test mix monty.run "${run_args[@]}" 2>&1 | grep -E "^[0-9]+ steps:") || true
  printf '%s\t%s\n' "$label" "${line:-no reading}"
}

printf 'old\t%s\n' "$(git -C "$worktree" rev-parse --short HEAD)"
printf 'new\t%s\n' "$(git -C "$here" rev-parse --short HEAD)"

for pair in $(seq 1 "$pairs"); do
  printf 'pair %s\n' "$pair"
  reading "$worktree" "old"
  reading "$here" "new"
done
