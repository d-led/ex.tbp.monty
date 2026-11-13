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

`process-compose.yaml` runs `scripts/cluster-node.sh` twice. The script is the
whole recipe:

```console
$ scripts/cluster-node.sh name port
```

It exports `MONTY_CLUSTER=1` and `MONTY_DB=sqlite`, starts the VM as
`name@127.0.0.1`, migrates that node's own database in a VM of its own (see
[below](#why-the-script-migrates-by-hand)), and then serves. Both nodes are
named, so nothing about them can be confused with the single node a bare
`mix phx.server` is.

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

| variable             | what it decides                                                                                                                                                                           |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MONTY_CLUSTER`      | `1`/`true` asks for the cluster's children. Not needed when `MONTY_SEEDS` is set — a list of nodes to dial is already the request                                                         |
| `MONTY_SEEDS`        | the peers to dial, `node1@10.0.0.7,node2@10.0.0.8`. Empty means gossip discovery, which is what several nodes on one machine need, because they cannot know each other's names in advance |
| `MONTY_COOKIE`       | a development node's cookie, passed to the VM as `--cookie`. A release reads `RELEASE_COOKIE`, which `rel/env.sh.eex` fills from `NODE_COOKIE`                                            |
| `PORT`               | that node's HTTP port                                                                                                                                                                     |
| `MONTY_CAPABILITIES` | what this node can do, comma-separated (see [capability tags](#capability-tags))                                                                                                          |
| `MONTY_DB`           | `sqlite` gives a development node a file instead of the Postgres a developer's machine has. A release asks `DATABASE_URL` instead                                                         |
| `NODE_NAME`          | a release's node name, the alias of `RELEASE_NODE`; in development the name is the VM's (`--name`/`--sname`)                                                                              |

**The cookie is the cluster's password.** Two nodes that disagree about it are two
clusters that quietly believe they are one: nothing fails, nothing is logged, and
each page shows one node. That is the failure this design's blueprint records, so
the settings page says where a node's cookie came from — and never what it is,
because a settings screen is not a place to print a password.

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
for exactly when clustering is on (`config/runtime.exs`): a job still executing
after ten minutes is put back in the queue for somebody else. On a node that runs
alone nothing is configured that was not configured before — a lone node's
longest run is never rescued out from under it.

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
- **A part writes files and publishes its steps into memory.** A part's log and
  pictures go to `Artifacts.dir/1` and its steps to `Monty.Studio.RunStream`, on
  the node performing it; the run that owns the parts reads both, from its own
  node. Running a part elsewhere therefore needs either a filesystem the owning
  node can read (a mount, which is a deployment decision, not a code change) or an
  explicit transfer of what the part produced.

### What one database gives you today, measured

Two development nodes told about **one** Postgres
(`DATABASE_URL=… MONTY_CLUSTER=1 MONTY_SEEDS=… elixir --name nodeN@127.0.0.1 -S
mix phx.server`), a run recorded on node1:

- **the queue spreads.** The job was inserted by node1 and taken by **node2**
  (`Jobs.Run.held?/1` answered `true` on node2, `false` on node1), and the steps
  went to 87 while both nodes read the same row;
- **the list is one list.** Both nodes' `/runs` show the run, with
  `owner=node1_127.0.0.1` — the node that recorded it;
- **the peer panel stays honest**: a node answers a peer with the runs **it owns**
  (`RunHistory.search(state: "running", node: …)`), so a shared table does not
  make every node report the others' runs as "somebody else's";
- **what is still one node's**: the live steps, which live in the memory of the
  node performing the run (the row is the record, written at every episode
  boundary, so a page elsewhere is that much behind), and — in a **release** —
  the run's files, which are written under the performing node's folder
  (`:studio_artifacts_dir`; a development node writes them into the checkout, so
  two dev nodes share them by accident).

One consequence worth deciding before relying on it: with one table, `node` means
_who has the run_. While it is queued that is the node that asked; the worker
overwrites it with its own name when it claims the job (the same setting, read at
`mark_running/1`), because that is the node whose memory holds the steps and, in a
release, whose folder holds the files. So the column always points at the node a
reader has to open — and the node whose queue took the job is the one it names.

Until those are answered, `Nodes.offering/1` answers a question nobody acts on
yet, and a cluster of several nodes is several studios that see each other and
share their downloads — which is already worth having for the tags and for the
one place that says what is running where.

## Why the script migrates by hand

An Ecto mix task reads configuration _before_ `config/runtime.exs`, which is where
a node's database is chosen — `mix ecto.create` would try the Postgres this
checkout was written around and find no database named in its config. `mix run
--no-start` does read that file, and `ExTbpMonty.Release.migrate/0` is the
migration a release applies, so the script runs those two and then serves.

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
