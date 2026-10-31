# Monty on the BEAM

A rewrite of the [Thousand Brains Project's Monty](https://github.com/thousandbrainsproject/tbp.monty)
in Elixir.

Monty implements the Thousand Brains Theory of Intelligence: a sensor module
moves over an object and senses it, learning modules keep models of objects and
use those senses to recognise the object and to say where the sensor is on it.
Monty is written in Python; this is the same system on the Erlang VM, where
every sensor module, learning module and the motor system is a process, and
every experiment Monty ships has a page in a browser UI.

The port follows Monty module for module, so the two can be read side by side,
and it is checked against Monty rather than against a description of it. Where
it deliberately differs, it says so.

It speaks the Model Context Protocol as well, so an assistant can ask it about
Monty — its theory, its roadmap, its code — and define and run an experiment
without leaving the conversation.

## Quickstart

```bash
scripts/quickstart.sh
```

That pulls the published image, starts a Postgres and the application in
containers of their own, and opens

```
http://localhost:4001
```

Docker is all it needs. `scripts/quickstart.sh --stop` stops it and keeps the
database and the app's files; `--purge` deletes them as well.

The page you land on lists every experiment Monty ships. Open one, press run,
and the run streams as it steps: the step log, the evidence each learning module
built, and the votes. A finished run stays in the history, where it can be
replayed step by step — what the sensor saw, the hypotheses counted, and why it
stopped.

Nothing large is in the image. Data and pretrained models are downloaded at
`/prerequisites`, into the same paths Monty uses, and a run says what it is
missing.

## An MCP server

The studio also speaks the Model Context Protocol at `/mcp`, so an assistant can
ask it about Monty's theory, its roadmap and its code, and about this port — and
preview, save and run an experiment from the conversation. Each request is one
JSON-RPC message in and one answer out, and the answers are read from the
sources: Monty's `docs/` in a checkout, the module map, `Monty.Studio` and the
run table.

`http://localhost:4001/mcp` is the quickstart's port, and VS Code is already
pointed at it in `.vscode/mcp.json`. [docs/mcp.md](docs/mcp.md) lists the tools
and a first request.

## From source

Needs Elixir 1.20 with the OTP it runs on, node/npm for the assets, and Docker
for Postgres:

```bash
scripts/init-dev.sh    # Postgres in Docker, dependencies, database, assets
scripts/run-dev.sh     # http://localhost:4000
```

[docs/developers.md](docs/developers.md) has the rest: invariants, tests, the
gates CI runs, and how a module is added.

## How it follows Monty

* **The same modules.** Python `path/file.py::Class` becomes
  `Monty.Path.File.Class` by one rule, with no module renamed to suit Elixir.
  `lib/monty/module_map/data.ex` is that mapping, and
  `mix monty.module_map.verify` fails when a Monty file has no entry, or an
  entry claiming to be ported has no module —
  [docs/module-map.md](docs/module-map.md).
* **The same configs.** Monty's Hydra YAML is read unchanged, and the tree ships
  in `priv/monty`, so no Monty checkout is needed. Every experiment Monty
  commits a snapshot for composes to the same tree here —
  [docs/config-compatibility.md](docs/config-compatibility.md).
* **Processes, not a loop.** A step is a barrier over processes: sensor modules,
  learning modules and the motor system exchange CMP messages, and a vote is a
  round with a deadline — [docs/architecture.md](docs/architecture.md).
* **Checked against Monty, not asserted.** What has been compared, and with
  which numbers, is [docs/validation.md](docs/validation.md); every deliberate
  difference is [docs/monty-bugs.md](docs/monty-bugs.md); what is ported today,
  and the evidence for each, is measured in [docs/features.md](docs/features.md).

## Headless

The studio is one way to run an experiment; the command line is the other, with
the same record of what happened:

```bash
mix monty.run tutorial/first_experiment --steps 20
```

[docs/features.md](docs/features.md) has the flags and `mix monty.bench`.

## Documentation

| Doc | Answers |
| --- | --- |
| [docs/features.md](docs/features.md) | what works, and what proves it |
| [docs/architecture.md](docs/architecture.md) | what happens in one timestep? |
| [docs/module-map.md](docs/module-map.md) | where is that Python file here? |
| [docs/config-compatibility.md](docs/config-compatibility.md) | which Hydra features are implemented, and how far parity goes |
| [docs/validation.md](docs/validation.md) | what has been compared with Monty, and how closely |
| [docs/monty-bugs.md](docs/monty-bugs.md) | every deliberate difference, and what looks wrong upstream |
| [docs/simulator-port.md](docs/simulator-port.md) | where the world lives, and what is still Python |
| [docs/developers.md](docs/developers.md) | how do I work on this? |
| [docs/container.md](docs/container.md) | how do I run the image? every variable, the volume, what it reports |
| [docs/mcp.md](docs/mcp.md) | `POST /mcp` — ask this app about Monty's docs, roadmap and code |
| [docs/roadmap.md](docs/roadmap.md) | the order the rest of Monty arrives in |

## Licence

MPL-2.0 — see [LICENSE](LICENSE). Monty itself is MIT-licensed, and this project
ships a verbatim copy of its config tree and of the snapshots our composer is
checked against: those files stay Monty's, with its licence beside them in
[priv/monty/LICENSE](priv/monty/LICENSE). Everything else the repository and the
image carry that this project did not write is listed in
[THIRD-PARTY.md](THIRD-PARTY.md).
