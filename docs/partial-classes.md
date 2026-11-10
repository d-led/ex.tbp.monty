# What a partly ported class is, and which ones there are

The module map answers one question per class of Monty's tree: does this
application have it. Three answers were enough while every module was either
here, not here yet, or replaced on purpose:

| status        | meaning                                                |
| ------------- | ------------------------------------------------------ |
| `implemented` | Monty's class is ported whole                          |
| `planned`     | this application owes the class and has not written it |
| `excluded`    | it will never have it, and something else does the job |

There is a fourth case, and it was previously told as `implemented`: a class
that **is** here, that a config **can** name, whose behaviour is only as much of
Monty's as anything here needs. Saying `implemented` of it overstates the port;
saying `planned` would understate it and would make its experiments read as
unrunnable. So:

| status    | meaning                                                                |
| --------- | ---------------------------------------------------------------------- |
| `partial` | the module exists and runs; Monty's behaviour it lacks is written down |

`partial` is a claim that has to be checked, so it is a claim with an argument
attached. `mix monty.module_map.verify` fails a `partial` entry or class that
has no `reason`, exactly as it fails an unexplained exclusion, and
`docs/partial-classes.md` — this page — holds the full argument for each one.

A partial class is **written**, not missing, in every place that asks: a config
naming one still builds, `ported/1` counts it, `Monty.ModuleMap.written?/1` is
the predicate all of those ask, and a partial module's test link still points at
its test.

## The four there are

**`FeatureGraphLM`** (`frameworks/models/feature_location_matching/feature_graph_lm.py`)
— the feature-location model matches and votes, but two things it also does are
not here:

- **Votes are negative only.** Monty's feature module also votes on the locations
  and rotations it still considers, and prunes its paths with the other modules'
  such votes. This port routes one kind of vote — the objects a module has ruled
  out — so a feature module votes like the rest and does no location pruning.
  Monty's own comment on that path says it is not being developed further.
- **Poses are not jittered.** Monty samples `n_samples` rotations around each
  aligned pose with `ctx.rng.vonmises`; the only caller passes zero, so the
  sampling was not ported. A config asking for it would need the RNG threaded
  into a place that has no such parameter today.

**`SurfaceNormalMethod`** (`frameworks/models/sensor_modules.py`) — only total
least squares is written. `new("OLS")` and the naive method Monty also accepts
raise rather than silently estimating normals another way. No config this
application runs asks for them; the refusal is loud so that one which did would
not read as a result.

**`HypothesesDisplacer`** (`frameworks/models/evidence_matching/hypotheses_displacer.py`)
— the object-orientation channel's evidence is computed
(`object_pose_evidence/2`, the trace of the relative rotation) but never
dispatched: Monty chooses between the location and orientation calculations by
an `isinstance` check on the hypothesis, and this port's hypotheses are one
shape. `docs/monty-differences.md` §2.21 has the arithmetic and why it is not
wired.

**`BasicGraphMatchingLogger`** (`frameworks/loggers/graph_matching_loggers/`)
— every numeric and per-learning-module figure is computed exactly as Monty
computes it, and the statistics files are the same files. What is missing is
`wandb.Histogram` values: wandb's own type, built only when a run has more than
one learning module, carrying distributions this module already keeps as lists.
The wandb handlers are excluded anyway, so the values would have nowhere to go.

## How the list was found, and how to find the next one

The sweep that produced these four, in the order that is worth repeating:

1. **The code's own admissions.** Every `raise` and every `@moduledoc` that says
   "not ported", "only … is", or "would need" is a class saying it is partial.
   That is where all four came from, and it is the only signal that cannot produce
   a false positive, because the module is describing itself.
2. **A method-count difference against Monty.** For each implemented class, the
   number of functions in its Elixir module against the number of methods in the
   Python class. It found eight, of which four were false positives and are worth
   knowing about:
   - **contracts** — `AttentionSystem`, `LearningModule`, `SensorModule`,
     `HypothesesUpdater`, `MotorPolicy`, `Snapshotable`, `PerceptFilter`,
     `PositioningProcedure` and friends are `Protocol`s or abstract classes in
     Monty. Here they are behaviours: `@callback` is the port of an abstract
     method, so a module with callbacks and no `def` is not short, it is the
     contract.
   - **inheritance** — `EvidenceGraphMemory` subclasses `GraphMemory`, so the
     methods it appears to lack are in the parent, and both are one struct here
     (`docs/monty-differences.md` §2.9).
   - **generated functions** — `BaseMontyLogger` and `LoggingCallbackHandler`
     define their eight events in a `for` comprehension, which a `def` count does
     not see.
   - **deliberate rewrites** — `MuJoCoSimulator` and `MontyExperiment` are
     counted as short because their Python methods are not where the port does
     the same work: the scene is `priv/monty_py/world.py`, the experiment's loops
     are `Monty.Studio.Run`, the step loop is `Monty.Runtime.Step`. Their
     moduledocs say so; a count cannot.
3. **What is still unjudged.** `MontyForGraphMatching` defines two functions where
   Monty's class defines thirteen, because the vote round is what is left of it
   after the message passing moved to `Monty.Runtime.Step` — the moduledoc says
   the arithmetic is what the port owes and the rest is the runtime's. That reads
   as a fourth deliberate rewrite rather than a shortfall, and it is left
   `implemented` on that reading: the next person to audit should either confirm
   it here or move it to `partial` with the vote machinery named.

## Changing one

A decision survives regeneration, the way an exclusion does:

```elixir
%{
  reason: "the location/rotation votes a feature module also sends are not ported",
  status: :partial,
  file: "packages/ex_tbp_monty_core/lib/monty/frameworks/models/…/feature_graph_lm.ex",
  elixir: "Monty.Frameworks.Models.FeatureLocationMatching.FeatureGraphLM",
  python: "FeatureGraphLM"
}
```

`mix monty.module_map.gen` carries `partial_classes` and a module-level
`:partial` through, `mix monty.module_map.verify` refuses one without a reason,
and this page gains the paragraph that explains it. A partial port that later
grows whole becomes `:implemented` by itself: the generator recomputes every
status that is not a decision, so removing the `:partial` mark and regenerating
is all it takes.
