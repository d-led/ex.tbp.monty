# Several nodes

One studio is one node. This page is about running more than one, on one machine
or on several, and about the two things that make a cluster of this application
different from a cluster of a stateless web app: **what each node keeps to itself**
and **what each node can do**.

Clustering is off unless it is asked for. A `mix phx.server` with no variables
set, a release with no node name and the desktop window all start exactly the
tree they started before clustering existed: no libcluster, no `Horde`, no
poller, no second folder. Everything below is an addition reached by environment,
and `ExTbpMonty.Cluster.children/0` is the single place that decides it.

## One machine

```console
$ process-compose up
$ open http://localhost:4001   # node1
$ open http://localhost:4002   # node2
```

`process-compose.yaml` runs two nodes with `elixir --name … -S mix phx.server` and
nothing else — no shell script, because the same file is read on Windows. The
recipe is three decisions, all of them environment:

| what                   | how                                                                          |
| ---------------------- | ---------------------------------------------------------------------------- |
| the node's name        | `--name node1@127.0.0.1` — the only thing that makes it a node               |
| the cluster            | `MONTY_CLUSTER=true` (or `MONTY_SEEDS`), see [The variables](#the-variables) |
| its own database       | `MONTY_DB=sqlite` — a file per node under `nodes/<its name>/`                |
| the cluster's password | `MONTY_CLUSTER_SECRET`, the same on every node that should join              |

A named node prepares its own folder: on boot it makes
`nodes/<its name>/` and migrates the database in it
(`ExTbpMonty.Application.prepare_data_folder/0`), which is what a release's
`bin/server` does before it serves. A node that runs alone has no such folder and
is not touched.

## What a node keeps, and what they share

The folder is `Monty.Paths.root/0` — the operating system's per-user application
directory, `~/Library/Application Support/ex-tbp-monty` on macOS. Under it, a
named node in a cluster works in `<root>/nodes/<its name>/`, where the name is
its node name with everything a path cannot hold replaced
(`node1@127.0.0.1` → `node1_127.0.0.1`).

| kept by the node                                                   | shared                                                  |
| ------------------------------------------------------------------ | ------------------------------------------------------- |
| `nodes/<name>/ex_tbp_monty.db` — its runs                          | `data/` — Monty's object data (`MONTY_DATA`)            |
| `nodes/<name>/runs/` — a run's log, transcript and pictures        | `models/` — pretrained archives (`MONTY_MODELS`)        |
| `nodes/<name>/projects/` — what Monty itself writes (`MONTY_LOGS`) | `data/libraries/` — memory exported from those archives |

Two nodes must not open one SQLite file, and a run belongs to the node that
started it; what they do share is what was _downloaded_, because fetching a
gigabyte twice is the only thing worse than fetching it once.

Which of the two folders a node is in is decided once, in `config/runtime.exs`,
from the same value that turns clustering on: a node that was asked to cluster
_and_ has a name gets its own folder; anything else keeps the single folder it
always had. `Monty.Paths.node_root/0` is the only thing that knows the rule.

## The variables

| variable                   | what it decides                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MONTY_CLUSTER`            | `1`/`true` asks for the cluster's children. Not needed when `MONTY_SEEDS` is set — a list of nodes to dial is already the request                                                                                                                                                                                                                                                                                                                                                |
| `MONTY_SEEDS`              | the peers to dial, `node1@10.0.0.7,node2@10.0.0.8`. Empty means gossip discovery, which is what several nodes on one machine need, because they cannot know each other's names in advance                                                                                                                                                                                                                                                                                        |
| `MONTY_CLUSTER_SECRET`     | the cluster's shared secret, the same on every node that should join. `config/runtime.exs` sets it as the VM's cookie before any cluster child connects, which is how nodes on different machines — with different `~/.erlang.cookie` files — join one cluster. `MONTY_COOKIE` is the same thing under the name the first launcher gave it, still read. A release reads `RELEASE_COOKIE`, which `rel/env.sh.eex` fills from `NODE_COOKIE`                                        |
| `PORT`                     | that node's HTTP port                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `MONTY_CAPABILITIES`       | what this node can do, comma-separated (see [capability tags](#capability-tags))                                                                                                                                                                                                                                                                                                                                                                                                 |
| `MONTY_DB`                 | `sqlite` gives a development node a file instead of the Postgres a developer's machine has. A release asks `DATABASE_URL` instead                                                                                                                                                                                                                                                                                                                                                |
| `NODE_NAME`                | a release's node name, the alias of `RELEASE_NODE`; in development the name is the VM's (`--name`/`--sname`)                                                                                                                                                                                                                                                                                                                                                                     |
| `MONTY_STUDIO_CONCURRENCY` | how many runs one node performs at once — Oban's `queues: [studio: n]`, two when it is not set. A laptop sharing its cores with two MuJoCo worlds is slower per run than one world at a time, and a node with a GPU is not, so it is the deployment's number. In a cluster the queue is one queue: two nodes at two each is four runs at once, and a node told to take one leaves the other for its peer. Anything that is not a whole number of at least one is refused at boot |
| `MONTY_ARTIFACTS_DIR`      | where a run's files go (`Monty.Studio.Artifacts`: the log, the pictures, the statistics, the memory it learned). Default: this node's own folder. Point every node at one directory before asking a run's parts to work on more than one node                                                                                                                                                                                                                                    |

**The secret is the cluster's password.** Two nodes that disagree about it are two
clusters that quietly believe they are one: nothing fails, nothing is logged, and
each page shows one node. That is the failure this design's blueprint records, so
the settings page says where a node's secret came from — and never what it is,
because a settings screen is not a place to print a password. A node given none
falls back to its user's `~/.erlang.cookie`, which is right for several nodes on
one machine and wrong for several machines.

## What the pages say

The footer of every page carries the count — `2 nodes` — and links to
Settings → Nodes, which names them, their build, and what each can do. Both
follow the cluster: a peer joining or leaving moves the count and the list
without anybody reloading. `ExTbpMonty.Cluster.Nodes` polls every three seconds
(asking a peer for its build is an `:rpc`, and a peer that has just died answers
nothing for a while, so no page ever waits behind one) and announces the list on
`"cluster:nodes"` when it changes — only when it changes, because a page that
re-renders every three seconds for nothing is a page that never stops working.

A peer's name is a link, because a node name is not a URL and "the run is on
node2" is not something a reader can click. The address comes from the node
itself: its host is the host part of its own name — the address its peers dialled
— and its port is the one its endpoint was configured with
(`ExTbpMonty.Node.web_url/1`). A node with no name to build one from is a name
and not a link, which is the honest thing to show.

A page shows **this node's runs**. The topic runs are announced on is the
cluster's — Phoenix's pubsub is the distributed one — so a page does hear about a
run recorded on a peer, and it drops it: a row it can act on is a row it has. The
run's files, its worker and its page are on that node, so a row here would offer
Stop and Delete beside a link this node cannot answer. One runs table for the
whole cluster would make those messages news, and nothing in this page would have
to change.

What a reader can see of the rest of the cluster is `/runs` → **Running on other
nodes**: each node answers with up to five of its unsettled runs (no transcript,
no pictures), and every row is a link to the peer's own page for it. It is asked
rather than subscribed — once when the page loads and then every five seconds, so
a peer's running run moves instead of standing still at the count the page found —
and it is read-only, because everything a reader could do to that run has to happen
where the run is. A node that runs alone draws no such panel.

A node with no name at all cannot join anything, and the settings page says so
with the variable and the `mix` line that would fix it.

## Capability tags

A cluster of identical nodes needs no vocabulary: every node can do everything,
and "which node" is only "which one is free". A heterogeneous cluster is the case
the tags exist for. One machine steps MuJoCo; another has the GPU; a third brings
modules this checkout does not have.

A tag is a short lowercase string, no spaces, and a colon groups a family:

```
monty                    every node: it runs this application's modules
gpu                      the machine has one
world:mujoco             this node can step MuJoCo
plugin:learning_module   this node brings plugins of that kind
```

`monty` is always advertised. `MONTY_CAPABILITIES` adds the machine's own, and a
node that brings plugins declares theirs in the same list. Tags are strings and
not atoms on purpose: they arrive from an environment variable and from other
people's VMs, and `String.to_atom/1` on either is a table that only grows.

The tags travel with the version in the one `:rpc` the poller already makes
(`ExTbpMonty.Cluster.Nodes.identity/0`), so an entry carries both, and a peer
running a build older than the vocabulary has none — the honest reading of that
answer is that it can be given only work that asks for nothing in particular.

`ExTbpMonty.Cluster.Capabilities` is the vocabulary: `declared/0` (this node's),
`offers?/2` (asked in any spelling), `by_tag/1` (tag → nodes) and `of_entry/1`.
`ExTbpMonty.Cluster.Nodes.offering/1` is the other direction: the nodes that
offer a tag, `[]` when none does.

Settings → Nodes shows it both ways round — a node's row carries its tags, and
"What this cluster can do" puts each tag above the nodes that have it. The second
direction is where a heterogeneous cluster's differences become visible: a tag
with one node under it is a decision somebody has to make.

## Where a run goes

Tags are not decoration: `ExTbpMonty.Cluster.Placement` decides from them whether
the node holding a job may perform it.

A run needs `monty`, plus the world it steps when that world is not the port's
own scene — a run recorded as MuJoCo needs `world:mujoco`, because a node
without MuJoCo cannot step it. A run may also add tags of its own in
`inputs.capabilities`, which is how it is pinned to a machine that has what it
takes:

```elixir
Monty.Studio.RunHistory.start(%{
  # ...
  inputs: %{"capabilities" => ["gpu"]}
})
```

Every run asked for from the studio's own page asks for nothing beyond `monty`
and its world, because a person who has not heard of tags should not need an
opinion about them.

The worker asks three questions, in order, before it opens a world:

1. **Does this node offer what the run needs?** Perform it here. A node that
   offers a tag keeps the work, however many peers also offer it: "which node" is
   then answered by whichever queue got there first, which is what it always was.
2. **Does a live peer?** Put the job back (`{:snooze, 15}`) and let that peer's
   queue take it. Nothing is opened and nothing is written: the run is still
   `queued`, because it is.
3. **Does nobody?** Perform it here anyway. A tag nobody declared must not hold a
   run hostage — a cluster whose nodes are all untagged is one untagged machine,
   and a node that runs alone cannot tell this answer from doing the work itself.

The third answer is why the single-node studio is untouched: its list of nodes is
itself, it offers `monty`, and every decision is the first question.

A peer that did not answer its poll is not a place a run can go, whatever it last
said about itself. And a job that waits does not wait forever on a node that has
gone: the next answer is question three, and the run is performed locally.

### A node that dies with a run

With one runs table for the cluster, a node that dies mid-run leaves its job
saying `executing`, and no other node will ever take it. `Oban.Lifeline` is asked
for exactly when clustering is on (`config/runtime.exs`), and what it does to such
a job is **discard** it, not re-run it: the worker allows one attempt
(`Jobs.Run`), and a second attempt would start the experiment from its first step
on another node beside a record that already has steps in it. The record itself is
settled by the reaper (`Monty.Studio.Jobs.Reaper`), which runs when a node starts
and when `/runs` or an experiment page loads — **on the node the row names**. That
node closing its own run is the whole rule: a peer's row is a peer's, however
quiet it looks.

The rule was wider for a day, and the trial that widened it is why it was narrowed
again. It said a row from a node _no longer in the cluster_ was anybody's to
close, and liveness in this cluster is a 500 ms `:rpc` to each peer's poller
(`ExTbpMonty.Cluster.Nodes`). Two runs saturating one machine made that probe time
out, node1 concluded node2 had gone, and abandoned node2's **live** runs twice —
at 95 steps and at 50. Nothing else was wrong: both jobs had executed at the same
time on different nodes, which is the point of the exercise. A run is not worth a
heuristic, so the only rows this node closes are the ones it recorded or claimed. A
node that really died leaves rows saying `running` until it comes back — which is
true, and is not improved by a guess.

Closing another node's run is still possible, but as a **statement** rather than an
inference: Stop on a shared row is asked of the node that has the run (see
"Stopping a run that another node has").

Its window is a **day**, and that is not caution for its own sake: Lifeline is
purely time-based — it cannot ask whether the node is alive — so any window
shorter than a run catches runs that are going perfectly well. Such a job would be
marked `discarded` while still stepping, and this page decides "is it in flight"
from the job, so a live run longer than the window would lose its Stop button. A
run of ours is minutes to hours; a day is past all of them. On a node that runs
alone nothing is configured that was not configured before.

## Where a run was asked for, and where it runs

With one runs table for a cluster those are two different nodes, so the list has
two columns, drawn only when clustering is on:

| column       | who writes it                                    | what it answers                                    |
| ------------ | ------------------------------------------------ | -------------------------------------------------- |
| `started on` | `RunHistory.start/1` (`studio_runs.started_on`)  | the node the run was asked for on. It never moves. |
| `running on` | `RunHistory.mark_running/1` (`studio_runs.node`) | the node performing it: the worker's own claim.    |

A claim that moved the run is drawn underlined with a dotted rule, and its title
says so, because "asked for here, running there" is the cluster working rather than
a detail to be inferred. A row written before `started_on` existed has no value
there and is shown as started where it runs — the honest answer about a row from a
build that could not have had a second node.

Both columns are written in the spelling that decided the node's folder
(`node2_127.0.0.1`), and a page translates each to the name peers dial
(`node2@127.0.0.1`) from the cluster's own list, which is the spelling
`MONTY_SEEDS` takes.

> "Split runs" in the sense of _parts of one run on several nodes_ do not exist yet
> — see "What is not spread yet". What the two columns do is make the split that
> **does** exist, the split between asking and performing, visible and
> attributable: a row can no longer be read as though it ran where it was asked
> for.

## Stopping a run that another node has

`Monty.Studio.Jobs.cancel/1` and `halt/1` reach the worker through
`ExTbpMonty.Cluster.Owner`, which reads the row's `node` and asks **that** node over
`:rpc` — `Run.stop/1` and `Run.halt/1` run where the process is, and `halt/1` stops
the model on the node that supervises it. Three answers come out:

- **on a node that runs alone, and on this node's own runs, nothing changed**: same
  calls, locally, in the same order, and the same `{:ok, :stopping}` /
  `{:ok, :settled}` back;
- **a node that does not answer** holds nothing this node can reach, which is the
  same answer as a run nobody holds — `{:error, :not_found}` — so the row is
  cancelled and settled as `cancelled`, and the list says what a person asked for.
  Cancelling is therefore the one cross-node action that does not depend on the peer
  being alive, and it is deliberately the only one;
- **the reaper is not on this path**. A person asked; that is the difference.

## What is not spread yet

A run of several parts is still performed whole on one node — the parts are
placed with it, never across the cluster.

That is not an oversight, it is where the two hard problems are:

- **The run's job lives in that node's database.** With a file per node, a second
  node neither sees the job nor can take it. Spreading the _queue_ needs one runs
  table for the whole cluster (`DATABASE_URL` pointing every node at one Postgres,
  which `ExTbpMonty.Database` already supports, in development too) or a merged
  view over the nodes' own tables. The row already says whose run it is —
  `studio_runs.node`, the node's folder name — so a merged view has the column it
  needs; the runs list shows it only on a node that was asked to cluster, because
  with one node it is a column saying "this one" on every row.

  With one table it works today, and this is what a trial showed: two nodes on one
  scratch Postgres, only the second declaring `world:mujoco`, and a MuJoCo run
  asked for through the first node's MCP endpoint. The first node's answer was
  `{:wait, 15}`, the job was taken by the second (`attempted_by
node2@127.0.0.1`, and still on its first attempt — a snooze is not a failed
  try), and the record ended `finished` with `node = node2_127.0.0.1`. Asked the
  same thing with the tagged node stopped, the first node performed the run
  itself: the run was not held hostage by a tag nothing alive offered.

- **A part writes files and publishes its steps into memory.** A part's log and
  pictures go to `Artifacts.dir/1` and its steps to `Monty.Studio.RunStream`, on
  the node performing it; the run that owns the parts reads both, from its own
  node. Running a part elsewhere therefore needs either a filesystem the owning
  node can read or an explicit transfer of what the part produced.

  The first is now a lever rather than a build: `MONTY_ARTIFACTS_DIR` points a
  node's run files at any directory, so several nodes can be given one, and the
  settings page says which of the two states a node is in — the directory, and
  whether that directory came from the variable or is this node's own. It does not
  say "shared": nothing here can tell a mount from a mistake, so it says what it
  knows. Live steps are still memory of the performing node, though the events
  themselves already cross the cluster — PubSub here is the cluster-wide adapter,
  so a page on the owner sees a peer part's steps as they happen and only the
  catch-up read (a page opened later) would need an `:rpc`.

  What a node now _does_ say is where it writes — `Nodes.identity/0` carries the
  directory, so a peer's entry has one beside its build and its tags, and
  `Nodes.shares_run_files?/2` answers whether two nodes name the same one. Files do
  not travel: a part's log, pictures and statistics are written by whoever
  performed it and read by the node that owns the run, so that question is what
  decides whether a part may be handed to a peer at all. A node that did not say —
  an older build — shares nothing, because "probably the same path" is not a fact
  to hand a run's output to.

- **A run's division is recorded, its parts' nodes included.** `studio_run_parts`
  keeps one row per part: how many the experiment was divided into, what state
  each is in, and the node that has it — written when the worker divides the run
  and updated as each part starts and ends. The run page's header counts them (`3
of 4 parts done`) and names each part's node in the count's title. Today every
  row says this node, because a part is a task inside one job; the rows are there
  so that the day it is not, the page and the record already say so. They cost no
  message: a page reads a table.

  A part is in one of six states — `queued`, `running`, `finished`, `failed`,
  `stopped`, `skipped` — and every way a run ends closes all of them: the worker
  settles the rows itself when it is done (`queued` becomes `skipped` for a part
  no wave reached, `running` becomes `failed` for one that never came back), and
  the Reaper settles them when the job died with its node. A part the stop
  reached is `stopped`, with the steps it managed, which is the run's own word for
  the same moment. `Monty.Studio.RunHistory.Part.ended?/1` is the one answer to
  "how many parts are there nothing more to happen to", so the page's count and an
  assistant's report cannot disagree about it.

- **Stopping a divided run reaches every part.** A part steps in a process of its
  own, so `Jobs.Run.stop/1` sends `:stop` to the job _and_ to each part's
  stream — the streams read from the record, because a stop may come from a page,
  an MCP tool, or a peer's `:rpc` call. A wave that starts with a stop already
  waiting does not start at all, and a part that ends `stopped` ends its wave and
  the run with it, so the evaluation wave never runs after a stop.

### What one database gives you today, measured

Two development nodes told about **one** Postgres
(`DATABASE_URL=… MONTY_CLUSTER=1 elixir --name nodeN@127.0.0.1 -S mix phx.server`),
a run recorded on node1:

- **the queue spreads.** The job was inserted by node1 and taken by **node2**
  (`Jobs.Run.held?/1` answered `true` on node2, `false` on node1), and the steps
  went to 87 while both nodes read the same row;
- **the list is one list.** Both nodes' `/runs` show the run, with the `node`
  column saying which node has it — the node that **claimed** it, not the one that
  asked (`RunHistory.mark_running/1` writes it), because the steps, the worker and
  in a release the files are there;
- **placement by tag is what picks the node.** With only node2 declaring
  `world:mujoco`, a MuJoCo run asked for through node1's MCP endpoint was answered
  `{:wait, 15}` by node1, taken by node2 (`attempted_by node2@127.0.0.1`, still on
  its first attempt) and finished with `node = node2_127.0.0.1`. With node2
  stopped, node1 performed the same run itself — a run is not held hostage by a
  tag nothing alive offers;
- **the peer panel stays honest**: a node answers a peer with the runs **it has**
  (`Cluster.Peers.local_recent/0`, filtered to rows whose `node` is its own), so a
  shared table does not make every node report the others' runs as "somebody
  else's";
- **what is still one node's**: the live steps, which live in the memory of the
  node performing the run (the row is the record, written at every episode
  boundary, so a page elsewhere is that much behind), and — in a **release** —
  the run's files, which are written under the performing node's folder
  (`:studio_artifacts_dir`; a development node writes them into the checkout, so
  two dev nodes share them by accident).
- **a run that waits says so.** A queued run whose needs this node does not offer
  owes a reader a sentence, because the queue calls "waiting for the node that has
  the tag" and "nobody has picked it up" the same word: `available`. The run's page
  draws `waits for <node>` beside its state (`ExTbpMonty.Cluster.Placement.awaiting/2`
  answers it, the title says which tag this node lacks). On a node that runs alone
  there is nothing to say and nothing is drawn.

What has changed since this section was first written: tags no longer only
describe a cluster, they place work in it (`ExTbpMonty.Cluster.Placement`, above),
and with one runs table that placement has somewhere to take effect — a run is
performed by a node that offers what it needs, wherever it was asked for. What is
still one node's is a run's **parts**: those are what the next change is about,
and they need one of the two answers this section lists — a filesystem the owning
node can read, or an explicit transfer of what a part produced.

## Why the node migrates itself

An Ecto mix task reads configuration _before_ `config/runtime.exs`, which is where
a node's database is chosen — `mix ecto.create` would try the Postgres this
checkout was written around and find no database named in its config. A node's own
start does read that file, so the migration belongs to the node: boot makes the
folder and runs `ExTbpMonty.Release.migrate/0` — the migration a release applies —
before the tree that reads the schema starts. That is also why this is a decision
of the node and not of a launcher: the same code path serves `mix phx.server` on
Windows, where a launcher script would not exist.

## Two runs, two nodes, at the same time

The trial below asked whether the cluster performs work in parallel, not merely
whether it places it. Two nodes, one scratch Postgres, MuJoCo parallelism pinned to
one per node (so that a node cannot answer the question by itself), one run queued
through each node's MCP endpoint:

- both jobs were taken, **one by each node** (`attempted_by` node1 and node2), and
  both runs stepped at the same time — 68 steps each at twenty seconds in;
- one run finished in 70 s, the other was abandoned at 50 steps **by the other
  node's reaper** — the bug described above, and the only thing the trial found.

With that fixed the shape is: the queue spreads, the work runs beside itself, and
the only rows a node closes are its own.

## What was verified

Two nodes on one machine (`4201`, `4202`, the second with
`MONTY_CAPABILITIES=gpu,world:mujoco`): both footers said "2 nodes", both settings
pages listed both nodes with their own tags and both tag groups, and stopping one
node moved the footer and the list to one node with no reload. On the page that
was still open, the peer's name was a link to `http://127.0.0.1:4202` — the port
it advertised — and this node's own name was text.
`test/ex_tbp_monty_web/live/cluster_chrome_test.exs` and
`test/ex_tbp_monty_web/live/settings_live_test.exs` pin the two live updates; the
cluster's own decisions are pinned in `test/ex_tbp_monty/cluster_test.exs`,
`test/ex_tbp_monty/cluster/nodes_test.exs` and
`test/ex_tbp_monty/cluster/capabilities_test.exs`.

Placement was checked the same way, on `4211`/`4212`, with no tags declared on
either node: a run queued through `POST /mcp` (`monty_run_experiment`, a MuJoCo
config) was performed by the node that was asked, which is the fail-open answer
and therefore the behaviour a lone node has. Asked from the other node,
`Cluster.Peers.recent()` came back with the first node's **finished** run and its
420 steps — the row the in-flight query could never have shown. The decisions
themselves are `test/ex_tbp_monty/cluster/placement_test.exs`, and the claim
moving `studio_runs.node` is `test/monty/studio/run_history_test.exs`.
