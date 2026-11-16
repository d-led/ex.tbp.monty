# Animals and mushrooms: a corpus, and the experiments it is for

Written 2026-11-17, while the core work continues. This page is a **plan**: what
we intend to run, on what, and where each piece lives. It quotes no run's
numbers; a number belongs to the run that printed it.

## Why a corpus that is not YCB

Every experiment this port can run today recognises household objects — YCB's
seventy-odd meshes and Numenta's twelve scanned lab objects. That is the right
referee for parity with Monty, and it is the wrong corpus for the question the
port exists to ask, because those objects differ in shape, size and colour all
at once: a mug is not mistaken for a spoon by accident.

Animals are a family where that is not true. Within one family the silhouette is
similar and identity is carried by proportion, colour and small features — which
is exactly what the learning module's three channels can and cannot separate
(`hsv`, `pose_vectors`, `principal_curvatures_log`; see the tolerance table in
the hand-over). They are also rigid scans of figurines, so they step in MuJoCo
the way a mug does, and a set of seven to twenty of them makes an all-against-all
sweep cheap enough to read.

Mushrooms are the degenerate case worth having later: one silhouette, so
texture does nearly all of the work. If a mushroom corpus cannot be told apart,
the answer says something about the feature set that a tenth YCB object cannot.

## Where our things live

`mix monty.inputs` **mirrors** Monty's config tree: it writes `conf/**/*.yaml`
and `snapshots/**/*.yaml` into `priv/monty` and deletes every other YAML under
those two prefixes (`Monty.Config.Inputs.sync/2`, `prune/3` in
`lib/monty/config/inputs.ex`). `mix monty.refresh` runs it. So a config written
under `priv/monty/conf/` is deleted by the next refresh — silently, which is the
part that would waste a day.

Ours therefore live beside the copy, in a tree of the same Hydra shape:

| what | where | why there |
| --- | --- | --- |
| our configs | `priv/monty_experiments/conf/…`, named once by `ExTbpMonty.AnimalExperiments.conf_dir/0` | outside the mirror's two prefixes; `test/ex_tbp_monty/animal_experiments_test.exs` holds the rule |
| the object meshes | `$MONTY_DATA/mujoco/objects/<set>/` | data, not configuration, unpacked by `/prerequisites` like every other object set |
| the archive a person downloads | `$MONTY_DATA/downloads/` | one copy, checksummed; never in git, never re-fetched |
| attribution | `$MONTY_DATA/mujoco/objects/<set>/ATTRIBUTION.md`, and this page | it has to travel with the data, not stay in a doc |
| the plan | this page | — |

**Rule: never write a config under `priv/monty/`.** The corpus tree's README says
the same thing where someone would look for it first.

### The one seam still missing: composition from two roots

Every opener already takes `:conf_dir` — `Monty.Studio.open/2`,
`Monty.Studio.Catalog.experiments/1`, `Monty.Studio.Readiness` — and
`mix monty.run` does not (`@switches` in `lib/mix/tasks/monty.run.ex` has no
`--conf-dir`). But `Monty.Config.Composer` resolves every `defaults:` entry
against **one** root, and an experiment names a dozen groups
(`/monty`, `/environment`, `/env_interface`, `/termination`, `/logging`, …). Two
ways to make a copied experiment compose:

1. **A full copy.** Our tree carries every file the experiment's defaults reach,
   transitively. Self-contained, no code, and nearly the whole of `conf/`
   duplicated — which then drifts from the copy with nothing noticing.
2. **An overlay.** `Source.load/3` tries our tree first, Monty's copy second;
   `Composer` carries the two directories through. Our tree then holds only the
   files that differ — an environment group naming the animal `data_path`, a
   handful of experiments — and Monty's copy stays exactly the mirror.

**Take the overlay.** It is the shape of "copy one of Monty's experiments and
change three lines", which is the whole point of the exercise, and it keeps the
mirror pristine. What it costs: a search order in `Source`, one more option in
`Composer`, the same option passed by `Catalog` and `Readiness`, and a test that
a file present in both trees is answered by ours.

## The corpora, and what each can and cannot give us

