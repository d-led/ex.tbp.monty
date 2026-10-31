#!/usr/bin/env bash
#
# Start the application from this checkout, with the code reloader, on
# http://localhost:4000.
#
#   scripts/run-dev.sh
#   PORT=4001 scripts/run-dev.sh
#
# scripts/init-dev.sh has to have run once: this starts the application, not the
# database or the assets.
#
# A world of Monty's own is optional and off by default. Without it a run steps
# the synthetic scene this port carries; with it a run steps Monty's simulator
# in a Python of your own (config/runtime.exs):
#
#   MONTY_WORLD=monty MONTY_PYTHON=../monty-orig/.venv/bin/python scripts/run-dev.sh

set -euo pipefail

cd "$(dirname "$0")/.."

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v mix >/dev/null 2>&1 ||
  die "mix is not on PATH: install Elixir 1.20 (https://elixir-lang.org/install.html) and run this again"

exec mix phx.server
