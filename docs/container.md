# Running the container image

One OTP release, built once and shipped as an image: the studio, the port, the
worlds and — embedded — the Python that Monty's loggers call. It runs as an
unprivileged user, with one writable directory, and it reports nothing to
anybody: what it did is in its own database, on its own volume, and on its own
pages.

```bash
docker pull ghcr.io/d-led/ex.tbp.monty:latest

docker run --rm -p 6401:4000 \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -v monty-runs:/app/priv \
  ghcr.io/d-led/ex.tbp.monty:latest
```

Then <http://localhost:6401>. The release migrates itself as it boots, so there
is no migration step in front of the server — `/app/bin/migrate` is there for an
operator who wants to migrate without starting one.

`docker compose -f docker-compose.quickstart.yml up` in this repository runs
that same thing with the database in a file on a volume.
[`docker-compose.postgres.yml`](../docker-compose.postgres.yml) beside it is the
same stack with a Postgres service of its own: same image, same port, same
volumes, and `DATABASE_URL` the only difference between them. Both were checked
by starting them: the file shape writes `ex_tbp_monty.db` on the volume, and the
server shape puts `studio_runs`, `schema_migrations` and Oban's two tables in
Postgres with no file in the container at all.

## The script, if you have the checkout

[`scripts/image.sh`](../scripts/image.sh) is the same thing under the same image
name, for a local tree: it builds with the build arguments CI passes, runs the
shape this page describes, and can publish both architectures.

```bash
scripts/image.sh build              # ghcr.io/d-led/ex.tbp.monty:local, from this tree
scripts/image.sh smoke              # build, migrate, serve, wait for /health, report, stop
scripts/image.sh run                # serve in the foreground (reads DATABASE_URL)
scripts/image.sh run --data /path/to/tbp   # …with a Monty tree mounted read-only
scripts/image.sh run --pull --tag main  # the published image instead
scripts/image.sh publish --tag main # buildx amd64 + arm64, pushed to GHCR
scripts/image.sh logs               # follow it
scripts/image.sh stop               # stop it and remove its volume
```

A single architecture is loaded into the local daemon; `--arch all` (and
`publish`) builds amd64 and arm64 into one index and pushes it, which is what
CI publishes. `--arch amd64|arm64` cross-builds one platform the same way.

## Tags

| Built from                 | Tags                                           |
| -------------------------- | ---------------------------------------------- |
| a push to `main`           | `:main` and `:latest`                          |
| a push to any other branch | `:<branch>` — `feature/x` becomes `:feature-x` |
| a tag `v1.2.3`             | `:v1.2.3`                                      |

Every published tag carries amd64 **and** arm64, each compiled on a runner of
its own architecture (`ubuntu-24.04`, `ubuntu-24.04-arm`), so neither half is
emulated. Both are needed: the amd64 release does not boot under emulation on
Apple Silicon (`{failed_to_start_child, user,nouser}` from the kernel), so an
amd64-only tag is an image an arm64 laptop cannot run. There are no commit-hash
tags: the image carries its commit instead, in `priv/build_info.json`, and the
footer of every page shows it.

## What it reports about itself

**Observability is the application's own.** The image does not talk to wandb:
`WANDB_MODE=disabled` is baked in, which is wandb's own no-op mode, so a Monty
config that names wandb loggers still runs and nothing is uploaded, written or
awaited. What a deployment can look at instead:

| Where                           | What                                                                                    |
| ------------------------------- | --------------------------------------------------------------------------------------- |
| `GET /health`                   | 200 when the database answers, 503 when it does not — `select 1`, nothing else          |
| stdout                          | each HTTP request (`GET / 200 in 5.4ms`), the build line at boot, Oban and Ecto notices |
| `/runs`, `/runs/:id`            | every run's record, summary, step log and the files it wrote, from Postgres             |
| `/jobs`                         | the Oban queue — where a run is before it has anything to show                          |
| `/app/priv/studio_runs/<uuid>/` | the same run's files as text a `grep` or `tail -f` can read                             |
| the footer                      | the build the page came from: `main+3f2a1c9`, with the whole build in its tooltip       |

To send runs to wandb anyway, `-e WANDB_MODE=online -e WANDB_API_KEY=...`: the
client forwards every `WANDB_*` variable into the interpreter on each init, and
writes under `WANDB_DIR` (below).

## Environment

