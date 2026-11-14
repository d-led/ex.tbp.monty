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

## What is spread, and what is not

A run of several parts is divided across the nodes that can be given a part.
`Monty.Studio.Partition.hosts/3` keeps the nodes that are alive, offer what the run
needs (`ExTbpMonty.Cluster.Placement.candidates/2` — the same tags that decide
whether a node may perform the run at all), write a run's files where this node
reads them (`Nodes.shares_run_files?/2`) and speak this protocol; then it deals
the parts round robin, this node first, and the owner calls
`Monty.Studio.Jobs.Run.perform_part/4` on each of them over `:rpc`.

Measured on two nodes (`probe` and `node2`) sharing one `MONTY_ARTIFACTS_DIR` and
a two-part division of four episodes: part 0 performed by `probe` and part 1 by
`node2`, four steps each; the run `finished` with eight steps in its transcript,
in part order. A stop asked on the owner — `Jobs.Run.stop/1` — reached both:
`run=stopped` with both parts `stopped` at eight steps each, the peer's included,
which is the `:rpc` cast that `stop_part/1` answers.

Three things carry a part across nodes, and each had to be true first:

- **Its steps come back as a file.** A part's steps live in the performing node's
  `RunStream`, a table on one machine. Every part now writes its own steps to
  `<run>/parts/<phase>-<index>.jsonl` when it ends — one step a line, its entry and
  its moment — and the run's transcript is those files in part order
  (`Artifacts.store_part/5`, `read_part/3`, and `store_parts/2` reading them). A
  part this node performed writes the same file, so the reader is the same
  wherever a part ran, and a part that failed leaves the steps it took, which is
  the number its row shows.
- **The run's directory is one answer.** A part may only go where that directory
  can be read, so `Nodes.identity/0` reports the directory a run's files are
  _written_ to — `Artifacts.root/0` — rather than a second setting saying where
  they ought to be. Those were two levers (`:studio_artifacts_dir` and
  `MONTY_ARTIFACTS_DIR`) and, outside a release, two answers: the first run of the
  two-node check refused the peer, correctly, because the two nodes named
  different directories.
- **The peer is asked with the record.** A peer has no row for a run it does not
  own — a node's runs table is its own — so everything a part needs travels with
  the call: the record, the part, and, for an evaluation part, the merged
  memory's _description_, which names a directory in the run's own folder and is
  readable by whoever can read the run's files. The peer opens the experiment
  itself (`opened_for/1`) and writes nothing to the run's row.

### A networked run is a run

A run asked for on one node is no longer that node's work. All three shapes are
ordinary now, and none of them needs a second page:

- **Performed elsewhere.** A node that cannot offer what the run needs — a world
  it does not have, a tag it does not carry — hands the job back and a peer's queue
  takes it (`Placement`, "Where a run goes" above). The record says `queued` while
  it waits, which is the truth.
- **Divided.** Four episodes at a parallelism of two are two parts, dealt round
  robin to the nodes that can be given one, each claimed in its row before its
  first step.
- **Survived.** A node that dies mid-part leaves a claim that lapses, a row that
  says which part ended, and a run that the next worker continues from there
  rather than from zero — the boot recovery (`Monty.Studio.Jobs.Reaper.recover/0`)
  re-queues it, and a part still in a _peer's_ hands is left to that peer instead
  of being taken twice.

What the record says while all this happens was made honest in the same pass:
`RunHistory.take/1` writes _which_ node has the run — the column a Stop is routed
by (`Cluster.Owner`) — and `mark_running/1` is written by the worker at the first
step, not when it picks the job up. Opening an experiment (composing the config,
starting the world, loading a pretrained library) is minutes on a big one, and a
row that said `running` through it was claiming work it had not begun.

Verified where: the division, the peer's claim, the stop that travels and the
resume are `test/monty/studio/jobs/run_test.exs`'s two-node cases (with
`cluster_of_two/1` and `claim_part/3` standing in for the second VM), the reaper's
boot recovery is `reaper_test.exs`, and the record's words are
`run_history_test.exs`. On a real cluster the division itself was measured as
described above, on `probe` and `node2`.

### Who owns a part, and what happens when a node dies

A part is an owner, not a work item. It has a row, a claim, a lease and a
transcript file of its own, so the question a reader of this design asks — _are
partitions stateless workers or resumable experiment owners?_ — is answered by
naming the things that make the second true:

| the question                            | where it is answered                                                                                        |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| who has part 2, and since when          | `studio_run_parts.node`, `.claim`, `.started_at`, written before the first step (`RunHistory.claim_part/3`) |
| how long that stays true without a word | the lease, `Monty.Studio.Claim.ttl_seconds/0`, renewed while the part works                                 |
| who may write how it ended              | only the holder of the token; anybody else is `{:error, :not_owner}` (`RunHistory.release_part/3`)          |
| what happens when that node dies        | the part is listed as recoverable (`lapsed_parts/1`) and given to the next candidate — one owner at a time  |
| what a node may be asked at all         | `ExTbpMonty.Cluster.Protocol`, advertised with the version and refused at the door (`perform_part/4`)       |

