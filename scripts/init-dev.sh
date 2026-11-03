#!/usr/bin/env bash
#
# Prepare this checkout to run: Postgres, the dependencies, the database, the
# assets.
#
#   scripts/init-dev.sh
#
# Run it once, and again after a pull that moves a dependency or a migration.
# `mix setup` decides what that costs; everything it writes stays local — a
# Docker volume for Postgres, deps/ and _build/, the development database.
#
# Needs node/npm for the asset bundle and Docker for the Postgres the dev stack
# publishes on 6432 — this project's port, so a second project's database on the
# default one is never mistaken for it. The application reads that port from
# config/runtime.exs and defaults to it, so nothing has to be exported here.
# Elixir 1.20 and a Rust toolchain are installed for you
# when this machine has neither.

set -euo pipefail

cd "$(dirname "$0")/.."

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v npm >/dev/null 2>&1 ||
  die "npm is not on PATH: the asset bundle is built with it (nodejs.org), so install Node and run this again"

command -v docker >/dev/null 2>&1 ||
  die "docker is not on PATH: install Docker Desktop (https://docs.docker.com/get-docker/) for the development Postgres and run this again"

# The two toolchains come after the cheap checks, because installing one is a
# download measured in minutes. Both are build requirements — `mix compile`
# stops without Elixir, and it stops without Rust too, which is what rustler
# compiles the nearest-neighbour index (native/kd_tree_nif) with. Each
# installer is a no-op where its own toolchain is already on PATH.
elixir_bin="$(scripts/install-elixir.sh)"
if [ -n "$elixir_bin" ]; then
  PATH="$elixir_bin:$PATH"
  export PATH
fi

scripts/install-rust.sh

echo "starting Postgres (docker compose up -d)" >&2
docker compose up -d

ready=0
for _ in $(seq 1 60); do
  if docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
((ready)) || die "Postgres did not answer within 60 s; see: docker compose logs postgres"

mix setup

cat <<'TEXT'

  ready. Start the application with:

    scripts/run-dev.sh        http://localhost:4000

TEXT
