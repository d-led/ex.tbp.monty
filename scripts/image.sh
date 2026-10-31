#!/usr/bin/env bash
#
# The image, from this checkout: build it, run it, smoke it, publish it.
#
#   scripts/image.sh build             build for this machine, tagged ghcr.io/d-led/ex.tbp.monty:local
#   scripts/image.sh build --arch all  amd64 + arm64 in one index, pushed (buildx, under QEMU)
#   scripts/image.sh run               migrate, then serve unprivileged on a volume, in the foreground
#   scripts/image.sh run --pull        …the published image instead of what was built here
#   scripts/image.sh run --data ~/tbp  …with a Monty tree mounted read-only where it looks for one
#   scripts/image.sh smoke             build, migrate, serve, wait for /health, report, stop
#   scripts/image.sh publish           buildx amd64 + arm64, push to ghcr.io/d-led/ex.tbp.monty:<tag>
#   scripts/image.sh stop              stop the container and remove its volume
#   scripts/image.sh logs              follow the running container's output
#
# The image name is the one CI publishes and the one `docker pull` would fetch,
# so a local build carries the name a published one has — `:main` over there,
# `:local` here — and the same script runs either.
#
# What `run` and `smoke` set up is the shape the image is verified in
# (docs/container.md): a read-only root filesystem, a tmpfs for /tmp, and one
# volume at /app/priv that holds everything the app writes — drafts, run
# artifacts, Monty's downloads, wandb's runs.
#
# `DATABASE_URL` is required by `run` and `smoke`: the release migrates and then
# serves one Postgres, and nothing here invents databases.
#
# Exit status is non-zero when a step fails, so this can sit in a pipeline.

set -euo pipefail

cd "$(dirname "$0")/.."

image="${IMAGE:-ghcr.io/d-led/ex.tbp.monty}"
container="${CONTAINER:-ex-tbp-monty-local}"
volume="${VOLUME:-ex-tbp-monty-local-priv}"
tag="${TAG:-local}"
port="${PORT:-4000}"
database_url="${DATABASE_URL:-}"
secret_key_base="${SECRET_KEY_BASE:-}"
# A Monty tree on this machine — data, results, logs — mounted read-only where
# the image's defaults look for one: HOME is /app/priv, so ~/tbp is
# /app/priv/tbp.
data_dir=""

# native, amd64, arm64 or all
arch=native
detach=0
pull=0
skip_build=0
skip_migrate=0

usage() {
  sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

die() {
  echo "$*" >&2
  exit 1
}

# The build arguments CI passes, from the same sources: what the footer names
# and the commit the image carries. A tree that is not the commit says so.
version() { git describe --tags --always --dirty 2>/dev/null || echo dev; }
revision() { git rev-parse HEAD 2>/dev/null || true; }

platforms() {
  case "$arch" in
    native) echo "linux/$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')" ;;
    all) echo "linux/amd64,linux/arm64" ;;
    amd64 | arm64) echo "linux/$arch" ;;
    *) die "--arch takes amd64, arm64 or all, not: $arch" ;;
  esac
}

build() {
  local target publish
  target=$(platforms)

  # An index of two architectures cannot be loaded into the daemon: it is
  # pushed, or it goes nowhere. Say that rather than building one silently.
  if [[ "$target" == *","* ]]; then
    publish=--push
  else
    publish=--load
  fi

  echo "building ${image}:${tag} for ${target}" >&2
  docker buildx build \
    --platform "$target" \
    "$publish" \
    --build-arg "VERSION=$(version)" \
    --build-arg "REVISION=$(revision)" \
    -t "${image}:${tag}" \
    .
}

require_database() {
  [[ -n "$database_url" ]] ||
    die "DATABASE_URL is required: the release migrates and serves a Postgres, e.g. ecto://postgres:postgres@localhost:5432/monty"
}

# One secret for the migrate run and the server after it, so a session opened by
# one is readable by the other.
ensure_secret() {
  [[ -n "$secret_key_base" ]] || secret_key_base=$(openssl rand -base64 48)
}

migrate() {
  require_database
  ensure_secret

  docker run --rm --entrypoint /app/bin/migrate \
    -e "DATABASE_URL=${database_url}" \
    -e "SECRET_KEY_BASE=${secret_key_base}" \
    "${image}:${tag}"
}

create_volume=0

serve() {
  require_database
  ensure_secret

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    docker volume create "$volume" >/dev/null
    create_volume=1
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true

  # A volume the daemon creates from the image arrives owned by uid 10001, which
  # is the one thing the unprivileged container cannot arrange for itself.
  local arguments=(
    run --name "$container"
    --read-only --tmpfs /tmp
    -v "${volume}:/app/priv"
    -p "${port}:4000"
    -e "DATABASE_URL=${database_url}"
    -e "SECRET_KEY_BASE=${secret_key_base}"
  )

  # Read-only: a tree somebody else owns is there to be read, and the page can
  # still download into the volume when it is not given one.
  [[ -n "$data_dir" ]] && arguments+=(-v "${data_dir}:/app/priv/tbp:ro")

  ((detach)) && arguments+=(-d)

  echo "serving ${image}:${tag} on http://localhost:${port}" >&2
  docker "${arguments[@]}" "${image}:${tag}"
}

wait_for_health() {
  local deadline=$((SECONDS + 90)) code=""

  while ((SECONDS < deadline)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/health" || true)
    [[ "$code" == "200" ]] && return 0
    sleep 1
  done

  docker logs "$container" >&2 || true
  die "/health did not answer 200 within 90 s (last: ${code:-no answer})"
}

# What the page says it was built from, which is the build argument above.
footer_label() {
  curl -s "http://localhost:${port}/" |
    grep -o 'font-mono">[^<]*' | head -1 | sed 's/.*>//'
}

command=""
while (($#)); do
  case "$1" in
    build | run | smoke | publish | stop | logs) command="$1"; shift ;;
    --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
    --arch) arch="${2:?--arch needs a value}"; shift 2 ;;
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --db) database_url="${2:?--db needs a value}"; shift 2 ;;
    --data) data_dir="${2:?--data needs a directory}"; shift 2 ;;
    --detach) detach=1; shift ;;
    --pull) pull=1; shift ;;
    --no-build) skip_build=1; shift ;;
    --no-migrate) skip_migrate=1; shift ;;
    -h | --help) command=""; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$command" in
  build)
    build
    ;;
  run)
    ((pull)) && docker pull "${image}:${tag}"
    ((skip_migrate)) || migrate
    serve
    ;;
  smoke)
    ((skip_build)) || build
    ((skip_migrate)) || migrate
    detach=1
    serve
    wait_for_health
    echo "health 200, footer reports: $(footer_label)"
    docker rm -f "$container" >/dev/null
    # A smoke run leaves nothing behind: the container goes, and the volume too
    # unless it was already there.
    ((create_volume)) && docker volume rm "$volume" >/dev/null
    ;;
  publish)
    arch=all
    build
    echo "pushed ${image}:${tag} for $(platforms)" >&2
    ;;
  stop)
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
    echo "stopped ${container}, removed ${volume}" >&2
    ;;
  logs)
    docker logs -f "$container"
    ;;
  *)
    usage
    ;;
esac
