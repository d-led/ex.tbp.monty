# The MCP server

`POST /mcp` speaks the Model Context Protocol over the Streamable HTTP
transport, so an assistant can ask about the Thousand Brains Project's theory,
its roadmap and its code, and about this port: what an experiment is configured
to be, and how to define and run one.

It is one endpoint, one JSON-RPC message in, one answer out. No sessions, no
server-sent events, no batches — every request is self-contained, which is what
lets a client treat it as a plain HTTP URL.

```bash
curl -s localhost:4001/mcp -H 'content-type: application/json' -d '{
  "jsonrpc": "2.0", "id": 1, "method": "initialize",
  "params": {"protocolVersion": "2025-06-18"}
}'
```

Point a client at the port your server prints (`4001` in this workspace,
`4000` by default). VS Code reads `.vscode/mcp.json`; a client that takes a URL
takes `http://localhost:4001/mcp`.

## Where the answers come from

The server does not keep a copy of anything it talks about.

| Question | Read from |
| --- | --- |
| What does the project say? | `docs/**` in the Monty checkout `MONTY_SOURCE` names (`../monty-orig` here) |
| What does it plan? | `docs/future-work/<section>/<task>.md`, whose front matter is the project's own future-work table |
| Where is that in code? | `priv/monty/module_map.exs`, the same map `mix monty.module_map.verify` checks |
| What is this experiment? | `Monty.Studio.open/2` — Monty's `conf/` tree, composed and read back |
| Did the run work? | `studio_runs`, written by `Monty.Studio.Jobs.Run` as the run goes |

Documentation answers carry the page's `path` and a link to its published
address (`https://docs.thousandbrains.org/docs/<page>`), so a claim can be
checked instead of believed. The published address is derived from the file
name, which is how Monty's site addresses a page; a page the site has not
published yet reads as a link that does not exist.

Port status answers are the module map's verdict, not an opinion: `implemented`
means the Elixir module exists, `planned` means it does not, `excluded` says
why. A class the generated map does not list is reported `unknown` rather than
guessed at.

## The tools

**Documentation** — `monty_search_docs`, `monty_read_doc`, `monty_docs_index`.

**Roadmap** — `monty_roadmap` (filter by section, status, skill, words),
`monty_roadmap_task`.

**The port** — `monty_lookup_module` (a Python class, a file, or an Elixir
module in, a verdict out), `monty_port_status`, `monty_code_in_doc` (resolve
every module a doc page refers to, which is the shortest path from a paragraph
of theory to source).

**Experiments** — `monty_list_experiments`, `monty_describe_experiment`,
`monty_experiment_options`, `monty_read_option`, `monty_preview_experiment`,
`monty_create_experiment`, `monty_run_experiment`, `monty_run_report`,
`monty_list_runs`.

Every tool has an `inputSchema` and honest annotations: the ones that only read
say `readOnlyHint`, and the two that write — a draft, a queued run — say that
too.

## Defining and running an experiment

The three calls are deliberately separate, because the interesting failure is a
config that does not compose and the cheapest place to find it is before
anything is written:

```jsonc
// 1. what would this be?  (nothing is saved)
{"name": "monty_preview_experiment", "arguments": {"attributes": {
  "name": "four_objects_evidence",
  "base": "base_config_10distinctobj_dist_agent",
  "monty/learning_module": "displacement_1lm",
  "n_eval_epochs": 1
}}}

// 2. save it as a draft the studio can open
{"name": "monty_create_experiment", "arguments": {"attributes": { ... }}}

// 3. queue a run; the answer carries the link
{"name": "monty_run_experiment", "arguments": {"name": "four_objects_evidence", "steps": 12}}
```

`attributes` is a blueprint: `name`, `base` (an experiment to start from), any
group of `monty_experiment_options` as a key (`monty/learning_module`,
`monty/sensor_module`, `environment`, …), and the config values `seed`,
`n_train_epochs`, `n_eval_epochs`, `supervised_lm_ids`, `model_name_or_path`.

A run is queued, not awaited. It is the studio's Oban job, exactly as the page's
Run button: it steps in the queue, it outlives the request, and the answer is a
link to `/runs/<id>` — the page that shows the sensors, the log and the summary
as they arrive. `monty_run_report` reads the same record back for a client that
would rather not open a page.

A setup Monty would refuse — a vote matrix of the wrong shape, a sensor nothing
listens to — is refused here too, before anything is queued, because a run that
fails immediately looks like a run that worked.

## Configuration

| Setting | Default | What it is |
| --- | --- | --- |
| `:monty_source` / `MONTY_SOURCE` | `../monty-orig` | the checkout the docs and configs are read from |
| `:monty_docs_dir` | `<monty_source>/docs` | the documentation corpus |
| `:monty_docs_url` | `https://docs.thousandbrains.org/docs/` | where pages are published |
| `:experiments_dir` | `priv/experiments` | where drafts are written |

## What it is not

There is no authentication. The tools read the checkout this application was
built from and write only where the studio itself writes; that is a statement
about a development server on a developer's machine, and the endpoint is meant
to be used as one.

`Origin`, when a client sends one, must name this host — the DNS-rebinding
defence the specification asks for — and `MCP-Protocol-Version`, when a client
sends one, must be a revision the server speaks. `GET` and `DELETE` answer 405:
there is no stream to subscribe to and no session to terminate.
