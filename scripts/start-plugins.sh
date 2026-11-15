#!/usr/bin/env bash
#
# Starts the two sample plugin nodes beside a studio that is already running.
#
#   scripts/start-plugins.sh                       # find the studio on this machine
#   scripts/start-plugins.sh monty-studio-1a2b3c@10.0.0.7
#   scripts/start-plugins.sh --stop
#   scripts/start-plugins.sh --rebuild             # build them again first
#
# This is the launcher the bundle ships (`scripts/desktop-plugins/`), pointed at
# the folder the bundle carries them in — one implementation, so a checkout and
# an installed window cannot start them differently. What this adds is the build:
# `scripts/build-plugins.sh` puts both examples there as releases, which is a
# couple of minutes the first time (the framework's native kernels compile).
set -euo pipefail
cd "$(dirname "$0")/.."

plugins="_build/desktop/plugins"

case "${1:-}" in
  --stop) exec "$plugins/start-plugins.sh" --stop ;;
  --rebuild)
    scripts/build-plugins.sh >/dev/null
    shift
    ;;
esac

if [ ! -d "$plugins/example_plugin" ]; then
  echo "building the two sample plugin nodes (the first build compiles the framework's kernels)"
  scripts/build-plugins.sh >/dev/null
fi

exec "$plugins/start-plugins.sh" "$@"
