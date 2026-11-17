# Training: what exists, what is missing, and the order to do it in

Written 2026-11-06, after the port finished a full evaluation run and the crash
that used to end one. Every claim here is a file and a line, or a command whose
output is quoted.

**The state in one sentence**: the runtime can train an episode, Monty's
learning code is ported, and the studio's loop now hands each episode the memory
the last one wrote — so a config that trains runs here, and the guard that used
to refuse it (`Setup.phase_findings/1`) is gone. What is missing is the referee:
nothing yet compares a trained memory against the one Monty's own test asserts.

Measured 2026-11-06, `MIX_ENV=test` (the stand-in scene), a training config
stepped by hand:

```
name = "tutorial/surf_agent_2obj_unsupervised"   # plan [{:train, 3}], 2 objects
Run.start(setup, mode: :train, memory: %{})      # empty memory, as Monty starts
60 steps, then Run.update_ltm/1 and Run.memories/1
episode 0: memory = ["new_object0"]
episode 1: memory = ["new_object0"]             # from the memory episode 0 wrote
```

And through the queue, on the same config: `Jobs.Run.perform/1` ran two
episodes of 40 steps and closed its record `finished` with 80 steps.

---

## 1. What is already there

- **The learning code is ported and tested, not stubbed.**
  `EvidenceGraphLM.update_ltm_from_stm/1` has its `mode: :train` clause
  (`evidence_graph_lm.ex:1774`) and folds the episode into memory through
  `update_memory/1` → `GraphMemory.update_memory/7` → `build_graph`/`extend_graph`
  (`graph_memory.ex:96-140`). The pieces under it — `GraphObjectModel.build_model/4`,
  `add_graph_to_memory/3`, `FeatureAtLocationBuffer.get_infos_for_graph_update/1` —
  are the ones evaluation already exercises every step.
- **A whole training episode has run.** `test/monty/recognition_test.exs:123-132`
  drives `Monty.Runtime.Episode.run(model_id, environment, mode: :train,
max_steps: 30)` against an empty memory and asserts both halves of what training
  is: `detected_object == "new_object0"` and
  `remembered_objects(model_id) == ["new_object0"]`. That is Monty's
  `"new_object<n>"` naming, produced by `detected_object/2`'s `:no_match` branch.
- **The mode is told to the model** (`run_test.exs`, `set_experiment_mode`), and
  the epoch plan already expresses `[{:train, n}, {:eval, m}]`
  (`Setup.epoch_plan/1`).
- **38 of the 210 shipped experiments were blocked by nothing but the missing
  loop** — every one of them composes, has its classes ported and has its memory.
  Now that a training phase carries its memory, they run: the
  `test/evidence_lm/*` family (30 of them, and Monty's own tests are their
  referee), `surf_agent_unsupervised_{10distinctobj,10distinctobj_noise,10simobj}`,
  `test/hierarchy/two_lms_heterarchy(+_mujoco)`,
  `test/policy/dist_hypo_driven_multi_lm(+_mujoco)` and
  `tutorial/surf_agent_2obj_unsupervised`.

The catalog's state, measured 2026-11-06 with `MIX_ENV=test` and both world
selectors (a run of every shipped experiment, counting the ones that open with no
`:error` finding):

| world                               | runnable  | blocked by unported classes | blocked by the world |
| ----------------------------------- | --------- | --------------------------- | -------------------- |
| MuJoCo (`world_simulator: :mujoco`) | 40 of 210 | 80                          | 83                   |
| the stand-in scene (`:synthetic`)   | 60 of 210 | 144                         | 0                    |

Re-derive it rather than trusting a number written down here: open every shipped
experiment with `Monty.Studio.open/2`, pass the world you care about, and count the
ones whose findings include an `:error`.

## 2. What was missing — and what the first step added

**A phase is many episodes and one memory.** Monty keeps _one model_ for the
whole experiment: `train()` sets the mode and runs epochs of episodes over it,
and `post_episode` calls `self.model.update_ltm()` after each one
(`monty_experiment.py:613`), so episode two is matched against the graph episode
one built. This port starts a model per episode — `Jobs.Run.start_episode/5` →
`Run.start/2`, stopped again in `end_episode/4` — and `end_episode` never called
`update_ltm` at all, so there was nothing to carry even if the model had lived.

