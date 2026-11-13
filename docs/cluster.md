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
`ExTbpMonty.Cluster.Nodes.offering/1` is the query placement will ask: the nodes
that offer a tag, `[]` when none does.

Settings → Nodes shows it both ways round — a node's row carries its tags, and
"What this cluster can do" puts each tag above the nodes that have it. The second
direction is where a heterogeneous cluster's differences become visible: a tag
with one node under it is a decision somebody has to make.

## What is not spread yet

A run is still performed by the node that owns it, and so are its parts.

That is not an oversight, it is where the two hard problems are:

- **The run's job lives in that node's database.** With a file per node, a second
  node neither sees the job nor can take it. Spreading the _queue_ needs one runs
  table for the whole cluster (`DATABASE_URL` pointing every node at one Postgres,
  which `ExTbpMonty.Database` already supports) or a merged view over the nodes'
  own tables. The owner column in the runs list waits on the same decision.
- **A part writes files and publishes its steps into memory.** A part's log and
  pictures go to `Artifacts.dir/1` and its steps to `Monty.Studio.RunStream`, on
  the node performing it; the run that owns the parts reads both, from its own
  node. Running a part elsewhere therefore needs either a filesystem the owning
  node can read (a mount, which is a deployment decision, not a code change) or an
  explicit transfer of what the part produced.

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
node moved the footer and the list to one node with no reload.
`test/ex_tbp_monty_web/live/cluster_chrome_test.exs` and
`test/ex_tbp_monty_web/live/settings_live_test.exs` pin the two live updates; the
cluster's own decisions are pinned in `test/ex_tbp_monty/cluster_test.exs`,
`test/ex_tbp_monty/cluster/nodes_test.exs` and
`test/ex_tbp_monty/cluster/capabilities_test.exs`.
