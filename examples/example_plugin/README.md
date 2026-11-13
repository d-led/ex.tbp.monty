# An example plugin

One node, three plugins, and nothing invented: this is the smallest application
that is a real Elixir Monty Studio plugin host.

A studio run is assembled from modules that need not live in the same node — an
**experiment**, the **learning modules** it steps, and the **motor policies** that
decide where to sense next (`MontyPlugin`). This example offers one of each:

| Plugin | Kind | What answers |
| --- | --- | --- |
| `ExamplePlugin.Experiment` | `:experiment` | the run it asks for, as data (`run/0`) |
| `ExamplePlugin.LearningModule` | `:learning_module` | `Monty.Frameworks.Models.EvidenceMatching.LearningModule`'s evidence threshold, parsed from the environment |
| `ExamplePlugin.Policy` | `:motor_policy` | `NaiveScanPolicy`'s square spiral |

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
studio nodes under *Ex.Monty nodes* and this one under *Ex.Monty.Plugin nodes*,
with the tags `plugin`, `plugin:experiment`, `plugin:learning_module` and
`plugin:motor_policy` — the tags are what it offers, not what somebody declared.

The CAD server's MCP tools read the same registry, so from a node of that
application in the same cluster:

```
cad_plugin_list
#=> 3 plugin(s) on this cluster: experiment: 10simobj_surf_agent_one_episode;
#   learning_module: evidence_threshold; motor_policy: spiral_scan

cad_plugin_describe name=spiral_scan kind=motor_policy
#=> spiral_scan — motor_policy, offered by example_plugin@127.0.0.1: kind
#   :motor_policy, name "spiral_scan", needs [:monty], placement :anywhere,
#   version "0.1.1"
```

Alone, without the compose project, `mix run --no-halt` is enough: the plugins are
registered on this node and visible to itself. The cluster machinery is
environment, not code:

| Variable | What it does |
| --- | --- |
| `--name example_plugin@127.0.0.1` | what this node is called; a VM cannot be renamed after it starts |
| `MONTY_CLUSTER_SECRET` | the cookie, the same string on every node that should join |
| `MONTY_SEEDS` | the nodes to reach, in the spelling a peer's Settings page shows |
| `PLUGIN_SCOPE` | the `:pg` scope, `monty_plugins` unless a deployment says otherwise |
| `PLUGIN_DISCOVERY=none` | takes part in no cluster at all |
| `EVIDENCE_THRESHOLD`, `X_PERCENT_THRESHOLD` | the learning module's setting, defaulting to `"x_percent_threshold"` and `20` |

Seeds are retried every five seconds, so the order `process-compose` starts the
processes in does not matter — the studio nodes take far longer to boot than this
one.

## What the tests hold

```
mix test
```

* every description conforms to the contract, and the three kinds appear once
  each;
* the application, started the way a release starts it, is what the registry
  answers, and the run the experiment names resolves to plugins this node offers;
* a plugin that does not describe itself usably is not offered — the process
  refuses to start rather than leaving a name in the cluster that nobody can
  call;
* the threshold a step compares against is what Monty computes for the setting,
  and a setting Monty does not define is refused where the module is built;
* an episode of the spiral starts by looking up, turns its leg at the right step,
  and starts over on `reset/1`.

## What it does not do

Nothing in a studio node *executes* a remote plugin yet. A learning module is
advertised rather than routed — a step calls it thousands of times, so the caller
compiles it in and the cluster's job is to say what is offered where — and
`ExamplePlugin.Experiment.run/0` is a definition for a caller to read, not a job
the studio picks up today. That last step is the piece of work this example is
the specification for.