The first step (`Run.memories/1`, `Run.start/2`'s `:memory`,
`Setup.memories/1`, and the write in `end_episode/4`) makes the memory the thing
that travels: each episode starts from what the phase has learned so far, and
what it learns is folded in at the end, in Monty's order — the episode is logged
first, because the write rewrites the graph-to-target mapping the log is about.

Specified by `test/monty/studio/run_test.exs`:

- a training episode writes what it saw (an empty memory gains
  `"new_object0"`);
- an evaluation episode writes nothing;
- the next episode starts from what the last one wrote.

**And the copy is only paid where it can matter.** Reading the memory back out of
a module sends its whole state across a process boundary — **177 ms** for the ten
objects of `base_config_10distinctobj_dist_agent`, two to four steps of work
(`docs/speed.md`). So an _evaluation_ phase neither writes the episode nor reads
the memory back; it keeps the value it started with. That is also the cheaper
shape for the erlang side of the house: the memory is a value, and handing the
same one on beats re-loading it from a library every episode.

## 3. What is still missing

One rule, from the no-stand-ins decision (`git log -S'no stand-ins'`): **a gap is
refused with a sentence, never stood in for.**

Training is no longer a gap. The loop carries the memory, the run writes it at the
end (§2), `mix monty.run` does the same, and `:training_not_implemented` is gone.

Two debts remain. Neither is a refusal.

1. **A referee.** "It trains" must mean "it learned what Monty learned", for one
   config, checked like the evaluation ladder. Monty's own tests assert on
   `test/evidence_lm/*`, and those configs compose here. Their world is
   Habitat-Sim (§6). So the referee is either a config this build steps, or
   Monty's own numbers for a Habitat run — comparing the graphs, not the pictures.
2. **A loaded library is not the memory the config would build.** `Memory.read!/1`
   builds a plain `GraphMemory`, with no `k` and no thresholds. `Setup` hands it
   to the module instead of the `EvidenceGraphMemory` the config describes.
   Recognition is unaffected — matching reads the graphs. But training _on top of_
   a pretrained library would extend the wrong kind of model. Monty loads a state
   dict into the module it just built (`monty_experiment.py`). Copy that shape.

## 4. Order

1. A referee for one config this build steps _(§3.1)_.
2. Load a written memory into the memory the config would have built _(§3.2)_.
   Then let a later run find the library an earlier one wrote.

No porting order is needed. No shipped experiment is refused for a class this port
has not written; `mix monty.readiness` prints the counts.

## 5. Two traps, recorded so they are not re-learned

- **`detected_object` decides whether a training episode writes anything.**
  `update_ltm_from_stm/1` needs `FeatureAtLocationBuffer.size > 0` _and_ a
  `detected_object`; a timed-out module with no possible matches has none
  (`evidence_graph_lm.ex:1176-1190`), and the memory is left alone — Monty's own
  behaviour, not a bug. An episode that ends `:time_out` therefore teaches
  nothing, which is what makes the step budget part of the experiment rather than
  of the page.
- **A module id is whatever the config calls it** — `learning_module_0` in most
  shipped configs, `:lm_0` in the tests' hand-built specs. The memory map is keyed
  by the setup's ids (`Setup.learning_modules`), never by a name chosen at the
  call site.

## 6. The world this application cannot step

A handful of the shipped experiments name a world this build does not carry (`mix
monty.readiness` counts them; nine on 2026-11-16), and almost all of them are
Habitat-Sim: the scene is images another program rendered, the
config has no mesh to place, and the package exists only as a conda build for
another Python. `Setup.world/3` cannot step it, so a MuJoCo run of such a config
is refused at open time with `:world_not_carried` — an error, not a warning,
because the run cannot start at all:

> This experiment's world is HabitatEnvironment, which this application does not
> carry: only MuJoCo and the stand-in scene can be stepped here. Step the stand-in
> scene to run a config of its shape, or run one whose world this build has.

The stand-in scene is a real option in the page's selector, and choosing it turns
the refusal into the `:world_is_a_stand_in` warning: a run of that shape is
stepped, and its numbers are nobody's but this port's. That is the honest half of
what a Habitat config means here — the experiment's _wiring_ runs, its _scene_
does not.

## 7. What a memory has to be, before an inference can be judged by it

