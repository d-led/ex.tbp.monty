#!/usr/bin/env bash
#
# A first look, in one command: the published image, a Postgres of its own, and
# a URL to open.
#
#   scripts/start-in-docker.sh                 # pull :latest, run on http://localhost:4001
#   scripts/start-in-docker.sh --port 5000
#   scripts/start-in-docker.sh --tag v1.2.3
#   scripts/start-in-docker.sh --local         # the image this checkout built (scripts/image.sh build)
#   scripts/start-in-docker.sh --data ~/tbp    # with a Monty tree mounted read-only
#   scripts/start-in-docker.sh --stop          # stop it, keeping the volumes
#   scripts/start-in-docker.sh --purge         # …and delete the database and the app's files
#
# Nothing here needs a checkout of the application, a Mix install, or a
# database: the app and Postgres arrive as containers on a private network of
# their own, and the two things worth keeping between runs — the database and
# the app's drafts, run logs and downloads — are named volumes.
#
# This is for looking, not for deploying. The password is in the URL below, the
# secret key is generated per run (so sessions do not survive a restart), and the
# container is the unprivileged shape the image is built for: read-only root,
# one volume, no root. docs/container.md has the options that matter when this
# becomes a deployment.

set -euo pipefail

cd "$(dirname "$0")/.."

app_image="ghcr.io/d-led/ex.tbp.monty"
tag="latest"
port="4001"
data_dir=""
local_image=0
stop=0
purge=0

db_container="ex-tbp-monty-db"
app_container="ex-tbp-monty-app"
db_volume="ex-tbp-monty-db-data"
app_volume="ex-tbp-monty-priv"
network="ex-tbp-monty"

# The image's docs say the volume has to belong to this uid; a volume the daemon
# creates from the image inherits it, which is why this is a named volume and
# not a bind mount.
app_uid="10001"

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

die() {
  echo "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --data) data_dir="${2:?--data needs a directory}"; shift 2 ;;
    --local) local_image=1; tag="local"; shift ;;
    --stop) stop=1; shift ;;
    --purge) stop=1; purge=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

command -v docker >/dev/null 2>&1 ||
  die "docker is not on PATH: install Docker Desktop (or docker engine) and run this again"

if ((stop)); then
  docker rm -f "$app_container" "$db_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true

  if ((purge)); then
    docker volume rm "$app_volume" "$db_volume" >/dev/null 2>&1 || true
    echo "stopped, and deleted the database and the app's files" >&2
  else
    echo "stopped; the database and the app's files are kept (--purge deletes them)" >&2
  fi

  exit 0
fi

# --- the image ---------------------------------------------------------------
if ((local_image)); then
  docker image inspect "${app_image}:${tag}" >/dev/null 2>&1 ||
    die "no ${app_image}:${tag} here: build it first with scripts/image.sh build"
  echo "using the local image ${app_image}:${tag}" >&2
else
  echo "pulling ${app_image}:${tag}" >&2
  docker pull "${app_image}:${tag}" ||
    die "could not pull ${app_image}:${tag}. If it has not been published yet, build it with scripts/image.sh build and run this with --local"
fi

# --- a network of their own, so the app can reach Postgres by name -----------
docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null

# --- Postgres ----------------------------------------------------------------
if ! docker volume inspect "$db_volume" >/dev/null 2>&1; then
  docker volume create "$db_volume" >/dev/null
fi

if docker container inspect "$db_container" >/dev/null 2>&1; then
  docker start "$db_container" >/dev/null
else
  # The major version CI runs and the suite was written against; pinned, so a
  # first look is not the place a database upgrade surprises anybody.
  docker run -d --name "$db_container" --network "$network" \
    -e POSTGRES_PASSWORD=monty -e POSTGRES_USER=monty -e POSTGRES_DB=monty \
    -v "${db_volume}:/var/lib/postgresql/data" \
    postgres:17 >/dev/null
fi

# Nothing else can start before it answers, and "cannot connect" from a
# migration is a worse message than waiting a second here.
ready=0
for _ in $(seq 1 60); do
  if docker exec "$db_container" pg_isready -U monty -d monty >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
((ready)) || die "Postgres did not become ready in 60 s; see: docker logs $db_container"

database_url="ecto://monty:monty@${db_container}:5432/monty"
secret_key_base="${SECRET_KEY_BASE:-$(openssl rand -base64 48)}"

# --- migrate, then serve -----------------------------------------------------
docker run --rm --network "$network" --entrypoint /app/bin/migrate \
  -e "DATABASE_URL=${database_url}" \
  -e "SECRET_KEY_BASE=${secret_key_base}" \
  "${app_image}:${tag}"

if ! docker volume inspect "$app_volume" >/dev/null 2>&1; then
  docker volume create "$app_volume" >/dev/null
fi

docker rm -f "$app_container" >/dev/null 2>&1 || true

app_arguments=(
  run -d --name "$app_container" --network "$network"
  --read-only --tmpfs /tmp
  -v "${app_volume}:/app/priv"
  -p "${port}:4000"
  -e "DATABASE_URL=${database_url}"
  -e "SECRET_KEY_BASE=${secret_key_base}"
  --restart unless-stopped
)

# Read-only on purpose: a tree somebody else owns is there to be read, and the
# app can still download into its own volume.
[[ -n "$data_dir" ]] && app_arguments+=(-v "${data_dir}:/app/priv/tbp:ro")

echo "starting ${app_image}:${tag} on port ${port}" >&2
docker "${app_arguments[@]}" "${app_image}:${tag}" >/dev/null

# --- and say something only when it is true ----------------------------------
health=""
for _ in $(seq 1 90); do
  health=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}/health" || true)
  [[ "$health" == "200" ]] && break
  sleep 1
done

if [[ "$health" != "200" ]]; then
  docker logs "$app_container" >&2 || true
  die "the app did not answer /health within 90 s; nothing is serving on port ${port}"
fi

build=$(curl -s "http://localhost:${port}/" | grep -o 'font-mono">[^<]*' | head -1 | sed 's/.*>//')

cat <<TEXT

  Monty on the BEAM is running.

    http://localhost:${port}          the studio: every experiment Monty ships

    http://localhost:${port}/health   the database, once

  build: ${build:-unknown}
  http://localhost:${port}/prerequisites is where data and models are downloaded;
  nothing large is in the image, and a run tells you what it is missing.

  Stop it with:  scripts/start-in-docker.sh --stop    (--purge also deletes its data)

TEXT

# A container that exits straight away would only surface as an empty page.
if [[ "$(docker inspect -f '{{.State.Running}}' "$app_container")" != "true" ]]; then
  docker logs "$app_container" >&2 || true
  die "the container is not running; the log above says why"
fi
