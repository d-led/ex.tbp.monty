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
`4000` by default). VS Code reads [`.vscode/mcp.json`](../.vscode/mcp.json); a
client that takes a URL
takes `http://localhost:4001/mcp`.

## Where the answers come from

The server does not keep a copy of anything it talks about.

| Question | Read from |
| --- | --- |
| What does the project say? | `docs/**` in the Monty checkout `MONTY_SOURCE` names (`../monty-orig` here) |
| What does it plan? | `docs/future-work/<section>/<task>.md`, whose front matter is the project's own future-work table |
| Where is that in code? | [`lib/monty/module_map/data.ex`](../lib/monty/module_map/data.ex), the same map `mix monty.module_map.verify` checks |
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

**The deployment** — `monty_studio`: how many experiments are preconfigured, how
many runs there are of each state, how many episodes run at once, which world a
run steps, and which data and model bundles are present. The answer to "can we
run experiments in parallel", and to every other question about *this* instance
rather than about a config — an assistant does not need a shell to ask it.

**Documentation** — `monty_search_docs`, `monty_read_doc`, `monty_docs_index`.

**Roadmap** — `monty_roadmap` (filter by section, status, skill, words),
`monty_roadmap_task`.

**The port** — `monty_lookup_module` (a Python class, a file, or an Elixir
module in, a verdict out), `monty_port_status`, `monty_code_in_doc` (resolve
every module a doc page refers to, which is the shortest path from a paragraph
of theory to source).

**Experiments** — `monty_list_experiments`, `monty_describe_experiment`,
`monty_experiment_options`, `monty_read_option`, `monty_preview_experiment`,
`monty_create_experiment`, `monty_export_experiment`, `monty_import_experiment`,
`monty_run_experiment`.

**Runs** — `monty_list_runs`, `monty_run_report`, `monty_delete_runs`.

Every tool has an `inputSchema` and honest annotations: the ones that only read
say `readOnlyHint`; the two that write — a draft, a queued run — say that too;
and `monty_delete_runs` says `destructiveHint`, because it is.

### Asking about this deployment

`monty_studio` takes no arguments and answers with numbers:

```
210 experiments preconfigured; 33 finished · 5 failed run(s)

Parallel: 2 episode(s) at a time (0 running now).
a run is a job on the :studio queue, and the queue's limit is how many run at
once. The run page's "in parallel" selector queues one run per episode and sets
the limit to the same number — one object per episode.
Monty does the same thing its own way: Monty's run_parallel.py, one process per
episode.

World: synthetic — runs step this port's synthetic scene, so their numbers are
not Monty's; MONTY_WORLD=monty with MONTY_PYTHON set runs Monty's own simulator
out of process.

Prerequisites: 2/2 present (pretrained_ycb_v13 present · pretrained_ycb_v13_zip present)
```

The limit is read from the running queue, not from the config: the run page
changes it while the queue drains, so the config value is where it started.
A process with no queue up (a Mix task, a test run) says so and reports the
configured limit, rather than claiming a number it cannot see.

### Asking "how many experiments?"

`monty_list_experiments` is a catalog answer, not a list: the total, the four
choices counted (`agent`, `modules`, `learning_module`, `model`), and a page of
the matching experiments. The counts respect the other filters, so one call
answers "how many surface-agent experiments start from a pretrained model":

```json
{"name": "monty_list_experiments", "arguments": {"agent": "surf", "model": "pretrained"}}
```

```
9 of 210 experiments match.

Choices, each counted with the other filters applied:
Agent: dist 98 · other 94 · surf 18
Learning modules: 1 18
...
```

`monty_describe_experiment` answers the next question — sensors and their count,
learning modules, the objects the config names (or the sampler that places
them), the connections, the epochs, the seed, `num_parallel`, and which classes
are ported — in one response, so an assistant needs no filesystem of its own.

### Taking one of Monty's experiments and changing it

An experiment is a file, and the round trip through a file is the shortest path
from "Monty ships one that is nearly right" to "a run of my own":

```jsonc
// 1. the file Monty ships — the short defaults list, not the composed tree
{"name": "monty_export_experiment", "arguments": {"name": "base_10simobj_surf_agent"}}

// 2. change it (the answer also serves it at /export/experiments/<name>)

// 3. keep it under a new name; it is composed before it is written
{"name": "monty_import_experiment", "arguments": {
  "name": "my_four_objects", "yaml": "<the edited file>"
}}

// 4. run it, and watch it
{"name": "monty_run_experiment", "arguments": {"name": "my_four_objects", "steps": 20}}
{"name": "monty_run_report", "arguments": {"run_id": "<from the previous answer>"}}
```

`monty_import_experiment` refuses a name that is not one file name (a file is
named after the draft), refuses a file that does not compose, and refuses to
replace an existing draft unless `overwrite` is true. A file that composes but
would not run is saved and its findings are reported — that is the answer to
"what is wrong with it".

The same two ends exist in the browser: every experiment page has a `yaml`
download (`/export/experiments/<name>`), and the build page imports a file as a
new draft.

### Runs, and deleting them

`monty_list_runs` takes `state` (`running`, `finished`, `stopped`, `failed`),
`query` (words of the experiment's name), `page` and `limit`, and answers the
counts by state plus each run with a link. `monty_run_report` is one run in
detail; `monty_run_experiment` returns the link of the run it queued.

`monty_delete_runs` deletes nothing unless `confirm` is true: the first call
answers exactly what would go, by id and experiment. It takes `run_ids`, or a
`state`/`query` filter (at most 50 runs a call — a filter nobody narrowed is not
a decision), and it never deletes a run that is still running: that run is the
only thing that can record what it did.

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
| `:experiments_dir` | [`priv/experiments`](../priv/experiments) | where drafts are written |

## What it is not

There is no authentication. The tools read the checkout this application was
built from and write only where the studio itself writes; that is a statement
about a development server on a developer's machine, and the endpoint is meant
to be used as one.

`Origin`, when a client sends one, must name this host — the DNS-rebinding
defence the specification asks for — and `MCP-Protocol-Version`, when a client
sends one, must be a revision the server speaks. `GET` and `DELETE` answer 405:
there is no stream to subscribe to and no session to terminate.
