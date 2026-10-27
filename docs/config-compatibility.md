# Config compatibility

An experiment config written for Monty must mean the same thing here. This
document says exactly how far that goes, so nobody has to guess.

## What is read

`Monty.Config.Source` reads a Monty checkout (`MONTY_SOURCE`, default
`../monty-orig`) and finds:

* `src/tbp/monty/conf/experiment.yaml` — the root config;
* the `defaults:` groups it pulls in (`monty`, `monty/learning_module`,
  `environment`, `env_interface`, `termination`, `logging`, `telemetry`, …);
* every `conf/experiment/**/*.yaml`, including `test/` and `tutorial/`.

## The Hydra subset implemented

Exactly the syntax Monty's tree uses — checked, not assumed:

| Feature | Example |
| --- | --- |
| defaults list | `- /monty: evidencegraph_exp1000_emin_t3` |
| shorthand default | `- hypotheses_updater/burst_sampling_5nn@learning_module_0` |
| package header | `# @package experiment.config.monty_config` |
| package override | `@learning_module_0` (relative to the including config) |
| special packages | `_global_`, `_here_` |
| self placement | `- _self_` |
| required group | `- experiment: ??` (filled from the command line / UI) |

Not implemented, because Monty does not use them: `override` entries,
`optional:` markers, CLI package overrides, Hydra sweeps.

## Composition, then resolution

Composition and interpolation are two steps on purpose.

1. `Monty.Config.Composer.compose/2` produces the same tree Monty's
   `conf/update_snapshots.py` writes to `tests/conf/snapshots/*.yaml`,
   `${...}` strings included.
2. `Monty.Config.Resolvers.resolve/2` turns those strings into values:

| Resolver | Result here |
| --- | --- |
| `${constants.min_eval_steps}` | the referenced value, type preserved |
| `${oc.env:VAR}` / `${oc.env:VAR,default}` | the environment variable, or its default, or an error naming it |
| `${monty.class:a.b.C}` | the dotted path as a string, for `Monty.Config.Registry` |
| `${np.array:[2, 0.5, 0.5]}` | `[2.0, 0.5, 0.5]` |
| `${np.ones:3}` | `[1.0, 1.0, 1.0]` |
| `${np.list_eval:[np.pi / 8, np.pi * 2]}` | arithmetic via `Monty.Config.Expression` |
| `${path.expanduser:~/x}` | `Path.expand("~/x")` |
| `${path.tests:conf/x.yaml}` | `<checkout>/tests/conf/x.yaml` |

An unresolvable reference is an error. A tree that still contains `${` after
resolution is an error. Nothing is passed through as a string that looks like a
value.

## The oracle

```bash
mix monty.config.snapshots
```

composes every experiment and compares it, path by path, with
`<checkout>/tests/conf/snapshots/`. Both missing and extra keys are
differences. The current state: **103 of 103 match**.

The same check runs as a test (`test/monty/config/composer_test.exs`) and in CI
against a pinned Monty revision.

## Deliberate differences

* `monty.class` yields the class path, not a class object: an Elixir process
  cannot hold a Python class. `Monty.Config.Registry` maps the path to a module
  and reports paths it does not know yet.
* `np.array`/`np.ones` yield lists, not tensors. Nx tensors appear at the
  numeric core's boundary, not in the config.
* The top-level `hydra` group is dropped: it configures Hydra's run directory,
  which this application does not have. Monty's snapshots omit it too.
* `# @package` is honoured only in a file's leading comment block, so a comment
  further down cannot reroute a config by accident.

## Editing from the UI

The editor (planned) writes the *same* YAML file in the Monty checkout, then
recomposes and diffs against the snapshot before saving. A config Monty would
reject cannot be saved here either — the UI is a nicer editor for the existing
files, not a second config format.