`SECRET_KEY_BASE` has no default; the rest can be left alone. Everything below
is read by the release at boot, so it is an environment variable, not a config
file.

### The database

The runs live in one of two places, decided when the instance starts:

| Variable       | Default                 | Meaning                                                                                                               |
| -------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `DATABASE_URL` | unset → SQLite          | Postgres, `ecto://user:pass@host:5432/database`. Setting it is the whole switch: the same image then uses the server. |
| `SQLITE_PATH`  | `$HOME/ex_tbp_monty.db` | Where the file goes when there is no `DATABASE_URL`. In the image `$HOME` is `/app/priv`, so it lands on the volume.  |

Both drivers are in the release, and the queue follows the choice: Oban's own
engine on SQLite, its locking one on Postgres. A fresh file gets the schema by
running `/app/bin/migrate` — or by booting, which migrates first.

### The memory

The memory a run recognises with is an export of the pretrained pickles, written
at run time, so it is kept beside the data rather than inside the release:
`MONTY_LIBRARIES`, which defaults to `$MONTY_DATA/libraries`. On a volume the
first fetch exports it once; inside the image's own filesystem it is thrown away
with the container, and every start reads every model again.

Nothing blocks on any of this. Every prerequisite with work left in it — the ones
that are absent _and_ the ones that arrived without the memory a run reads — is
fetched in the background as the server starts (`PREFETCH=0` turns that off),
`/prerequisites` shows each download as it happens, and a run whose data has not
arrived yet says so — rather than failing inside the simulator.

### Required

| Variable          | Meaning                                                                         |
| ----------------- | ------------------------------------------------------------------------------- |
| `SECRET_KEY_BASE` | Signs cookies and sessions (`mix phx.gen.secret`). Refuses to start without it. |

### HTTP

| Variable     | Default             | Meaning                                                                                                                                                                                                     |
| ------------ | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PORT`       | `4000`              | The port Bandit listens on, on all interfaces.                                                                                                                                                              |
| `PHX_HOST`   | `example.com`       | The host absolute URLs are built from (links, redirects). Set it to the name users reach, or the pages will link to `example.com`. URLs are generated as `https://<PHX_HOST>/…`, so terminate TLS in front. |
| `PHX_SERVER` | set by `bin/server` | What makes the release start the endpoint. Only matters if you run `bin/ex_tbp_monty start` yourself.                                                                                                       |

### Database

| Variable    | Default | Meaning                                                                                                                                              |
| ----------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POOL_SIZE` | `10`    | Connections per node. Runs are Oban jobs that write as they step, so size it to the concurrent runs you expect rather than to the number of readers. |
| `ECTO_IPV6` | unset   | `true`/`1` resolves and connects over IPv6 — needed on a Fly private network, wrong for a managed Postgres without an AAAA record.                   |

### Clustering

One node is a supported deployment; these are for more than one. The release
names the node from whichever of these it finds, in this order: Fly, Kubernetes,
explicit, local.

| Variable                                          | Meaning                                                                                                                                                                                   |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FLY_APP_NAME`, `FLY_IMAGE_REF`, `FLY_PRIVATE_IP` | On Fly the node names itself `<app>-<tag>@<private IPv6>`, binds distribution over IPv6 and sets `DNS_CLUSTER_QUERY` to `<app>.internal` (and `ECTO_IPV6=true` unless you say otherwise). |
| `POD_NAME`, `POD_IP`                              | On Kubernetes the node names itself `<pod>@<pod IP>` (from the downward API), which a StatefulSet keeps stable.                                                                           |
| `RELEASE_NODE`                                    | An explicit `<name>@<host>` for anywhere else.                                                                                                                                            |
| `RELEASE_DISTRIBUTION`                            | `name` or `sname`; implied by the two above, `sname` otherwise.                                                                                                                           |
| `RELEASE_COOKIE`                                  | Set it, and every node that should join the same cluster must agree.                                                                                                                      |
| `DNS_CLUSTER_QUERY`                               | A DNS name whose answers are the peers to join. Without it the app is a cluster of one.                                                                                                   |
| `ERL_AFLAGS`                                      | Extra emulator flags; the Fly branch adds `-proto_dist inet6_tcp`.                                                                                                                        |

### World

A run steps MuJoCo, in the interpreter the release carries. `mujoco` arrives as
a wheel when the image is built (`config/pythonx.exs`), the scene is
`priv/monty_py/world.py`, and there is nothing for an operator to install. The
other choice is this port's stand-in scene, which the setup page names.

