# Calling a plugin across a node

`ex_monty_plugin` (Hex) owns the contract; this page is the caller's side of it.
It says what a studio node can already do, what it cannot, and the rules that keep
a cluster of callers from talking itself into a loop.

## What already works

**Discovery.** A plugin joins `:pg` under `PLUGIN_SCOPE` from its own boot, and
`:pg` is OTP's cluster-wide process group — a name joined on one node is visible on
every node. The package turns what is registered into the tags a studio reads
(`plugin`, `plugin:<kind>`), so a plugin host appears in Settings → Cluster as a
node with those tags and no web URL.

**Identity over rpc.** A studio node's poller asks each peer for its version, tags
and web URL. A plugin host is not a studio and has no `identity/0` of its own, so
the poller asks a second question — `:rpc.call(node, MontyPlugin.Registry,
:identity, [])` — rather than deciding the peer is dead. That is the one place this
repository names the package, and it does it through `Module.concat` because the
studio does not depend on the plugin host and must not start doing so.

**A provider is an addressable process.** `MontyPlugin.Registry.lookup/2` and
`lookup/3` answer `%{kind:, name:, node:, pid:, describe:}`, and a `pid` is a
remote pid — `GenServer.call(pid, request, timeout)` reaches the plugin on its own
node with no transport of our own. Placement vocabulary is in the description
(`:anywhere` / `:owner_only`) and `lookup/3` answers "on that node" with an error
that names the nodes that do offer it.

## What is missing before a plugin can be *called* as intended

1. **There is no call contract.** `MontyPlugin` defines `describe/0` and nothing
   else. A caller that does not know the plugin's own message shape cannot ask it
   anything, so "a run is assembled from modules" holds for discovery and stops
   there. The example plugin says the same thing in its own moduledoc: a learning
   module is advertised, not routed.
2. **`placement` is a claim, not a check.** `:owner_only` says a call has to reach
   the node holding the state; nothing refuses a call that reaches a copy which
   cannot serve, and `lookup/2` will hand out exactly such a copy. The caller is
   expected to know; a cluster should not depend on that.
3. **`needs` is advisory.** A call that arrives on a node without `:quiddity`
   fails inside the plugin, as an error the cluster did not predict.
4. **No answer discipline.** Nothing says whether a request is idempotent, how long
   it may take, or what a call in flight does when the peer dies
   (`GenServer.call` to a dead remote pid exits with `:noproc`), so every caller
   invents its own answer.
5. **The studio never calls one.** Today the only plugin fact a studio node reads
   is `identity/0`.

## The loop rules

A cluster of callers can amplify a single fact into traffic that never settles.
These are the rules that stop it; each names what breaks if it is broken.

- **A node answers a peer from its own state and never asks another node while
  answering.** Otherwise one round of polling becomes N², and the next round
  amplifies again.
  `Peers.local_recent/0`, `Peers.local_runs/1` and
  `MontyPlugin.Registry.identity/0` are the answering side and all obey it: each
  reads one node's database or one node's `:pg`.
- **One publisher per fact.** PubSub here is the default adapter, which is
  cluster-wide — a broadcast on a plugin host is delivered on the studio. The node
  that did the work publishes; a subscriber re-renders and never re-publishes the
  same fact. There is no de-duplication key anywhere in this system, so a relay is
  not "less efficient", it is unbounded.
- **An answer is data.** Nothing in a reply may be read as a request. A plugin that
  answered "here is what I need from you" and then called back would be two nodes
  in a conversation, not a call.
- **No retry without a deadline, and no retry at all of a call that changes
  state.** Placement's own waiting answer (`{:wait, seconds}`) is the one place
  allowed to ask for another try, because it carries its own clock.
- **Nothing reaps on an event it publishes.** The reaper runs on a boot, a page
  load and the run page's tick; a reap publishes; if a page reaped on that
  publication the two would trade one message per round for ever.

## The change this asks for

Two additions to the plugin contract, both small, both in the package rather than
here:

```elixir
# A plugin answers requests, and says which kinds of request it answers.
@callback handles() :: [String.t()]                     # ["step", "reset", ...]
@callback call(request :: map()) :: {:ok, map()} | {:error, String.t()}

# The registry answers a routed call, so a caller never picks a node itself.
route(kind, name, request, opts) :: {:ok, map()} | {:error, String.t()}
```

`route/4` is where the missing checks belong, because it is the only place that
has the description and the caller's intent at once:

- `placement: :owner_only` with no `:on` option is refused, naming the nodes that
  could serve it — the caller cannot accidentally get a copy.
- a node whose tags do not cover `needs` is not a candidate, so the answer is
  "nobody can serve this" rather than a plugin deciding mid-step.
- `version` is reported with the answer, so a caller can refuse an older provider.
- the request carries a `"deadline"`; the registry does not retry, and an answer
  never contains a request (`An answer is data`, above).

Until that exists, a caller in this repository stays where it is: reading
`identity/0` and the tags, which is discovery, not routing.