| corpus | meshes a MuJoCo run can step? | how it arrives | licence, as its own page states it |
| --- | --- | --- | --- |
| **GraspNet-1Billion `models.zip`** | **yes** — `textured.obj` + `textured.png` per object (plus non-textured `ply`/`stl`) | one archive, Google Drive (also Baidu, Jbox), fetched once by a person or `gdown` | "All data, labels, code and models belong to the graspnet team, MVIG, SJTU … CC BY-NC-SA": attribution, non-commercial, share-alike. Confirm before any use outside research |
| YCB / Numenta lab | yes — already here | `/prerequisites` | unchanged; these are the controls |
| **Sketchfab collections** (animals, mushrooms, the mushroom 3D scans) | yes, per model | Sketchfab's own download, per model, with a person's API token | **per model**, recorded per model. A collection is a curated list, not a licence; many are CC-BY, some NC, some ND (no derivatives — unusable for us) |
| **Animal3D** | no — images, 26 keypoints, SMAL pose and shape | Google Drive | "publicly available"; the SMAL model it depends on is registration-gated at `smal.is.tue.mpg.de`, under its own licence |
| **GenZoo** | no — a million synthetic images with SMAL parameters | registration at the project site, then per-file links | code inherits MIT plus the institute's terms in `LICENSE.md`; the data needs an account |
| **SMS3D** | the *renders* yes, the mushrooms **no** | two public sample archives (white, brown) | code MIT; the mushroom models and soil textures are "not included … due to copyright restrictions", available on request |
| the taobao / amazon figurines | no — they are physical | bought and scanned (photogrammetry) | our photographs, but the figurine's design is somebody's |

Reading the table as a plan: **GraspNet first** (meshes, one archive, no
account), **Sketchfab second** (real variety, but per-model licence bookkeeping),
**Animal3D and GenZoo later and as evaluation or supervision** rather than as
meshes, **SMS3D and photographed mushrooms last**.

## Attribution, and being nice to downloads

Both are gate conditions, not polish: a corpus we cannot attribute is a corpus we
do not use, and a corpus we hammer is one we get cut off from.

- **One download per corpus, once.** Cached under `$MONTY_DATA/downloads/`, with
  the archive's sha256 recorded next to it. Nothing re-fetches on boot, on a
  test, or on a page load.
- **Quota-hosting is fetched by a person.** A Google Drive file of several
  gigabytes answers `download quota exceeded` after a handful of attempts; a
  retry loop is what turns that into a ban. The page says what the fetch costs
  and who has to start it; it does not start it.
- **Sketchfab only through its own download route**, one request per model,
  never a crawl of the site, and never a redistribution of the file from this
  repository.
- **The attribution record travels with the data.** Per object set: the source,
  its author or team, the licence, the URL, the sha256 of what was downloaded,
  and the citation line. For Sketchfab, per **model** — a set assembled from
  twelve pages has twelve records.
- **Credentialed sources are placed, not stored.** `/prerequisites` already
  answers "is it here"; the person puts the files where the page says and the
  page verifies. The application does not keep anybody's password or token.
- **Nothing from a corpus goes into git.** `priv/monty/libraries/**` is generated
  for the same reason (see the standing rule in the hand-over); meshes are bigger.

## What an object set has to be

The world reads a directory per object under the environment group's
`data_path` (`priv/monty/conf/environment/mujoco_ycb_surf_agent.yaml` is the
shape), and the env-interface group names the objects
(`object_names`, `priv/monty/conf/env_interface/train_distinctobj_predefined.yaml`).
Each object directory holds:

- `textured.obj` — the mesh;
- `texture_map.png` — the texture, loaded separately because MuJoCo will not
  read the one the OBJ names;
- `metadata.json` — optional, and the only place three numbers can live:
  `refpos` (subtracted from the vertices), `refquat` (`wxyz`, whose conjugate
  rotates them) and `scale` (per axis). Unknown keys are a refusal, not a
  default (`priv/monty_py/world.py`, `load_object_metadata/2`).

