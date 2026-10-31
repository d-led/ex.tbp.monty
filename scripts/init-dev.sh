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
# Needs Elixir 1.20 with the OTP it runs on, node/npm for the asset bundle, and
# Docker for the Postgres config/dev.exs expects on port 6432.

set -euo pipefail

cd "$(dirname "$0")/.."

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

while (($#)); do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v mix >/dev/null 2>&1 ||
  die "mix is not on PATH: install Elixir 1.20 (https://elixir-lang.org/install.html) and run this again"

command -v npm >/dev/null 2>&1 ||
  die "npm is not on PATH: the asset bundle is built with it (nodejs.org), so install Node and run this again"

command -v docker >/dev/null 2>&1 ||
  die "docker is not on PATH: install Docker Desktop (https://docs.docker.com/get-docker/) for the development Postgres and run this again"

echo "starting Postgres (docker compose)" >&2
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
