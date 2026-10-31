# Running the container image

One OTP release, built once and shipped as an image: the studio, the port, the
worlds and — embedded — the Python that Monty's loggers call. It runs as an
unprivileged user, with one writable directory, and it reports nothing to
anybody: what it did is in its own database, on its own volume, and on its own
pages.

```bash
docker pull ghcr.io/d-led/ex.tbp.monty:latest

# Once per deploy: the release expects its tables to exist.
docker run --rm \
  -e DATABASE_URL=ecto://user:pass@host:5432/monty \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  ghcr.io/d-led/ex.tbp.monty:latest /app/bin/migrate

# …and then the app, with the one writable directory on a volume.
docker run --rm -p 4000:4000 \
  --read-only --tmpfs /tmp \
  -v monty-priv:/app/priv \
  -e DATABASE_URL=ecto://user:pass@host:5432/monty \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  ghcr.io/d-led/ex.tbp.monty:latest
```

Then <http://localhost:4000> — every experiment Monty ships, and a run you can
start from any of them.

## The script, if you have the checkout

`scripts/image.sh` is the same thing under the same image name, for a local
tree: it builds with the build arguments CI passes, runs the shape this page
describes, and can publish both architectures.

```bash
scripts/image.sh build              # ghcr.io/d-led/ex.tbp.monty:local, from this tree
scripts/image.sh smoke              # build, migrate, serve, wait for /health, report, stop
scripts/image.sh run                # serve in the foreground (reads DATABASE_URL)
scripts/image.sh run --data ~/tbp   # …with a Monty tree mounted read-only
scripts/image.sh run --pull --tag main  # the published image instead
scripts/image.sh publish --tag main # buildx amd64 + arm64, pushed to GHCR
scripts/image.sh logs               # follow it
scripts/image.sh stop               # stop it and remove its volume
```

A single architecture is loaded into the local daemon; `--arch all` (and
`publish`) builds amd64 and arm64 into one index and pushes it, which is what a
release tag publishes. `--arch amd64|arm64` cross-builds one platform the same
way.

## Tags

| Built from | Tags |
| --- | --- |
| a push to `main` | `:main` and `:latest` |
| a push to any other branch | `:<branch>` — `feature/x` becomes `:feature-x` |
| a tag `v1.2.3` | `:v1.2.3`, amd64 **and** arm64 |

A branch publishes amd64 only; the arm64 half is compiled under QEMU and is the
expensive part, so a release tag (or `gh workflow run ci --field image=true`)
pays for it. There are no commit-hash tags: the image carries its commit
instead, in `priv/build_info.json`, and the footer of every page shows it.

## What it reports about itself

**Observability is the application's own.** The image does not talk to wandb:
`WANDB_MODE=disabled` is baked in, which is wandb's own no-op mode, so a Monty
config that names wandb loggers still runs and nothing is uploaded, written or
awaited. What a deployment can look at instead:

| Where | What |
| --- | --- |
| `GET /health` | 200 when the database answers, 503 when it does not — `select 1`, nothing else |
| stdout | each HTTP request (`GET / 200 in 5.4ms`), the build line at boot, Oban and Ecto notices |
| `/runs`, `/runs/:id` | every run's record, summary, step log and the files it wrote, from Postgres |
| `/jobs` | the Oban queue — where a run is before it has anything to show |
| `/app/priv/studio_runs/<uuid>/` | the same run's files as text a `grep` or `tail -f` can read |
| the footer | the build the page came from: `main+3f2a1c9`, with the whole build in its tooltip |

To send runs to wandb anyway, `-e WANDB_MODE=online -e WANDB_API_KEY=...`: the
client forwards every `WANDB_*` variable into the interpreter on each init, and
writes under `WANDB_DIR` (below).

## Environment

`DATABASE_URL` and `SECRET_KEY_BASE` have no default; the rest can be left
alone. Everything below is read by the release at boot, so it is an environment
variable, not a config file.

### Required

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | Postgres, `ecto://user:pass@host:5432/database`. The release refuses to start without it. |
| `SECRET_KEY_BASE` | Signs cookies and sessions (`mix phx.gen.secret`). Refuses to start without it. |

### HTTP

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `4000` | The port Bandit listens on, on all interfaces. |
| `PHX_HOST` | `example.com` | The host absolute URLs are built from (links, redirects). Set it to the name users reach, or the pages will link to `example.com`. URLs are generated as `https://<PHX_HOST>/…`, so terminate TLS in front. |
| `PHX_SERVER` | set by `bin/server` | What makes the release start the endpoint. Only matters if you run `bin/ex_tbp_monty start` yourself. |

### Database

| Variable | Default | Meaning |
| --- | --- | --- |
| `POOL_SIZE` | `10` | Connections per node. Runs are Oban jobs that write as they step, so size it to the concurrent runs you expect rather than to the number of readers. |
| `ECTO_IPV6` | unset | `true`/`1` resolves and connects over IPv6 — needed on a Fly private network, wrong for a managed Postgres without an AAAA record. |

### Clustering

One node is a supported deployment; these are for more than one. The release
names the node from whichever of these it finds, in this order: Fly, Kubernetes,
explicit, local.

| Variable | Meaning |
| --- | --- |
| `FLY_APP_NAME`, `FLY_IMAGE_REF`, `FLY_PRIVATE_IP` | On Fly the node names itself `<app>-<tag>@<private IPv6>`, binds distribution over IPv6 and sets `DNS_CLUSTER_QUERY` to `<app>.internal` (and `ECTO_IPV6=true` unless you say otherwise). |
| `POD_NAME`, `POD_IP` | On Kubernetes the node names itself `<pod>@<pod IP>` (from the downward API), which a StatefulSet keeps stable. |
| `RELEASE_NODE` | An explicit `<name>@<host>` for anywhere else. |
| `RELEASE_DISTRIBUTION` | `name` or `sname`; implied by the two above, `sname` otherwise. |
| `RELEASE_COOKIE` | Set it, and every node that should join the same cluster must agree. |
| `DNS_CLUSTER_QUERY` | A DNS name whose answers are the peers to join. Without it the app is a cluster of one. |
| `ERL_AFLAGS` | Extra emulator flags; the Fly branch adds `-proto_dist inet6_tcp`. |