- **A part is claimed before it is performed.** `RunHistory.claim_part/3` takes
  the row only if nobody holds it — or if the holder's lease has run out — and
  answers the token that fences the writes about it. A second node asking for the
  same part is told who has it (`{:error, {:held, node, until}}`) rather than given
  it, and a part that has ended cannot be claimed at all
  (`{:error, {:settled, status}}`). That refusal is the whole answer to
  "reassign without silently duplicating runs": two nodes cannot both be told to
  perform part 2.
- **The claim is renewed while the part works.** The owner waits for its part in
  `Jobs.Run.await/3`, which renews the claim at a third of the lease and stops the
  work if a renewal is refused. A part is minutes to hours, so a lease that was
  only taken once would lapse under a working node; a lease that is renewed is a
  part nobody else can take.
- **A write is fenced.** A node that lost its part still holds its token, and the
  row no longer does: its `finished` is refused with `{:error, :not_owner}` and
  logged, instead of overwriting the work of the node that has the part now. This
  is the case the forum's wording is about — a node believed dead that comes back.
- **A lost node costs a part an attempt, not the part.** `Partition.hosts/3`
  answers an **ordered list** per part — the primary first, then the rest in round
  robin order — and `run_part/5` walks it when a peer stops answering: the row goes
  back to `queued` (`RunHistory.abandon_part/1`), and the next node claims it with a
  new token. Measured on the two-node probe by killing the peer mid-part: the
  part's row returned to `queued`, the second candidate claimed it, and the old
  token's later `finished` was refused.

What a lost part does next, said plainly: an **evaluation** part given to another
node picks up where the one that had it stopped. Its file carries the episodes it
finished (`Artifacts.append_part/6`, written at every boundary), and
`Jobs.Run.remaining/2` drops those from what the new owner is given. A **training**
part still starts its stretch again, because the episodes build on each other and
the model that took them did not travel with the part. The lease is what makes
either safe: nothing the lost holder writes can land.

### A run whose worker died, which is not the same failure

A node dying _while a part is in hand_ is the case above — the part is re-taken
inside the wave that was already running. A node dying _with the run_ is another:
nothing is left to walk the division, and until `3738467` the answer was to close
the run as failed (`Monty.Studio.Jobs.Reaper.sweep/0`) and lose the work.

Now the boot sweep asks first. `Reaper.recover/0` runs once at boot, before the
sweep, and put back in the queue every run of this node's whose division has
**something done and something left**; the sweep then closes whatever it did not
take. What a resumed run keeps:

| it keeps                       | where it comes from                                            |
| ------------------------------ | -------------------------------------------------------------- |
| the division, one row per part | `RunHistory.parts/1` — a run that finds one does not plan      |
| the parts an attempt ended     | `RunHistory.ended_parts/1`; `step_wave/6` skips them           |
| each part's steps              | the part files (`Jobs.Run.store_parts/2`)                      |
| the numbers so far             | `RunHistory.checkpoint_summary/2`, read by `Summary.restore/1` |

Three things it does not keep, and says so in the run's own log: a training part
interrupted mid-episode starts that episode again; a worker that dies **inside** a
wave loses that wave's numbers (the checkpoint is at wave boundaries, because until
a wave ends its numbers are in memory only); and a run whose parts are all ended is
closed rather than resumed — there is nothing to perform, and re-queueing it would
be a second attempt wearing the first one's record.

**On Horde and consistent hashing**, the suggestion this design did not take
literally. `Horde.Registry` and `Horde.DynamicSupervisor` are already in the
supervision tree (`ExTbpMonty.Cluster`), and `:pg` carries the plugin registry
across nodes. What is _not_ Horde's is the division: consistent hashing answers
"which node should own partition k" for a cluster whose parts have no shared
record, and it re-maps on membership change — which is exactly the moment this
design must not move a part that somebody is performing. The claim is that
coordination instead: assignment may be as simple as round robin because the
_candidacy_ is decided by tags, build and shared files, and because taking a part
is a compare-and-set in the one table both nodes can see. A Horde ring on top
would give a stable preference order — which `Partition.hosts/3` already provides,
as a list — without deciding ownership.

### What is still not spread

- **A run's job lives in that node's database.** With a file per node, a second
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

- **A part's live steps are the performing node's memory.** Its steps and pictures
  are written where the run's files go — which a division requires to be shared —
  but a page on the owner reads a part's _live_ steps from `RunStream`, which is
  the memory of this node. A page opened on the owner while a peer steps a part
  therefore sees the transcript only once the part ends and its file is read.
  PubSub here is the cluster-wide adapter, so the events themselves already cross;
  what would need an `:rpc` is the catch-up read for a page opened later.

- **A peer on another build is refused, not tolerated.** Handing a part over is
  calling into the peer's own code with this build's record and reading this
  build's answer, so `Partition.hosts/3` keeps only nodes whose `version` is this
  node's — a peer mid-boot answers `"unknown"` for a few seconds and is not a
  candidate until it has the real one.

- **A run's division is recorded, its parts' nodes included.** `studio_run_parts`
  keeps one row per part: how many the experiment was divided into, what state
  each is in, and the node that has it — written when the worker divides the run
  and updated as each part starts and ends. The run page's header counts them (`3
of 4 parts done`) and its title names each part's node and the steps it took, so a
  part that ended at 68 of the 70 steps it was given reads differently from one
  that did all of them. The row's `node` is the node that performed the part: the
  owner writes it when it makes the assignment, because a peer has no row to
  write. They cost no message: a page reads a table.

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
