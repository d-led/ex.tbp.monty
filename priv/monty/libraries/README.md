# Pretrained memories

Monty's pretrained learning modules, as data this port can read.

**In one line:** nothing in this directory is committed and nothing is
hand-written. Each file is produced on the machine that needs it, by the
application itself, from the pretrained archive `/prerequisites` unpacked — so a
run recognises objects without a Python interpreter, without `torch`, and without
a model file travelling through git.

| Question | Answer |
| --- | --- |
| Which files exist? | `<release>/<model>.jsonl.gz`, one for every model of every pretrained archive unpacked here. `priv/monty/libraries/*/*.jsonl.gz` is in `.gitignore`, with no exception |
| Where do they come from? | `$MONTY_MODELS/<release>/<model>/pretrained/model.pt`, unpacked from the archive `priv/prerequisites.yaml` names |
| Who writes them? | `Monty.Studio.Pretrained.sync/2` — the last phase of a prerequisite fetch, after the archive is unpacked |
| How does a run find one? | `Monty.Studio.Memory`, from the config's `model_name_or_path` |
| Why is it not in git? | It is derived: a function of an archive that is already downloaded, one file per model per release, and a release holds a dozen models. Committing it would put Monty's data in this project's history for good |

## The layout, and why it has a release in it

    priv/monty/libraries/<release>/<model>.jsonl.gz

`<release>` is the directory Monty keeps models of one release in
(`pretrained_ycb_v13`), `<model>` is Monty's own directory name for a model
(`surf_agent_1lm_10distinctobj`), and a config's `model_name_or_path` names
both:

    ${constants.pretrained_dir}/surf_agent_1lm_10distinctobj/pretrained/

The release is part of the address because it is part of the model: the same
name in two releases is two memories, trained differently.

* A config naming `${constants.pretrained_dir}/…` means whichever release its
  `pretrained_dir` resolves to.
* Monty's default is `pretrained_ycb_v14`; the recordings in `test/fixtures/`
  were made with `pretrained_dir` overridden to `pretrained_ycb_v10`.
* Recognising with another release's graphs would answer a question nobody asked.
  So the port looks in the release the config names, and when only another
  release is exported here it says so (`:memory_from_another_release`) instead of
  substituting it quietly.

## What is in a file

One JSON object per line, one line per object and input channel:

    {"object_id": "mug", "input_channel": "patch",
     "positions": [[x, y, z], …],
     "features": {"hsv": [[h, s, v], …], …}}

Every node's position and the four features the evidence-based learning module
matches on (`hsv`, `pose_vectors`, `pose_fully_defined`,
`principal_curvatures_log`) are there, and nothing else: a graph that is only
ever matched against does not need the rest. `pretrained_ycb_v10`'s models were
trained with the older feature-graph learning module and store
`GraphObjectModel`s; the evidence module loads them as they are
(`use_original_graph`), which is why the stored graph is exported rather than a
rebuilt one.

The archives Monty publishes, for reference:
<https://tbp-pretrained-models-public-c9c24aef2e49b897.s3.us-east-2.amazonaws.com/tbp.monty/pretrained_ycb_v14.tgz>,
and Monty's own instructions, "Download Pretrained Models", in
`docs/how-to-use-monty/getting-started.md`.

## How they are made, without torch

`model.pt` is a torch save: a zip holding a pickle and the raw bytes of every
storage the pickle names. `Monty.Studio.Pretrained.Torch` reads both, using the
[`unpickler`](https://hex.pm/packages/unpickler) dependency for the pickle and its
own resolvers for torch's storages and `_rebuild_tensor_v2`. Monty's classes
(`GraphObjectModel`, `Data`, `GlobalStorage`) are walked as attribute maps;
nothing about how Monty computes with a graph is reimplemented.

That is not a guess about the format. The Elixir export was compared, record for
record, against the same models exported by `torch` through the Python exporter
that used to live in `scripts/`:

| release, model | records | identical to torch's |
| --- | --- | --- |
| `pretrained_ycb_v10/surf_agent_1lm_10distinctobj` | 10 | 10 |
| `pretrained_ycb_v13/surf_agent_1lm_10distinctobj` | 10 | 10 |
| `pretrained_ycb_v14/surf_agent_1lm_10distinctobj` | 10 | 10 |

Every number equal, not merely close. `torch` is two hundred megabytes of
numerics this application would never call, so it is not a dependency.

**Why full precision.** The files were once written at six decimals, reasoning
that micrometres are far below anything a voxel or a tolerance can tell apart.
Measured against Monty's own recording of an episode, they are not:

* a node's frame a millionth short becomes a pose a millionth wrong;
* that pose rotates every step's displacement;
* where many nodes match an observation equally well — a sphere — a
  rounding-sized difference picks a different node at the cut-off.

That cost one object `8 %` of its evidence. The files are 2.3 times larger as a
result, and they are the exact graph.

## Keeping it current

The export runs as the last phase of a prerequisite fetch, and it is idempotent: a
library newer than the pickle it came from is left alone. Fetching something that
is already here still runs it, which is how a library that was deleted — or one
made by an older version — comes back without a second download:

    /prerequisites → Download (of an archive that is already here)

From a checkout, the same thing without a browser:

    mix monty.prerequisites.fetch            # everything the manifest names
    mix monty.prerequisites.fetch pretrained_ycb_v14

It downloads nothing that the manifest does not name, and it says so when the
archives are not unpacked yet.

## How a run finds it

`Monty.Studio.Memory` reads the model name and the release off the config's
`model_name_or_path` and loads
`priv/monty/libraries/<release>/<name>.jsonl.gz`.

A config whose model has no library here is **not an error**: the run starts with
an empty memory, and the setup page and `mix monty.run` say so before it runs —
because a run with nothing to recognise with cannot recognise anything.
