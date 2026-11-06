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

The rule is the one `7cba014` established: **a gap is refused with a sentence,
never stood in for.** Training is no longer a gap — the loop carries the memory —
so `:training_not_implemented` is gone and a config that trains is offered. What
is left is not a refusal but a debt: nothing yet proves the trained memory is the
one Monty would have built.

1. **A referee.** "It trains" has to mean "it learned what Monty learned" for some
   config, compared the way the evaluation ladder compares. The
   `test/evidence_lm/*` configs are the ones Monty's own tests assert on and they
   are composed here — but their world is Habitat-Sim (§6), so the referee has to
   be a config this build steps, or Monty's own numbers for one of its Habitat runs
   taken as the reference while the graphs are compared rather than the pictures.
2. **What was learned has to survive the run** _(done)_: `Memory.save/4` writes a
   memory in the format `load/3` reads, and a run with a training phase writes
   each module's memory to `<artifacts>/<run>/memory/trained/<name>.jsonl.gz`
   when it ends — Monty's `save_state_dir/1`, in this port's format. The round
   trip is specified by `test/monty/studio/memory_test.exs` (the same objects,
   every node in the same place with the same features) and end to end by
   `test/monty/studio/jobs/run_test.exs` (a training episode's memory is on disk
   afterwards and names `new_object0`).
3. **A loaded library is not the memory the config would build.**
   `Memory.read!/1` builds a plain `GraphMemory` with `GraphObjectModel` and no
   `k`/thresholds, and `Setup` hands that to the module in place of the empty
   `EvidenceGraphMemory` the config's own numbers would have built. Recognition is
   unaffected — matching reads the graphs — but a config that trains _on top of_ a
   pretrained library would extend it with the wrong kind of model. Monty loads a
   state dict into the module it has just built (`monty_experiment.py`), which is
   the shape worth copying.
4. **`Mix.Tasks.Monty.Run` has its own loop.** It steps an episode at a time and
   neither writes the episode into memory nor carries it to the next one, so
   `mix monty.run` trains differently from the page. It has to take the same
   hand-off.
5. **The other 170 refusals.** Of the 210 shipped experiments, 170 are refused in a
   MuJoCo run: 80 for classes this port has not written (`DisplacementGraphLM`
   alone is 44 of them, `FeatureGraphLM` 10, `TwoDSensorModule` with
   `DefaultAttentionSystem` 10, `MontySupervisedObjectPretrainingExperiment` 11,
   `SaccadeOnImage*` 7, `MontyBase` 3, `MontyForNoResetEvidenceGraphMatching` 3,
   `Omniglot*` 2) and 83 because their world is Habitat-Sim, which this
   application does not carry (§6).

## 4. The order worth following

1. Carry the memory through a phase _(done: §2)_ and lift the guard _(done)_.
2. A referee for one config this build steps _(§3.1)_.
3. Load a written memory into the memory the config itself would have built
   _(§3.3)_, and give a later run a way to find the library an earlier one wrote.
4. `Mix.Tasks.Monty.Run`'s own loop _(§3.4)_.
5. Port what the catalog is missing, biggest first: `DisplacementGraphLM` (44),
   `MontySupervisedObjectPretrainingExperiment` (11), `FeatureGraphLM` (10), the
   cows image family (`TwoDSensorModule`, `DefaultAttentionSystem`, 10), the
   saccade environments (7), then `MontyBase`, the no-reset learning module and
   Omniglot (8) _(§3.5)_.

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

83 of the 210 shipped experiments name a world this build does not carry. Almost
all of them are Habitat-Sim: the scene is images another program rendered, the
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
