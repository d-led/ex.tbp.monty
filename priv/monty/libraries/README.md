# Pretrained memories

Monty's pretrained learning modules, exported as data this port can read.

**In one line:** nothing here is computed by this project and nothing is
hand-written — each file is a lossless export of graphs **Monty trained**, taken
from Monty's own prerequisites. It is committed so a run can recognise an object
without a Python interpreter and without a `torch` install.

| Question | Answer |
| --- | --- |
| Which files ship? | four: two models × two releases, `pretrained_ycb_v10/` and `pretrained_ycb_v13/` |
| Where do they come from? | Monty's prerequisites, unpacked under `$MONTY_MODELS` |
| How do I refresh them? | `scripts/sync_monty_libraries.sh` |
| How does a run find one? | `Monty.Studio.Memory`, from the config's `model_name_or_path` |

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
* Monty's default is `pretrained_ycb_v13`; the recordings in `test/fixtures/`
  were made with `pretrained_dir` overridden to `pretrained_ycb_v10`.
* Recognising with another release's graphs would answer a question nobody asked.
  So the port looks in the release the config names, and when only another
  release is exported here it says so (`:memory_from_another_release`) instead of
  substituting it quietly.

## What is shipped, and where it comes from

Both files exist for both models and both releases:

| file | objects |
| --- | --- |
| `pretrained_ycb_v10/surf_agent_1lm_10distinctobj.jsonl.gz` | the ten distinct YCB objects Monty's `base_config_10distinctobj_*` evaluation uses |
| `pretrained_ycb_v10/surf_agent_1lm_10similarobj.jsonl.gz` | the ten *similar* objects used by `base_10simobj_*` and `randrot_noise_10simobj_*`: `c_cups`, `cracker_box`, `d_cups`, `e_cups`, `fork`, `knife`, `mug`, `pudding_box`, `spoon`, `sugar_box` |
| `pretrained_ycb_v13/surf_agent_1lm_10distinctobj.jsonl.gz` | as above, from the release Monty's configs resolve to by default |
| `pretrained_ycb_v13/surf_agent_1lm_10similarobj.jsonl.gz` | as above |

v10 is what the committed Monty recordings were produced with; v13 is what a
config resolves to when nothing overrides `constants.pretrained_dir`.

Every node's position and the four features the evidence-based learning module
matches on (`hsv`, `pose_vectors`, `pose_fully_defined`,
`principal_curvatures_log`) are exported, one object per line, gzipped.

**Where they come from.** Monty's prerequisites, published by the Thousand
Brains Project:

- Monty's own instructions, "Download Pretrained Models":
  <https://github.com/thousandbrainsproject/tbp.monty/blob/main/docs/how-to-use-monty/getting-started.md#42-download-pretrained-models>
- The archives themselves:
  <https://tbp-pretrained-models-public-c9c24aef2e49b897.s3.us-east-2.amazonaws.com/tbp.monty/pretrained_ycb_v10.tgz>
  and
  <https://tbp-pretrained-models-public-c9c24aef2e49b897.s3.us-east-2.amazonaws.com/tbp.monty/pretrained_ycb_v13.zip>

Unpacked where Monty expects them (see `priv/prerequisites.yaml`), the archives
put the pickles at:

    $MONTY_MODELS/pretrained_ycb_v10/surf_agent_1lm_10distinctobj/pretrained/model.pt
    $MONTY_MODELS/pretrained_ycb_v13/surf_agent_1lm_10similarobj/pretrained/model.pt
    … and one for each of the other combinations

## The commands that produced these files

Run in a checkout of the port, with an interpreter that has `torch` — Monty's own
pinned environment does (see `docs/validation.md`, "The environment the
recordings came from"):

```
PYTHON=$(conda info --base)/envs/tbp.monty/bin/python \
    scripts/sync_monty_libraries.sh --only surf_agent_1lm_10distinctobj --force

PYTHON=$(conda info --base)/envs/tbp.monty/bin/python \
    scripts/sync_monty_libraries.sh --only surf_agent_1lm_10similarobj --force
```

Each is a wrapper around the exporter itself, once per release:

```
python scripts/export_monty_pretrained.py \
    --model "$MONTY_MODELS/pretrained_ycb_v10/surf_agent_1lm_10similarobj/pretrained/model.pt" \
    --out priv/monty/libraries/pretrained_ycb_v10/surf_agent_1lm_10similarobj.jsonl.gz
```

The exporter's docstring is the specification of the format; briefly, each line
is `{"object_id": …, "input_channel": "patch", "positions": [[x, y, z], …],
"features": {…}}`, every number at full precision so the port reads the same
bits Monty holds, and the stored graph is exported as stored rather than rebuilt,
because that is what the evidence module loads.

**Why full precision.** The files were once written at six decimals, reasoning
that micrometres are far below anything a voxel or a tolerance can tell apart.
Measured against Monty's own recording of an episode, they are not:

* a node's frame a millionth short becomes a pose a millionth wrong;
* that pose rotates every step's displacement;
* where many nodes match an observation equally well — a sphere — a
  rounding-sized difference picks a different node at the cut-off.

That cost one object `8 %` of its evidence. The files are 2.3 times larger as a
result, and they are the exact graph.

**One oddity worth knowing.** A gzip archive records the name of the file it was
created from, and that name is the one the export had at the time —
`monty_pretrained_10distinctobj.jsonl`, `monty_pretrained_10similarobj.jsonl`. So
`gunzip -l` and a hex dump of the header still show those names even though the
files are now named after the model and the release they came from. The bytes are
the model's; only the embedded name is stale.

## Keeping it current

`scripts/sync_monty_libraries.sh` re-exports the models this port ships a library
for, from whatever Monty prerequisites are installed — so after a Monty release
moves, or after an archive is unpacked on a new machine, the memories are
refreshed rather than grown stale:

```
scripts/sync_monty_libraries.sh                 # refresh every library present here
scripts/sync_monty_libraries.sh --all           # also export every model of every installed release
scripts/sync_monty_libraries.sh --only <model>  # every release that holds this model
scripts/sync_monty_libraries.sh --release <release>  # narrow to one release
scripts/sync_monty_libraries.sh --force         # re-export even if up to date
```

It downloads nothing: it reads `$MONTY_MODELS` (Monty's own default if unset)
and says what to do when the archives are not unpacked yet. It is idempotent — a
model whose library is newer than its pickle is left alone.

Only v10 and v13 are committed. v9 and v11 also hold these models; export them
with `--release pretrained_ycb_v9` (or `--all`) when a config needs them.

## How a run finds it

`Monty.Studio.Memory` reads the model name and the release off the config's
`model_name_or_path` and loads
`priv/monty/libraries/<release>/<name>.jsonl.gz`.

A config whose model has no library here is **not an error**: the run starts with
an empty memory, and the setup page and `mix monty.run` say so before it runs —
because a run with nothing to recognise with cannot recognise anything.
