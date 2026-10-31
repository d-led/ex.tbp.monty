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
curl -fsSLO https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/docker-compose.yml
docker compose up
```

→ <http://localhost:4001>

The image is `ghcr.io/d-led/ex.tbp.monty:latest` (amd64 and arm64); the compose
file adds the Postgres it needs and runs the migration. The database and
`/prerequisites` downloads are named volumes, so `docker compose down` keeps
them and `docker compose down -v` deletes them.

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

## From source

```bash
scripts/init-dev.sh    # Postgres on 6432, dependencies, database, assets
scripts/run-dev.sh     # http://localhost:4000
```

Needs Elixir 1.20 with its OTP, node/npm and Docker.
[docs/developers.md](docs/developers.md) has the tests, the gates CI runs and how
a module is added.

## Also

- **MCP.** `/mcp` answers an assistant about Monty's theory, roadmap and code, and
  previews, saves and runs experiments. `http://localhost:4001/mcp` is already in
  [`.vscode/mcp.json`](.vscode/mcp.json) — [docs/mcp.md](docs/mcp.md).
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
- **The experiment's own engine, unless the run chooses otherwise.** A run steps
  MuJoCo or Habitat-Sim through Monty's Python, in an external process that
  imports Monty; the Elixir stand-in scene is the alternative —
  [docs/simulator-port.md](docs/simulator-port.md).
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
| [docs/mcp.md](docs/mcp.md)                                   | `POST /mcp` — ask this app about Monty's docs, roadmap and code      |
| [docs/roadmap.md](docs/roadmap.md)                           | the order the rest of Monty arrives in                               |

## Licence

MPL-2.0 — see [LICENSE](LICENSE). Monty itself is MIT-licensed, and this project
ships a verbatim copy of its config tree and of the snapshots our composer is
checked against: those files stay Monty's, with its licence beside them in
[priv/monty/LICENSE](priv/monty/LICENSE). Everything else the repository and the
image carry that this project did not write is listed in
[THIRD-PARTY.md](THIRD-PARTY.md).
