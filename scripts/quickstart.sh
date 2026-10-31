#!/usr/bin/env bash
#
# First time here? Run this, with no arguments.
#
#   scripts/quickstart.sh
#
# It decides everything else for you: the newest published image if there is
# one (otherwise it builds this checkout's), a Postgres of its own, a migrated
# database, the studio on a free port from 4001 upwards, and a browser on it.
#
#   scripts/quickstart.sh --stop     stop it (keeps the database and the app's files)
#   scripts/quickstart.sh --purge    …and delete them
#   scripts/quickstart.sh --port 5000 --data ~/tbp
#
# The aggregate is a sequence of the two smaller scripts, with the arguments a
# first-timer would have had to work out: `scripts/image.sh` builds the image
# when nothing is published, and `scripts/start-in-docker.sh` runs it. Use those
# directly when you want to choose; use this when you just want the studio.

set -euo pipefail

cd "$(dirname "$0")/.."

image="ghcr.io/d-led/ex.tbp.monty"
tag="latest"
port=""
data_dir=""
stopping=0
forward=()

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

die() {
  echo "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --port) port="${2:?--port needs a value}"; forward+=(--port "$2"); shift 2 ;;
    --data) data_dir="${2:?--data needs a directory}"; forward+=(--data "$2"); shift 2 ;;
    --stop | --purge) stopping=1; forward+=("$1"); shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# Stopping needs no image and no reasoning: hand it straight to the script that
# owns those containers.
if ((stopping)); then
  exec ./scripts/start-in-docker.sh ${forward[@]+"${forward[@]}"}
fi

command -v docker >/dev/null 2>&1 || die "$(cat <<'MESSAGE'
Docker is not on PATH, so there is nothing to pull or run.

Either install Docker Desktop (https://docs.docker.com/get-docker/) and run this
again, or run it from a checkout with Elixir on the machine:

    docker compose up -d      # Postgres 17 on :6432
    mix setup                 # deps, database, assets
    mix phx.server            # http://localhost:4000
MESSAGE
)"

# --- which image -------------------------------------------------------------
# The published one if it exists, because that is the one this project ships;
# this checkout's if it does not (a fresh fork, or before CI has published).
if docker manifest inspect "${image}:${tag}" >/dev/null 2>&1; then
  echo "using the published image ${image}:${tag}" >&2
else
  echo "no ${image}:${tag} is published; building this checkout's image instead" >&2
  ./scripts/image.sh build
  forward+=(--local)
fi

# --- which port --------------------------------------------------------------
# 4001 keeps the studio next to a `mix phx.server` on 4000, which is what the
# README's dev path uses. A port somebody else is on is not a question for a
# first-time user, so walk upwards from there.
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

start=${port:-4001}
for candidate in $(seq "$start" $((start + 20))); do
  if ! port_in_use "$candidate"; then
    port="$candidate"
    break
  fi
done

[[ -n "$port" ]] || die "ports ${start} to $((start + 20)) are all in use"
((port == start)) || echo "port ${start} is taken; using ${port}" >&2

# --- and the rest, which the other script already knows how to do -------------
./scripts/start-in-docker.sh --port "$port" ${forward[@]+"${forward[@]}"}

# --- one more thing a first-timer wants: the page, open ----------------------
url="http://localhost:${port}/"
if command -v open >/dev/null 2>&1; then
  open "$url" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$url" >/dev/null 2>&1 || true
fi
