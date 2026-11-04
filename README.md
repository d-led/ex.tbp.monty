# Monty on the BEAM

[Monty](https://github.com/thousandbrainsproject/tbp.monty) is the Thousand
Brains Project's system: a sensor module moves over an object, learning modules
model it and say where the sensor is on it. This is that system rewritten in
Elixir — one process per module, every experiment Monty ships on a page in a
browser, and an MCP endpoint for an assistant.

The port is module for module and checked against Monty's own numbers;
differences are listed in [docs/monty-differences.md](docs/monty-differences.md).

## Run it

```bash
curl -fsSLO https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/docker-compose.quickstart.yml
docker compose -f docker-compose.quickstart.yml up
```

→ <http://localhost:6401>

The image is `ghcr.io/d-led/ex.tbp.monty:latest` (amd64 and arm64). That compose
file runs the image alone: the database is a file on a named volume, and the
release migrates itself as it boots. The volume and the `/prerequisites`
downloads are named, so `docker compose down` keeps them and `down -v` deletes
them.

Want a database server rather than the file? The same stack with Postgres beside
it — same image, same port, `DATABASE_URL` the only difference:

```bash
curl -fsSLO https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/docker-compose.postgres.yml
docker compose -f docker-compose.postgres.yml up
```

The image alone, against a Postgres you already have:

```bash
docker run --rm \
  -e DATABASE_URL=ecto://user:pass@host:5432/monty \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  ghcr.io/d-led/ex.tbp.monty:latest /app/bin/migrate      # once per deploy

docker run -d -p 4001:4000 \
  -e DATABASE_URL=ecto://user:pass@host:5432/monty \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=localhost \
  ghcr.io/d-led/ex.tbp.monty:latest
```

Tags, every variable, the one writable directory:
[docs/container.md](docs/container.md).

## As an app

The same application in a native window, with its own server inside — no
Docker, no Elixir, nothing to install but the app:

```bash
curl -fsSL https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/run-desktop.sh | bash
```

That line runs on macOS (Apple Silicon and Intel) and on Linux (x86-64 and
arm64). It takes the newest build of `main` into `./ex-tbp-monty-<platform>/`,
unpacks it there and opens it: nothing is installed, nothing is registered, and
deleting that folder is the whole of uninstalling it. Running it again opens what
is there; `--update` takes the newest build first. A tagged release keeps the
same file in the releases page, which is what to use for a version that has to
stay put. Prefer to take the file yourself? These links always give the latest
build:

| Platform    | Download                                                                                                       |
| ----------- | -------------------------------------------------------------------------------------------------------------- |
| macOS arm64 | [ex-tbp-monty-osx-arm64](https://nightly.link/d-led/ex.tbp.monty/workflows/ci/main/ex-tbp-monty-osx-arm64.zip) |
| Linux x64   | [ex-tbp-monty-linux-x64](https://nightly.link/d-led/ex.tbp.monty/workflows/ci/main/ex-tbp-monty-linux-x64.zip) |

The macOS app is unsigned, so its first launch is right-click → Open. The Linux
download holds a tarball of the window with its release beside it — and a `.deb`,
for whoever would rather their package manager tracked it. Where it keeps its
data, what is built for which platform, and why the download is about 300 MB
while the app is 550 MB on disk — most of it the Python interpreter the release
carries: [docs/desktop.md](docs/desktop.md). A checkout builds and opens it with
`scripts/start-desktop.sh`, or `scripts\start-desktop.ps1` on Windows.

## From source

```bash
scripts/init-dev.sh    # Postgres on 6432, dependencies, database, assets
scripts/run-dev.sh     # http://localhost:4000
```

A development run keeps its data in that Postgres; a release and the desktop app
keep theirs in a SQLite file unless `DATABASE_URL` names a server. `mix
ecto.migrate` creates the file on first run and `mix ecto.drop` deletes it —
[docs/developers.md](docs/developers.md#a-file-instead-of-a-server).

Needs Elixir 1.20, node/npm, Docker, and a Rust toolchain — and installs the
first and the last itself when the machine has neither:

```bash
scripts/install-elixir.sh    # Elixir 1.20.5 + OTP 29.1, per user, no root
scripts/install-rust.sh      # the Rust toolchain
```

Both take no arguments and do nothing where their toolchain is already there.
Rust is a _build_ requirement: the native kernels are NIFs (`native/kd_tree_nif`,
`native/matcher_nif`) that rustler compiles with the application. Running the
app needs none of it — the release carries the compiled shared objects.
[docs/developers.md](docs/developers.md) has the tests, the gates CI runs and how
a module is added.

## Also

- **MCP.** `/mcp` answers an assistant about Monty's theory, roadmap and code, and
  previews, saves and runs experiments. `http://localhost:4001/mcp` is already in
  [`.vscode/mcp.json`](.vscode/mcp.json) — start the server with `PORT=4001
scripts/run-dev.sh` (4000 is the default, and then the URL to copy is the one
  `/mcp/config` prints) — [docs/mcp.md](docs/mcp.md).
- **Headless.** `mix monty.run tutorial/first_experiment --steps 20` is the same
  run record without the browser; flags and `mix monty.bench` in
  [docs/features.md](docs/features.md).

## How it follows Monty

- **The same modules.** Python `path/file.py::Class` becomes
  `Monty.Path.File.Class` by one rule, with nothing renamed to suit Elixir —
  [`lib/monty/module_map/data.ex`](lib/monty/module_map/data.ex), checked by
  `mix monty.module_map.verify`.
- **The same configs.** Monty's Hydra YAML is read unchanged from
  [`priv/monty`](priv/monty), so no Monty checkout is needed; every experiment
  Monty snapshots composes to the same tree here —
  [docs/config-compatibility.md](docs/config-compatibility.md).
- **Processes, not a loop.** A step is a barrier over processes: sensor modules,
  learning modules and the motor system exchange CMP messages, and a vote is a
  round with a deadline — [docs/architecture.md](docs/architecture.md).
- **MuJoCo is the world a run steps.** Monty's own simulator, copied into
  `priv/monty_py` rather than ported, driven in the interpreter the release
  carries; the Elixir stand-in scene is the alternative. Habitat is not carried —
  a Habitat config is refused rather than given MuJoCo's scene and allowed to look
  as if it ran — [docs/simulator-port.md](docs/simulator-port.md).
- **Checked against Monty.** What was compared, with which numbers, is
  [docs/validation.md](docs/validation.md); what is ported is measured in
  [docs/features.md](docs/features.md).

## Where it differs

Monty steps one object graph in one loop; here every module is a process. What
follows from that is argued in [docs/monty-differences.md](docs/monty-differences.md) §2.

- **Voting is a message round.** With no deadline it is Monty's synchronous
  round; with one, the round closes when time is up and the step says how many
  votes it used and whether it ran short.
- **A module can fail on its own.** A dead one is replaced; a slow one is named
  in that step and the step goes on.
- **A stream per module, not one shared stream.** A seeded episode repeats
  Python's numbers where the drawing order is the same.
- **Values returned, not mutated.** Python's subclasses and self-mutating objects
  become functions and returned state.
- **A UI and an MCP server.** A page per experiment, runs kept in Postgres, and
  `/mcp`.

## Docs

| Doc                                                          | Answers                                                              |
| ------------------------------------------------------------ | -------------------------------------------------------------------- |
| [docs/features.md](docs/features.md)                         | what works, and what proves it                                       |
| [docs/architecture.md](docs/architecture.md)                 | what happens in one timestep?                                        |
| [docs/module-map.md](docs/module-map.md)                     | where is that Python file here?                                      |
| [docs/from-monty.md](docs/from-monty.md)                     | what comes from Monty, where it lands, and the task that writes it   |
| [docs/config-compatibility.md](docs/config-compatibility.md) | which Hydra features are implemented, and how far parity goes        |
| [docs/validation.md](docs/validation.md)                     | what has been compared with Monty, and how closely                   |
| [docs/monty-differences.md](docs/monty-differences.md)       | every deliberate difference, and what looks wrong upstream           |
| [docs/simulator-port.md](docs/simulator-port.md)             | where the world lives, and what is still Python                      |
| [docs/developers.md](docs/developers.md)                     | how do I work on this?                                               |
| [docs/container.md](docs/container.md)                       | how do I run the image? every variable, the volumes, what it reports |
| [docs/desktop.md](docs/desktop.md)                           | how do I open this as an app? the window, the folder it writes to    |
| [docs/mcp.md](docs/mcp.md)                                   | `POST /mcp` — ask this app about Monty's docs, roadmap and code      |
| [docs/roadmap.md](docs/roadmap.md)                           | the order the rest of Monty arrives in                               |

## Licence

MPL-2.0 — see [LICENSE](LICENSE). Monty itself is MIT-licensed, and this project
ships a verbatim copy of its config tree and of the snapshots our composer is
checked against: those files stay Monty's, with its licence beside them in
[priv/monty/LICENSE](priv/monty/LICENSE).

The rest of what is third-party here is a dependency rather than a copy, so the
build's own files are the list — each fetched package keeps its licence:

| What                       | Where it is declared                                                |
| -------------------------- | ------------------------------------------------------------------- |
| Elixir libraries           | [`mix.exs`](mix.exs), pinned in [`mix.lock`](mix.lock)              |
| browser packages           | [`assets/package.json`](assets/package.json)                        |
| Python, in our interpreter | the `pyproject_toml` in [`config/pythonx.exs`](config/pythonx.exs)  |
| the NIFs, the desktop app  | [`native/`](native), [`src-tauri/Cargo.toml`](src-tauri/Cargo.toml) |
| the image's base images    | [`Dockerfile`](Dockerfile)                                          |
