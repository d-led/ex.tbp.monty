# Training: what exists, what is missing, and the order to do it in

Written 2026-11-06, after the port finished a full evaluation run and the crash
that used to end one. Every claim here is a file and a line, or a command whose
output is quoted.

**The state in one sentence**: the runtime can train an episode and Monty's
learning code is ported, but the studio's loop is an _evaluation_ loop — one
model per episode, nothing carried between them — so a run that trains would
explore and forget in the same breath, which is why
`Setup.phase_findings/1` refuses one.

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
- **38 of the 210 shipped experiments are blocked by nothing but the missing
  loop** — every one of them composes, has its classes ported and has its memory,
  and fails only with `:training_not_implemented`. They are the
  `test/evidence_lm/*` family (30 of them, and Monty's own tests are their
  referee), `surf_agent_unsupervised_{10distinctobj,10distinctobj_noise,10simobj}`,
  `test/hierarchy/two_lms_heterarchy(+_mujoco)`,
  `test/policy/dist_hypo_driven_multi_lm(+_mujoco)` and
  `tutorial/surf_agent_2obj_unsupervised`. Re-derive the list with:

  ```
  mix run -e 'for %{name: n} <- Monty.Studio.Catalog.experiments() do
    {:ok, o} = Monty.Studio.open(n)
    if o.setup.findings |> Enum.filter(&(&1.level == :error)) |> Enum.map(& &1.code) |> Enum.uniq() == [:training_not_implemented], do: IO.puts(n)
  end'
  ```

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
(`docs/speed.md`). So an *evaluation* phase neither writes the episode nor reads
the memory back; it keeps the value it started with. That is also the cheaper
shape for the erlang side of the house: the memory is a value, and handing the
same one on beats re-loading it from a library every episode.

## 3. What is still missing before the guard may be lifted

The rule is the one `7cba014` established: **a gap is refused with a sentence,
never stood in for.** So `:training_not_implemented` stays until the list below
is empty for a config, and then it becomes a finding about _that_ config.

1. **What was learned has to survive the run.** Today the memory lives in the
   learning module's process and dies with it, which is fine for an episode and
   useless for a training run: a `train` phase that ends leaves no library, so
   the evaluation phase after it — and the next run — start from the pretrained
   graphs again. Monty writes pickles (`_snapshot_monty`, `memory_to_pickles`);
   here the equivalent is the library format
   `Monty.Studio.Memory` already _reads_ (`priv/monty/libraries/<release>/<model>.jsonl.gz`,
   written by `Monty.Studio.Pretrained`), so a writer is the missing half.
2. **A referee.** "It trains" means "it learned what Monty learned" for some
   config, compared the way the evaluation ladder compares: the
   `test/evidence_lm/*` configs are the ones Monty's own tests assert on, and they
   are already composed here. Until one of them produces Monty's numbers, the
   guard is right.
3. **Then the guard, per config.** `phase_findings/1` is a function of the setup,
   so it can answer "this config trains and this build can carry it" instead of
   refusing every training config — but only after 1 and 2 hold for that config.

One more place has its own loop and its own copy of this gap:
`Mix.Tasks.Monty.Run` steps an episode at a time too, and neither writes the
episode into memory nor carries it to the next one. It is behind the same guard,
so nothing there is wrong today — but the memory hand-off has to reach it before
the guard moves, or `mix monty.run` would train differently from the page.

## 4. The order worth following

1. Carry the memory through a phase _(done: §2)_ and prove it through
   `Jobs.Run`, once a training config is allowed far enough to run.
2. Write a trained memory out as a library, and read it back into the next phase
   — one round trip, tested against the same memory.
3. Take one `test/evidence_lm/*` config whose classes are all ported, run its
   train + evaluate plan, and compare against Monty's own recording of it.
4. Only then: replace `:training_not_implemented` with a finding that names what
   a _particular_ config still cannot do.

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
