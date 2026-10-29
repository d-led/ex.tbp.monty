# Pretrained memories

Monty's pretrained learning modules, exported as data this port can read. One
file per model, named after Monty's own directory for that model.

Nothing here is computed by this project and nothing here is hand-written: each
file is a lossless export of graphs **Monty trained**, taken from Monty's own
prerequisites, and it is committed so a run can recognise an object without a
Python interpreter and without a `torch` install.

## `surf_agent_1lm_10distinctobj.jsonl.gz`

**What it is.** The graph memory of Monty's `surf_agent_1lm_10distinctobj`
model — ten YCB objects, every node's position and the four features the
evidence-based learning module matches on (`hsv`, `pose_vectors`,
`pose_fully_defined`, `principal_curvatures_log`) — one object per line, gzipped.

**Where it comes from.** It is exported from the `model.pt` of the
`surf_agent_1lm_10distinctobj` model in Monty's **`pretrained_ycb_v10`** release.
Those pretrained models are Monty's prerequisites, published by the Thousand
Brains Project:

- Monty's own instructions, "Download Pretrained Models":
  <https://github.com/thousandbrainsproject/tbp.monty/blob/main/docs/how-to-use-monty/getting-started.md#42-download-pretrained-models>
- The archive they are published in, for the version this port's configs name:
  <https://tbp-pretrained-models-public-c9c24aef2e49b897.s3.us-east-2.amazonaws.com/tbp.monty/pretrained_ycb_v10.tgz>
  (the same public bucket serves `pretrained_ycb_v13.tgz`, which is what Monty's
  current documentation links; the port's base configs still name v10, and this
  library must be the model those configs name, or a run would recognise with
  someone else's memory.)

Unpacked where Monty expects it (see `priv/prerequisites.yaml`), that archive
puts the pickle at:

```
$MONTY_MODELS/pretrained_ycb_v10/surf_agent_1lm_10distinctobj/pretrained/model.pt
```

**The command that produced this file.** Run in a checkout of the port, with an
interpreter that has `torch` — Monty's own pinned environment does (see
`docs/validation.md`, "The environment the recordings came from"):

```
PYTHON=$(conda info --base)/envs/tbp.monty/bin/python \
    scripts/sync_monty_libraries.sh --only surf_agent_1lm_10distinctobj --force
```

which is a wrapper around the exporter itself:

```
python scripts/export_monty_pretrained.py \
    --model "$MONTY_MODELS/pretrained_ycb_v10/surf_agent_1lm_10distinctobj/pretrained/model.pt" \
    --out priv/monty/libraries/surf_agent_1lm_10distinctobj.jsonl.gz
```

The script's docstring is the specification of the format; briefly, each line is
`{"object_id": …, "input_channel": "patch", "positions": [[x, y, z], …],
"features": {…}}`, positions and features rounded to six decimals (micrometres —
far below what a voxel or a tolerance can tell apart), and the stored graph is
exported as stored rather than rebuilt, because that is what the evidence module
loads.

**One oddity worth knowing.** A gzip archive records the name of the file it was
created from, and that name is the one this export had at the time —
`monty_pretrained_10distinctobj.jsonl`. So `gunzip -l` and a hex dump of the
header still show the old name even though the file is now named after the model.
The bytes are the model's; only the embedded name is stale.

## Keeping it current

`scripts/sync_monty_libraries.sh` re-exports the models this port ships a library
for, from whatever Monty prerequisites are installed — so after a Monty release
moves, or after the archive is unpacked on a new machine, the memory is refreshed
rather than grown stale:

```
scripts/sync_monty_libraries.sh                 # refresh the libraries present here
scripts/sync_monty_libraries.sh --all           # also export every other model found
scripts/sync_monty_libraries.sh --only <model>  # one model, named
scripts/sync_monty_libraries.sh --force         # re-export even if up to date
```

It downloads nothing: it reads `$MONTY_MODELS` (Monty's own default if unset) and
says what to do when the archive is not unpacked yet. It is idempotent — a model
whose library is newer than its pickle is left alone.

## How a run finds it

A config's `model_name_or_path` names Monty's model directory
(`…/surf_agent_1lm_10distinctobj/pretrained/`); the port takes the segment before
`pretrained` as the library name and looks for `<libraries dir>/<name>.jsonl.gz`
(`Monty.Studio.Memory`). The directory is `priv/monty/libraries` unless
`config :ex_tbp_monty, :monty_libraries_dir` says otherwise.

**A config naming a model with no library here is not an error.** The run starts
with an empty memory and says so as a warning finding
(`:no_pretrained_memory`), because a run with nothing to recognise with cannot
recognise anything, however long it runs.

## Licence

The pretrained models are the Thousand Brains Project's, published under the same
MIT licence as `tbp.monty` (<https://github.com/thousandbrainsproject/tbp.monty>).
The objects they describe are from the [YCB dataset](https://www.ycb-benchmarks.com/).