| Variable          | Default | Meaning                                                                                                |
| ----------------- | ------- | ------------------------------------------------------------------------------------------------------ |
| `MONTY_OVERRIDES` | unset   | Hydra overrides for a config composed from a checkout, space separated as on Monty's own command line. |

### This image's own choices

| Variable         | Image value       | Why                                                                                                                                                      |
| ---------------- | ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `WANDB_MODE`     | `disabled`        | No wandb from a container. `online` plus `WANDB_API_KEY` (and any other `WANDB_*`) turns it back on; the client forwards them into the interpreter.      |
| `WANDB_DIR`      | `/app/priv/wandb` | Where a wandb run would write. It has to exist — wandb silently uses the system temp directory otherwise — so `bin/server` creates it at boot.           |
| `HOME`           | `/app/priv`       | A run's downloads and pretrained models go under `$HOME/tbp`, i.e. `/app/priv/tbp`; the image gives the unprivileged user a writable home on the volume. |
| `LANG`, `LC_ALL` | `en_US.UTF-8`     | Experiment names sort and log as written.                                                                                                                |
| `MIX_ENV`        | `prod`            | The release is a prod build; this is only informational at run time.                                                                                     |

Not used by the image: `MONTY_SOURCE` and `TELEOP_SOURCE` (only the tasks that
regenerate from upstream read a checkout), `PYTHON` (one Mix task),
`MIX_TEST_PARTITION` and `COVERAGE_THRESHOLD` (CI). The configs and snapshots the
studio reads are **inside** the image — `/app/lib/ex_tbp_monty-*/priv/monty` for
the release's own copy and `/app/priv/monty` for the one `HOME` and the `bin/priv`
symlink point at; they need no checkout and take no volume.

The MCP server's documentation and roadmap tools read no filesystem at all:
they ask `docs.thousandbrains.org` and the project's roadmap data, so they answer
the same here as on a laptop. They are the one part of the server that needs
outbound HTTPS; every other tool answers from the image or the database, and a
site that cannot be reached is reported in words rather than failing a call.

## Data and models: the prerequisites

The image carries the software and Monty's own config tree — every config it
ships, the snapshots they are held to, the worlds and the Python that steps
them. What it does not carry is the memory those configs read:
`/app/priv/monty/libraries` is derived data, exported from the pretrained model
bundle, so an image built from a checkout has the directory and nothing in it,
and the first `/prerequisites` download fills it (that fetch ends by exporting
the libraries, and a later visit exports nothing). The datasets and the model
bundles themselves are not in it either: they are big, they change on their own
schedule, and a pull that shipped them would be a pull nobody wants.
`/prerequisites` lists what an experiment needs, the path each file goes to, and
which of them are already there.

Three ways to have them:

| Where they come from          | How                                                                                                                                                                                                                                                |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| fetched from a terminal       | `docker run --rm -v monty-priv:/app/priv … /app/bin/prerequisites` — the page's fetch, for a deployment that would rather script it. It fetches what is missing, waits, exports the libraries and exits; on a volume that has them it does nothing |
| downloaded by the running app | open `/prerequisites` in the UI and press download per entry. Each file streams to a `.part` name on the volume and is moved into place only when its size and checksum match                                                                      |
| a Monty tree you already have | `-v /path/to/tbp:/app/priv/tbp:ro` — the defaults hang off `HOME`, which is `/app/priv`, so the directory you mount is the one those defaults already point at. `scripts/image.sh run --data /path/to/tbp` is this row with the flag spelled out   |
| anywhere else                 | `-e MONTY_DATA=… -e MONTY_MODELS=… -e MONTY_LOGS=…` — the variables Monty's own documentation uses — each pointing at a mounted path                                                                                                               |

The volume to mount for downloads is `/app/priv/tbp`, and that is what
[`docker-compose.quickstart.yml`](../docker-compose.quickstart.yml) names —
beside a second one for Postgres, so `docker compose down` keeps both the
database and the downloaded bundles (`down -v` deletes them). Mounting
`/app/priv` itself also works but hides the prerequisites the image carries;
mounting `/app/priv/tbp` leaves them alone.

A read-only mount is enough to _run_ against data you already have. Downloading
into it needs write access, so leave the mount out (or make it writable) when the
app should fetch them itself; either way they land on the volume and survive a
restart.

