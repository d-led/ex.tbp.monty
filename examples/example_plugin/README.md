# An example plugin

One node, three plugins, and nothing invented: this is the smallest application
that is a real Elixir Monty Studio plugin host.

A studio run is assembled from modules that need not live in the same node — an
**experiment**, the **learning modules** it steps, and the **motor policies** that
decide where to sense next (`MontyPlugin`). This example offers one of each:

| Plugin                         | Kind               | What answers                                                                                                |
| ------------------------------ | ------------------ | ----------------------------------------------------------------------------------------------------------- |
| `ExamplePlugin.Experiment`     | `:experiment`      | the run it asks for, as data (`run/0`)                                                                      |
| `ExamplePlugin.LearningModule` | `:learning_module` | `Monty.Frameworks.Models.EvidenceMatching.LearningModule`'s evidence threshold, parsed from the environment |
| `ExamplePlugin.Policy`         | `:motor_policy`    | `NaiveScanPolicy`'s square spiral                                                                           |

Two of those decisions are the framework's own code, taken from
[`ex_tbp_monty_core`](https://hex.pm/packages/ex_tbp_monty_core); the third is a
definition, not a decision. What this repository adds is the description a cluster
asks for, the placement that says whether a call may cross a node, and a process
that can be reached.

## Running it

```
cd examples/example_plugin
mix deps.get
```

Then, from the application's root:

```
process-compose up
```

`process-compose.yaml` starts two studio nodes and this one as a third process,
named `example_plugin@127.0.0.1`, with the same cluster secret and the same
seeds. Open <http://localhost:4001/settings>: **Settings → Nodes** puts the two
studio nodes under _Ex.Monty nodes_ and this one under _Ex.Monty.Plugin nodes_,
with the tags `plugin`, `plugin:experiment`, `plugin:learning_module`,
`plugin:motor_policy` and `monty`. The first four are what it offers, read from
the registry; `monty` is what it carries — `ex_tbp_monty_core` is on this node's
code path, and a plugin's `needs` (`[:monty]`, below) is answered against that
half of the answer.

A host on an `ex_monty_plugin` older than 0.1.2 published only the plugin tags,
so it carries nothing a `needs` could be checked against and the studio refuses
these plugins instead of calling them where the framework is not.

The CAD server's MCP tools read the same registry, so from a node of that
application in the same cluster:

```
cad_plugin_list
#=> 3 plugin(s) on this cluster: experiment:
#   example_plugin.10simobj_surf_agent_one_episode; learning_module:
#   example_plugin.evidence_threshold; motor_policy: example_plugin.spiral_scan

cad_plugin_describe name=example_plugin.spiral_scan kind=motor_policy
#=> example_plugin.spiral_scan — motor_policy, offered by
#   example_plugin@127.0.0.1: kind :motor_policy, name
#   "example_plugin.spiral_scan", needs [:monty], placement :anywhere, version
#   "0.1.1"
```

A plugin's name is cluster-wide rather than per node (`:pg` groups by kind and
name), so each of these carries the host that owns it.

Alone, without the compose project, `mix run --no-halt` is enough: the plugins are
registered on this node and visible to itself. The cluster machinery is
environment, not code:

| Variable                                    | What it does                                                                  |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| `--name example_plugin@127.0.0.1`           | what this node is called; a VM cannot be renamed after it starts              |
| `MONTY_CLUSTER_SECRET`                      | the cookie, the same string on every node that should join                    |
| `MONTY_SEEDS`                               | the nodes to reach, in the spelling a peer's Settings page shows              |
| `MONTY_CLUSTER=1`                           | join by gossip with no seed — the studio's own switch, read the same way      |
| `PLUGIN_SCOPE`                              | the `:pg` scope, `monty_plugins` unless a deployment says otherwise           |
| `PLUGIN_DISCOVERY=none`                     | takes part in no cluster at all                                               |
| `EVIDENCE_THRESHOLD`, `X_PERCENT_THRESHOLD` | the learning module's setting, defaulting to `"x_percent_threshold"` and `20` |

Joining is [libcluster](https://hex.pm/packages/libcluster), so a seed that is not
up yet is retried and nothing here polls: with seeds the node dials them, and it
gossips beside them (`ExamplePlugin.Cluster`). The gossip is what survives a
restarted studio: a window names itself `monty-studio-<id>@127.0.0.1` with a fresh
id on every start, so the name this node was handed stops existing, and a node
that listens for the window's announcements reconnects to the new one.

## The app it ships as

`app/` is this example's own window: a small Tauri program, built with
`cargo build --release`, that makes the node an application a person
double-clicks instead of a command to remember. It asks a studio's `/health` for
the node to join, reads that studio's cookie, starts the release with a node name
of its own (`example_plugin_app`), shows what this example is, which node it runs
as, where its log is and which studio it joined, and stops the node when the
window closes or Quit is chosen.

It lives here rather than in the studio's repository because this folder is what
a person takes away. Apart from `ex_monty_plugin` and `ex_tbp_monty_core` from
Hex, nothing outside it is needed.

```
cd examples/example_plugin
mix deps.get
MIX_ENV=prod mix release                          # the node: _build/prod/rel/example_plugin
cargo build --release --manifest-path app/Cargo.toml
```

`app/target/release/ex-tbp-monty-plugin-window` is then the executable, and
`_build/prod/rel/example_plugin` the node it starts. A packaged download is the
two of them inside one application bundle, which is the same arrangement a
checkout produces.

## What the tests hold

```
mix test
```

- every description conforms to the contract, and the three kinds appear once
  each;
- the application, started the way a release starts it, is what the registry
  answers, and the run the experiment names resolves to plugins this node offers;
- a plugin that does not describe itself usably is not offered — the process
  refuses to start rather than leaving a name in the cluster that nobody can
  call;
- the threshold a step compares against is what Monty computes for the setting,
  and a setting Monty does not define is refused where the module is built;
- an episode of the spiral starts by looking up, turns its leg at the right step,
  and starts over on `reset/1`.

## What it does not do

Nothing in a studio node _executes_ a remote plugin yet. A learning module is
advertised rather than routed — a step calls it thousands of times, so the caller
compiles it in and the cluster's job is to say what is offered where — and
`ExamplePlugin.Experiment.run/0` is a definition for a caller to read, not a job
the studio picks up today. That last step is the piece of work this example is
the specification for.
