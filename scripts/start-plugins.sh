#!/usr/bin/env bash
#
# Starts the two sample plugin nodes beside a studio that is already running, so
# the plugin story can be watched instead of read.
#
#   scripts/start-plugins.sh                              # find the studio on this machine
#   scripts/start-plugins.sh monty-studio-1a2b3c@10.0.0.7  # one it cannot find by itself
#   scripts/start-plugins.sh --stop
#
# What it starts is `examples/example_plugin` (one experiment, one learning
# module, one motor policy) and `examples/flyverse_plugin` (the same contract,
# different answers). Both are built as releases — an escript cannot carry the
# native kernels `ex_tbp_monty_core` compiles — and both join through
# `MONTY_SEEDS`, which is the one line the examples' own `Join` modules read.
#
# The cookie is the user's `~/.erlang.cookie` on both sides: that is what a
# release does when nobody sets `RELEASE_COOKIE`, and it is the right answer for
# several nodes on one machine. Two machines need `MONTY_CLUSTER_SECRET` on all
# three, which is `docs/cluster.md`'s business, not this script's.
set -euo pipefail
cd "$(dirname "$0")/.."

seeds="${MONTY_SEEDS:-}"
pids="$(dirname "$0")/../tmp/plugins.pids"
logs="${TMPDIR:-/tmp}"

stop() {
  if [ -f "$pids" ]; then
    while read -r pid; do
      # A release is a shell script that execs the VM, so the pid this started is
      # the VM's; `kill` on a dead one is not a failure worth reporting.
      kill "$pid" 2>/dev/null || true
    done <"$pids"
    rm -f "$pids"
    echo "stopped the plugin nodes"
  fi
}

case "${1:-}" in
  --stop)
    stop
    exit 0
    ;;
esac

# The studio's node name, asked of the studio. `/health` names the node that
# answered (`ExTbpMontyWeb.HealthController`), which is exactly the string a
# plugin dials — and the port is the desktop's, then this workspace's.
if [ -z "$seeds" ] && [ -n "${1:-}" ]; then
  seeds="$1"
fi

if [ -z "$seeds" ]; then
  for port in "${MONTY_DESKTOP_PORT:-42800}" 4001 4000; do
    answered="$(curl -fsS --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null || true)"
    seeds="$(printf '%s' "$answered" | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')"
    [ -n "$seeds" ] && break
  done
fi

if [ -z "$seeds" ]; then
  echo "no running studio answered with a node name." >&2
  echo "  Start one (scripts/start-desktop.sh), or name it:" >&2
  echo "  scripts/start-plugins.sh monty-studio-1a2b3c@10.0.0.7" >&2
  echo "  A node with no name cannot be joined — MONTY_STUDIO_CLUSTER=0 starts one." >&2
  exit 1
fi

echo "the plugins will join $seeds"

# Said before the first build, because the first build of one of these is minutes
# (the framework's native kernels compile) and a script that looks stuck is a
# script somebody ctrl-Cs at the wrong moment.
for example in example_plugin flyverse_plugin; do
  echo "building examples/$example (the first build compiles the framework's kernels)"
  (cd "examples/$example" && MIX_ENV=prod mix release --overwrite >/dev/null)
done

: >"$pids"

for example in example_plugin flyverse_plugin; do
  release="examples/$example/_build/prod/rel/$example"
  log="$logs/$example.log"

  # `sname`, not `name`: this is a demo beside a desktop on one machine, and a
  # short name is the one that does not listen to the network. The release names
  # itself after the release, which is unique between the two of them.
  ( cd "$release" && MONTY_SEEDS="$seeds" ./bin/"$example" start >"$log" 2>&1 ) &
  echo "$!" >>"$pids"

  echo "  $example: log in $log"
done

echo
echo "both are starting. The studio's Settings → Cluster lists them once they are"
echo "in; scripts/start-plugins.sh --stop ends them."
