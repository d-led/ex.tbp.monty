# sharing — two modules, one object, no parent

A limited experiment for the Thousand Brains "shared distributed learning"
discussion (Jeff Hawkins' alternating parent–child inference cycles, Niels'
hippocampal consolidation). Neither mechanism is implemented upstream and
neither has a config key here, so this set tests the one thing a config *can*
say: **two learning modules learning at the same time from two views of the same
surface, wired to each other only by a vote.**

## What is in it

| file | what it is |
| --- | --- |
| `conf/monty/learning_module/evidence_2lm_tutorial.yaml` | the tutorial surface module twice, tolerances keyed per patch |
| `conf/monty/connectivity/2lm_2sm_voting.yaml` | LM0 ← `patch`, LM1 ← `patch_side`, no LM-to-LM input, both vote |
| `conf/experiment/sharing/plate_two_columns.yaml` | one supervised training epoch, both modules written |

The world, the sensor trio, the interface, the clip transform and the policy are
the **cad set's** groups (`cad_plate_objects_2patch`,
`camera_tutorial_surf_agent_2patches`, `cad_plate_train`,
`missing_depthto3d_sensor3_semantic0_clip`, `naive_scan_5`). They are named in
the experiment's `defaults`, not copied, so a fix there reaches this set too.

## How to run it

Experiments page → `sharing / plate_two_columns` → **Run it**. One epoch over the
plate's three rotations is the default budget; the page's episode field is the
limit to set for a first look. There is no `mix` command in this workflow on
purpose — a desktop user runs it from the page.

Checks on the page should say the run would start (the plate's meshes come from
`/prerequisites`, the same ones the cad arms use). If the experiment is missing
from the list, the node is serving a config tree it read before this file
existed: `process-compose process restart node1` — client mode, and only when
`scripts/run_in_flight.sh` says nothing is stepping.

## What the run answers

The library it writes must hold **two** module indices, each with graphs on
them (`lm_index` in the JSONL, one record per object and channel). That is the
claim "two modules learned at the same time from one object".

What would falsify the premise: the second module refusing to start, or writing
nothing while the first learns. That is the honest current answer to "shared
simultaneous learning across many modules" — the arrangement is reachable only
as a fixed, static matrix, and the modules have no way to swap roles.

**Measured 2026-11-19**, from this page, one episode capped at 300 steps:
`finished`, 300 steps, 7.2 s, `votes sent 600 · votes used 600`, and every step's
log line carries `inputs learning_module_0=1 learning_module_1=1` — both modules
are fed from step 0. The library
`<libraries>/trained/sharing_plate_two_columns.jsonl.gz` holds **one record per
module index** (`lm_index` 0 and 1, both on `plate`): the second module did not
refuse, and did not write nothing.

So the flat arrangement works today, and what it cannot do is change. The next
question is not "can two modules share a stream" but "can the pair swap roles
while it runs", and that needs a mechanism, not a config.

## What this set is not

It is not a test of oscillation, replay or consolidation. A consolidation pass
over a stored library would be an offline job over the same files, needs no step
semantics, and can fail — that is the next experiment, after the parallel
learning modules work.