Measured 2026-11-17, on this box, with `priv/monty/libraries` read by
`MIX_ENV=test mix run --no-start /tmp/library_nodes.exs <dir>` — one record a
graph, so a library's node count is what a percept can be matched against.

| library | objects | nodes an object |
| --- | --- | --- |
| Monty's own `supervised_pre_training_5lms` (exported from its `model.pt`) | 10 | 2 668 … 376 |
| Monty's own `supervised_pre_training_10distinctobj_vocus2` | 10 | 1 253 … 531 |
| `trained/surf_agent_1lm_2obj_train` (a surface agent's own exploration) | 2 | ~1 500 |
| `trained/surf_agent_2obj_unsupervised` (2 episodes) | 2 | ~540 |
| `trained/dogs_surf_unsupervised` (8 dogs, one epoch of the surface agent) | 8 | 29 … 88 |
| `trained/dogs_supervised_pretraining_small` (8 dogs, one naive-scan epoch) | 8 | 9 … 41 |

The same inference, over two of those memories:

- **`tutorial/surf_agent_2obj_eval`, against the 1 500-node YCB memory: 6 of 6
  `match`, 599 steps** (~100 an episode) — the pipeline works.
- **`dogs/inference_supervised` and `dogs/inference`, against 20–88-node
  memories: 0 of 8 concluded, every episode `time_out`**, evidence around 2–5
  where the YCB memory reaches tens. Not a policy problem: the patch sees the
  dog, hypotheses are culled (4 296 → 136), and the evidence cannot climb because
  almost no percept has a node within `max_match_distance` of it.

So a recognition needs a memory of **hundreds of nodes an object**, and the
density of a supervised pretraining is `epochs × sensors`: Monty's
`supervised_pre_training_5lms` is fourteen rotations of five sensors, i.e. seventy
passes an object, and that is where its ~2 400 nodes come from. One epoch of one
sensor is one pass and ~20 nodes.

**Trap — `NaiveScan`'s `fixed_amount` is a step size in degrees, not a count.**
The spiral is `k * (k - 1) + 1` steps with `k = ceil(90 / fixed_amount)`
(`monty/experiment/recognition_strategy/naive_scan.ex`), so 5 is 307 steps and 50
is **3**: raising it shortens a pretraining rather than lengthening it.

## 8. Two defects found by running the pipeline, both fixed

- **A per-channel noise amount crashed the episode's stream.** Monty writes
  `noise_params: features: hsv: [0.1, 0.2, 0.2]` and NumPy **broadcasts** it over
  the draws; the port passed the list as a scalar standard deviation and
  `Random.Stream` died with `:erlang.*/2 bad argument` on the first step of
  `tutorial/surf_agent_2obj_eval`. `Monty.Random.Numpy.normals/4` now takes a
  scale a draw and spends the stream exactly as scalar draws do (pinned against
  numpy 1.23.5's own numbers in `numpy_test.exs`).
- **An empty memory was written as a library.** `Memory.save_all/4` writes one
  record a graph, so a memory holding none became a record-less file: a library
  that reads back as "there is a memory here", recognises nothing, and — filed
  under the name a previous run wrote — destroys that run's memory.
  `Learned.holding/2` is what both writers ask now, and a divided wave whose merge
  is empty answers `{:error, :nothing_learned}`.

## 9. Which of the two memories a run can be scored against

Both `dogs/inference` and `dogs/inference_supervised` read a library a run here
trained, and only one of them can be judged:

- **A supervised pretraining names each graph after the object it was told** —
  `milka`, `puppy`, … — so `graph_id_to_target` is the identity and a verdict can
  be `match`.
- **An unsupervised one names them `new_object0`, `new_object1`, …** (Monty's own
  naming) and keeps the true object in the module's `graph_id_to_target`; the
  library format holds objects, nodes and features, not that mapping, so a
  memory read back from `trained/` cannot say which dog `new_object3` was. Its
  recognition is still a recognition — one graph, one possible object — it just
  cannot be scored as correct. Monty's own unsupervised experiments are scored
  because they train and evaluate **in one run**, where the mapping is still in
  the module.

### The dog corpus, end to end (measured 2026-11-17)

The pipeline, on the eight-dog Objaverse corpus
(`priv/monty_experiments/conf/experiment/dogs/`):

1. **Train** — `dogs/supervised_pretraining`, Monty's
   `supervised_pre_training_base` with the corpus swapped: 14 rotations × 8 dogs
   = 112 training episodes, 34 384 steps, and a memory of **2 518 nodes** written
   as `trained/dogs_supervised_pretraining` (1 109 for the easiest dog, 124 for
   the hardest).
2. **Infer** — `dogs/inference_supervised`, Monty's
   `unsupervised_inference_distinctobj_dist_agent` with the corpus and the memory
   swapped: **8 of 8 episodes concluded `match`, 2 059 steps** (~257 an episode).

| episode | placed | concluded | evidence | nodes in that graph |
| --- | --- | --- | --- | --- |
| 1 | boykin_spaniel | boykin_spaniel | 31.3 | 298 |
| 2 | milka | milka | 2.3 | 1 109 |
| 3 | dog_free_fire | **milka** | 42.5 | 124 / 1 109 |
| 4 | kinder_guard_dog | **puppy_dog** | 14.1 | 125 / 240 |
| 5 | puppy_dog | puppy_dog | 8.3 | 240 |
| 6 | puppy | **boykin_spaniel** | 17.5 | 223 / 298 |
| 7 | smoothie_3d | smoothie_3d | 44.5 | 242 |
| 8 | dogs_head | dogs_head | 67.2 | 157 |

**Five of eight are right, and the three wrong ones are the three thinnest
graphs.** Which episode shows which object is not a guess: the interface answers
`Enum.at(object_names, rem(episode, n_objects))`
(`one_object_per_episode_interface.ex:167`).

Two things this taught, both Monty's own behaviour rather than the port's:

- **A `match` needs the pose, not the evidence.** Episode 2 concluded on evidence
  2.3: one object was left and the possible hypotheses agreed on a pose, and that
  is all `check_terminal_condition` asks. `object_evidence_threshold` gates the
  object a *time-out* reports (Monty's line 610), not a match, so raising it does
  not change a conclusion — measured: three runs with threshold 1, threshold 20
  and a twenty-step minimum evaluation are identical step for step.
- **A module that reads every hypothesis does not resolve a pose.** With
  `noresetevidence_1lm` (`evidence_threshold_config: all`, and a 100-matching-step
  cut-off) the same memory narrows to one dog and evidence 78 and stops: no
  conclusion in 8 of 8 episodes. With `evidence_tutorial_surf_agent_2obj` (top
  80 % only, `max_nneighbors: 10`) and a 500-step budget, every episode concludes.
  Which module a config names is part of the experiment.

The next step for the three missed dogs is the memory, not the module: the corpus
was scanned by one sensor in fourteen rotations, and Monty's own densities come
from five sensors (`supervised_pre_training_5lms`: 2 668 nodes for `mug`) or a
surface agent's thousands of steps (`surf_agent_1lm_2obj_train`: ~1 500).
### The unsupervised half, and the same config over two memories (measured 2026-11-17)

`dogs/surf_unsupervised` trains a surface agent on the corpus and evaluates in
the same run — Monty's own shape for unsupervised learning, where the
graph-to-target mapping is still in the module and a verdict can be scored.
Recorded, one epoch of eight episodes: 32 000 steps and a memory of **1 393
nodes over 4 objects** (487, 447, 297, 162), filed as
`trained/dogs_surf_unsupervised`. Its own training episodes ended `no_match` five
times — which is how a graph is born in training, not a failure.

The same inference, `dogs/inference`, over two memories of that corpus — so the
only thing that changed is the memory:

| memory | best evidence | steps | verdicts |
| --- | --- | --- | --- |
| 74 nodes an object (a run killed at step 1049 by the sensor's heap, §8) | 11.3 | 13 690 | 8 of 8 `time_out` |
| 348 nodes an object | **70.7**, 1 object possible | 9 345 | 8 of 8 `time_out` |

Density is worth six times the evidence and it narrows the field to one dog — and
still no episode concludes, because this config's module
(`noresetevidence_1lm_dod0025`, `evidence_threshold_config: all`) reads every
hypothesis and the episode is cut at a hundred matching steps. Over the
supervised memory, the same module reached evidence 78 with one object possible
and stopped in the same place, while `evidence_tutorial_surf_agent_2obj` (top
80 %, `max_nneighbors: 10`) concluded every episode. **The memory decides how
much evidence a percept can earn; the module decides whether an episode ever
concludes.**