That is the whole import contract: a converter reads the archive, writes those
three files per object, and writes the attribution record. The numbers in
`metadata.json` are chosen **by looking at the render** — a scan's vertices are
in whatever frame the scanner used, and an animal lying on its side is a corpus
that measures the wrong thing. In-app, as a Mix task (`mix monty.animals.import`),
not a shell script: the standing rule is that behaviour belongs in the
application.

## The experiment set

Each is a **copy of a config Monty ships**, with the environment group, the
object list and (where it matters) the epoch counts changed. Keeping the rest
identical is what makes a result a statement about the corpus rather than about a
config.

| # | experiment | copy of | what it answers |
| --- | --- | --- | --- |
| A1 | supervised pretraining on the animal set | `supervised_pre_training_base` | the cheapest memory: told which object it is while it explores. The baseline every other number is read against |
| A2 | unsupervised surface-agent training, then recognition | `surf_agent_unsupervised_10distinctobj` | can the surface agent build a usable memory of an animal from its own gait, with no labels |
| A3 | unsupervised distant-agent training | `only_surf_agent_training_10obj` (training only, keeps the memory) then a recognition config | the distant agent's version, and a memory we can reuse across experiments instead of retraining |
| A4 | recognition of the whole set from one memory | `unsupervised_inference_distinctobj_dist_agent` | what the memory is worth once built: the all-against-all row |
| A5 | held-out family member | A2 with the eval object removed from training | shape generalisation — the question animals are actually chosen for |
| A6 | the confusions, pairwise | A4 restricted to pairs (`cat`/`dog`, `cow`/`horse`/`hippo`) | not "does it recognise" but "what does it mistake for what", which one confusing pair explains better than any aggregate |
| M1 | mushrooms, later | A2 on the mushroom set | the degenerate family: one silhouette, texture carrying identity |

Read, in this order: **completions, then the step counts, then the mean** — the
run's own record has the first, and a mean over a short slice has surprised this
repository before. A control run on YCB (already here, same config) belongs
beside every one of these, so a difference has a corpus to blame and not a
patch.

## First: the GraspNet animals

Chosen because it is the only candidate that is meshes today, in one archive,
behind no account, and because its object list is the one this plan started
from: **object ids 48, 49, 51, 52, 55, 56 and 69** are the animal models. (The
names behind those ids are read off `obj_list.pdf` when the set is imported;
they are not guessed here.)

The order of work, each step leaving something checkable:

1. **Fetch once.** `models.zip` (4.3 GB) into `$MONTY_DATA/downloads/`, sha256
   written beside it, by a person or by `gdown`. Nothing else downloads it.
2. **Import.** `mix monty.animals.import --from <unpacked models> --ids
   48,49,51,52,55,56,69` writes `$MONTY_DATA/mujoco/objects/graspnet_animals/<name>/…`
   and its `ATTRIBUTION.md`; an id the archive does not hold is a refusal that
   names it.
3. **See them.** An environment group naming that `data_path`, and one run that
   draws the object in the patch and the centre view. The three numbers in
   `metadata.json` are settled here, on the render, and not by arithmetic.
4. **A1 and A2**, each with its YCB control beside it.
5. **A5 and A6** once the memory is cheap to rebuild, which is what A3 is for.

What "done" means for this slice: seven animals named by the world, a supervised
memory and an unsupervised memory both built from them, recognition rows for
each, and the attribution record in place — with the numbers in the runs'
records and the method, not the numbers, in this page.

## Decisions a person has to make

- **What the corpora may be used for.** GraspNet's licence is non-commercial and
  share-alike; the Sketchfab models differ one from another. If this work is ever
  more than research, that is a decision before a download, not after.
- **Meshes only, or real images too.** Animal3D is the only real-image animal
  benchmark in the list, and it is SMAL-shaped rather than mesh-shaped. It would
  make an evaluation the MuJoCo corpus cannot: an animal photographed, not
  scanned.
- **How much of the corpus is downloaded on a first boot.** The prerequisites
  saga fetches what is unfinished; a multi-gigabyte corpus should be
  `present?`-checked and fetched on request, not at start.
- **Seven objects or ten.** Seven is what the animal ids give. A recognition
  sweep reads better at Monty's usual ten, which means either a second corpus or
  six more meshes from Sketchfab.