Nothing is fetched at boot: an offline container runs any experiment whose files
are in place, and `/prerequisites` is what says which ones are missing. From a
fresh volume a MuJoCo run needs two downloads on that page — the YCB meshes it
renders and the pretrained release its config names — after which the first
experiment has its memory and starts. The third entry there, the older release
the recorded parity episodes were made with, is not one of them.

### The world needs nothing installed

MuJoCo runs in the interpreter the release already carries. `pythonx` builds it
at compile time and ships it under `/app/lib/pythonx-*/priv`, with `mujoco` and
`numpy` in it; `priv/monty_py/world.py` is the scene, the agents and their
cameras. So a MuJoCo run needs two things beyond the image, and neither is a
package: the GL libraries MuJoCo's offscreen camera rendering uses (`libegl1`,
`libgl1`, `libosmesa6`, installed by the Dockerfile) and the datasets below.

**Habitat-Sim is not carried.** It exists only as a conda package for `linux-64`
and `osx-64`, built against Python 3.9, and this application's world is MuJoCo.
A Habitat config is reported as a world this build does not have, rather than
being started and failing at its first step.

### The embedded Python is not one of them

pythonx's environment — CPython and the packages named in
[`config/pythonx.exs`](../config/pythonx.exs) —
is built when the release is _compiled_: uv downloads and installs it then, which
is most of the image's size. At run time nothing is downloaded and nothing is
written; `pythonx` starts the interpreter from the release's `priv` on the boot
path, so a run pays no first-use penalty for having Python at all — starting it
measures in the low hundreds of milliseconds of boot.

The one thing that _is_ lazy is `import wandb` inside that interpreter: about a
second, once, on the first run that names a wandb logger. Paying it at boot for a
process that may never log to wandb would be the worse trade, so it is left
where it is. `/prerequisites` shows the interpreter's version and where a run
would report — `wandb disabled` in this image — which is the pair worth knowing
before a run.

## What is on the volume, and what owns it

`/app/priv` is the only writable directory, and everything that writes is
pointed at it — the studio's drafts, a run's files (`/app/bin/priv` is a symlink
into it, because a release resolves those paths relative to its own `bin/`),
Monty's downloads under `$HOME/tbp`, wandb's runs.

That directory must belong to uid **10001**. The image cannot arrange it —
giving ownership away needs the root it deliberately does not have:

| Volume                                          | What to do                                                        |
| ----------------------------------------------- | ----------------------------------------------------------------- |
| Docker named volume (`-v monty-priv:/app/priv`) | Nothing: Docker copies the image's directory, ownership included. |
| Kubernetes PVC                                  | `securityContext: { fsGroup: 10001 }` on the pod.                 |
| Bind mount, tmpfs, Fly volume                   | `chown 10001:10001` the mount point once.                         |

When it is wrong, the release says so at boot — `the release cannot write
/app/priv/wandb (uid 10001); wandb will use the system temp directory` — and
runs on, because a wrong volume is not a reason to refuse to serve.

## Operating it

```bash
# The release's own tools, next to the running node
docker exec <container> /app/bin/ex_tbp_monty rpc 'ExTbpMonty.Repo.query!("select 1")'
docker exec <container> /app/bin/ex_tbp_monty eval 'IO.inspect(Application.spec(:ex_tbp_monty, :vsn))'
docker exec <container> /app/bin/ex_tbp_monty remote     # a shell on the node
```

A healthcheck that means something: `GET /health` answers 200 when the
database is reachable and 503 when it is not, so an orchestrator's HTTP probe
covers it — Fly's `[[http_service.checks]]`, a Kubernetes `readinessProbe` on
`/health`, or any uptime monitor pointed at it.

The image carries no HTTP client of its own (no `curl`, no `wget`), so a
`docker --health-cmd` needs one added first; a probe from outside the container
needs nothing.

## What is inside

- The release, at `/app`, owned by uid 10001, with `bin/migrate`, `bin/server`
  and the OTP tools above.
- The embedded Python: `/app/lib/pythonx-*/priv` holds `libpythonx.so` and a uv
  environment built from [`config/pythonx.exs`](../config/pythonx.exs). Most of the image is that
  environment — and it is why nothing has to be installed on the host for
  Monty's loggers to work.
- No compiler, no Node, no git, no Hex cache: those live in the builder stage
  only.
- Nothing writable but `/app/priv`, which is why `--read-only` works — and why
  CI checks that it does, on every image it builds.