### World

Monty's own simulator runs out of process, in the embedded interpreter; without
these a run steps this port's synthetic scene, and the setup page says so.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MONTY_WORLD` | unset (synthetic) | `synthetic` steps the built-in scene; `monty` or `habitat` step Monty's own environment through the peer. Any other value fails the boot rather than the run. |
| `MONTY_PYTHON` | unset | The interpreter the peer runs on. It is *not* the embedded one: Monty's simulator brings its own dependencies. |
| `MONTY_OVERRIDES` | unset | Hydra overrides passed to the peer, e.g. `experiment.config.environment.env_init_args.data_path=/data/ycb`. |

### This image's own choices

| Variable | Image value | Why |
| --- | --- | --- |
| `WANDB_MODE` | `disabled` | No wandb from a container. `online` plus `WANDB_API_KEY` (and any other `WANDB_*`) turns it back on; the client forwards them into the interpreter. |
| `WANDB_DIR` | `/app/priv/wandb` | Where a wandb run would write. It has to exist — wandb silently uses the system temp directory otherwise — so `bin/server` creates it at boot. |
| `HOME` | `/app/priv` | `~/tbp` is where a run's downloads and pretrained models go; the image gives the unprivileged user a writable home on the volume. |
| `LANG`, `LC_ALL` | `en_US.UTF-8` | Experiment names sort and log as written. |
| `MIX_ENV` | `prod` | The release is a prod build; this is only informational at run time. |

Not used by the image: `MONTY_SOURCE` and `TELEOP_SOURCE` (only the tasks that
regenerate from upstream read a checkout), `PYTHON` (one Mix task),
`MIX_TEST_PARTITION` and `COVERAGE_THRESHOLD` (CI). The configs and snapshots the
studio reads are **inside** the image, under `/app/lib/ex_tbp_monty-*/priv/monty`;
they need no checkout and take no volume.

## Data and models: the prerequisites

The image carries the software, not the data. Monty's datasets and pretrained
models are large, they change on their own schedule, and a pull that shipped
them would be a pull nobody wants. `/prerequisites` lists what an experiment
needs, the path each file goes to, and which of them are already there.

Three ways to have them:

| Where they come from | How |
| --- | --- |
| downloaded by the running app | open `/prerequisites` and press download. Each file streams to a `.part` name on the volume and is moved into place only when its size and checksum match |
| a Monty tree you already have | `-v ~/tbp:/app/priv/tbp:ro` — the defaults hang off `HOME`, which is `/app/priv`, so `~/tbp` inside the container is exactly where this machine's `~/tbp` lands. `scripts/image.sh run --data ~/tbp` is this row with the flag spelled out |
| anywhere else | `-e MONTY_DATA=… -e MONTY_MODELS=… -e MONTY_LOGS=…` — the variables Monty's own documentation uses — each pointing at a mounted path |

A read-only mount is enough to *run* against data you already have. Downloading
into it needs write access, so leave the mount out (or make it writable) when the
app should fetch them itself; either way they land on the volume and survive a
restart.

Nothing is fetched at boot: an offline container runs any experiment whose files
are in place, and `/prerequisites` is what says which ones are missing.

### The embedded Python is not one of them

pythonx's environment — CPython and the packages named in `config/pythonx.exs` —
is built when the release is *compiled*: uv downloads and installs it then, which
is most of the image's size. At run time nothing is downloaded and nothing is
written; `pythonx` starts the interpreter from the release's `priv` on the boot
path, so a run pays no first-use penalty for having Python at all — starting it
measures in the low hundreds of milliseconds of boot.

The one thing that *is* lazy is `import wandb` inside that interpreter: about a
second, once, on the first run that names a wandb logger. Paying it at boot for a
process that may never log to wandb would be the worse trade, so it is left
where it is. `/prerequisites` shows the interpreter's version and where a run
would report — `wandb disabled` in this image — which is the pair worth knowing
before a run.

## What is on the volume, and what owns it

`/app/priv` is the only writable directory, and everything that writes is
pointed at it — the studio's drafts, a run's files (`/app/bin/priv` is a symlink
into it, because a release resolves those paths relative to its own `bin/`),
Monty's downloads under `~/tbp`, wandb's runs.

That directory must belong to uid **10001**. The image cannot arrange it —
giving ownership away needs the root it deliberately does not have:

| Volume | What to do |
| --- | --- |
| Docker named volume (`-v monty-priv:/app/priv`) | Nothing: Docker copies the image's directory, ownership included. |
| Kubernetes PVC | `securityContext: { fsGroup: 10001 }` on the pod. |
| Bind mount, tmpfs, Fly volume | `chown 10001:10001` the mount point once. |

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

* The release, at `/app`, owned by uid 10001, with `bin/migrate`, `bin/server`
  and the OTP tools above.
* The embedded Python: `/app/lib/pythonx-*/priv` holds `libpythonx.so` and a uv
  environment built from `config/pythonx.exs`. Most of the image is that
  environment — and it is why nothing has to be installed on the host for
  Monty's loggers to work.
* No compiler, no Node, no git, no Hex cache: those live in the builder stage
  only.
* Nothing writable but `/app/priv`, which is why `--read-only` works — and why
  CI checks that it does, on every image it builds.
