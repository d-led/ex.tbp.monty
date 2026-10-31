# Open ends

Everything the Thousand Brains Project and its forum have said is **not done yet**,
harvested 2026-10-31 from three places:

- `monty-orig/docs/future-work/` — 94 roadmap tasks (57 open · 12 evergreen · 7 paused ·
  3 scoping · 4 in progress · 11 done)
- the published docs — [the roadmap](https://docs.thousandbrains.org/docs/project-roadmap)
  plus all 178 task and reference pages it links to
- the forum — 566 topics and 3,073 posts, in the team's own words rather than a summary

Nothing here is a plan. It is a **menu**. Every line has a number, a size and a
*first move*, so you never have to hold a whole project in your head at once.

> **60-second version:** skim the table, take the line that makes you curious, do its
> first move. Decide after fifteen minutes, not before.

Sizes: 🍬 = minutes to an hour · 🍪 = an afternoon · 🎂 = weeks or more.

---

## Start here — twelve openings

| # | Opening | Size | First move |
| --- | --- | --- | --- |
| [1](#a-platform-plumbing--tristans-future-reality-tree) | Telemetry pipeline replacing the logging framework | 🎂 | Read threads [1014](https://forum.thousandbrains.org/t/what-monty-features-or-injections-to-work-on-next/1014) and [1076](https://forum.thousandbrains.org/t/333-telemetry-collection-is-configurable-down-to-the-python-module-level/1076), sketch `telemetry.snapshot/1` |
| [4](#a-platform-plumbing--tristans-future-reality-tree) | Coordinate transforms easy to use | 🍪 | Find every raw quaternion multiply in the port |
| [6](#a-platform-plumbing--tristans-future-reality-tree) | `State` in the CMP | 🍬 | Open [include-state-in-cmp](https://docs.thousandbrains.org/docs/include-state-in-cmp) — the page is six lines |
| [12](#c-sensors-and-senses) | Additional methods for depth perception | 🍪 | Compare two cheap depth estimators on one episode |
| [20](#c-sensors-and-senses) | Touch properties in MuJoCo | 🎂 | Niels asked for it by name — start from his reply in [1218](https://forum.thousandbrains.org/t/thoughts-after-monkeying-around-with-monty/1218) |
| [21](#d-learning-modules) | Reliable poses for symmetric objects | 🎂 | Viviane's in-progress design: her two posts in [1165](https://forum.thousandbrains.org/t/could-exact-pose-matching-be-a-bottleneck-for-compositional-generalization/1165) |
| [25](#d-learning-modules) | Event detection to reset the timer | 🍪 | Beginner-friendly roadmap task, no RFC needed |
| [32](#e-compositional-objects-and-continual-learning) | Global-first recognition of compositional objects | 🎂 | Daniel's five steps in [1204](https://forum.thousandbrains.org/t/from-single-parts-to-compositional-objects-the-whole-first-then-the-details/1204) |
| [34](#e-compositional-objects-and-continual-learning) | A continual-learning loop that repairs itself | 🎂 | A PR is promised — check GitHub before rebuilding it |
| [50](#g-theory-and-measurement) | Formal verification of the core | 🍬 to read | [1050](https://forum.thousandbrains.org/t/developments-with-formal-verification/1050) — nobody has picked it up |
| [53](#h-community-docs-and-reaching-people) | Turn recurring forum questions into docs | 🍬 | Ask MemPalace which questions repeat |
| [57](#h-community-docs-and-reaching-people) | Organise a local meetup | 🍬 | Evergreen roadmap task |

---

## A. Platform plumbing — Tristan's Future Reality Tree

Tristan Slominski publishes a *Current Reality Tree* (the problems, ~40 numbered
undesirable effects) and a *Future Reality Tree* (desired effects plus
**injections** — the actions that get you there). The injections are a public
project list, and he updates it in-thread whenever one lands.

- [776 Platform Current Reality Tree](https://forum.thousandbrains.org/t/platform-current-reality-tree/776)
- [818 Platform Future Reality Tree](https://forum.thousandbrains.org/t/platform-future-reality-tree/818)

- [ ] **1 · Telemetry pipeline.** Replace `graph_matching_loggers` with a
      `logging`-shaped `telemetry.snapshot(...)` that emits inline instead of at
      hardcoded step/episode/epoch boundaries. *Injection #81 → Desired Effect 333.*
      🎂 Needs an RFC, and Tristan wants it split so no dead code merges.
      Here: `Monty.Studio.Logging` already resolves handlers from config, so a
      `snapshot/1` handler is the smallest honest prototype.
- [ ] **2 · Sensor modules as a transformation pipeline.** Two sequential
      injections (#95 refactor all sensor-module functionality into reusable
      transforms, #96 compose modules from them), so that a new sensor module is
      "only the necessary and sufficient code". RFC #1005 in the monty repo.
      *Desired Effect 381.* 🎂
- [ ] **3 · Remove the Monty inheritance hierarchy.** *Injection #10 → DE 246
      "platform code is ignorant of experiments".* 🍪 The port has no inheritance
      to delete — but it has the same question in another shape: which behaviour
      in `Monty.Runtime.*` is really an algorithm that belongs in a pure module?
- [ ] **4 · Coordinate transforms easy to use.** *DE 260.* 🍪 Open question
      Tristan raised against his own design: does this also fix the quaternion
      convention? Answer so far: no — motor policies use quaternions directly,
      outside reference-frame context.
- [ ] **5 · CMP: separate location and feature messages.**
      [separate-location-and-feature-messages-in-cmp](https://docs.thousandbrains.org/docs/separate-location-and-feature-messages-in-cmp) · 🍪 to scope, large to do
- [ ] **6 · `State` in the CMP.**
      [include-state-in-cmp](https://docs.thousandbrains.org/docs/include-state-in-cmp) ·
      🍬 the only small task in the hierarchy area
- [ ] **7 · Global interval timer.**
      [global-interval-timer](https://docs.thousandbrains.org/docs/global-interval-timer) ·
      🍪 beginner-friendly
- [ ] **8 · Extend percept filtering to LM-to-LM messages.**
      [extend-percept-filtering-to-lm-to-lm-messages](https://docs.thousandbrains.org/docs/extend-percept-filtering-to-lm-to-lm-messages) · 🍪

**Design change to know about (2026-10-27):** desired effect 321 ("Experiment can
execute the Platform main loop") was **removed**. A platform runtime and an
experiment are now *swappable peers* in front of Monty and the environment.
Anything built on the old assumption is stale.

## B. Seeing inside

- [ ] **9 · Improve `tbp.plot` during learning and inference.** Evergreen, medium,
      skills `python, visualizations`. 🍪
- [ ] **10 · Profile and speed up Monty.** Evergreen, open-ended; pairs with "find
      a faster alternative to KDTree search", which is *paused*. 🎂
- [ ] **11 · More W&B logging for unsupervised learning.** Roadmap open. In this
      port it is the next logging milestone: `WandbWrapper` + `from_config/1`,
      plus the `mark_obs` decision ("Monty's exact marked image, or our own
      rendering?"). 🍪

## C. Sensors and senses

Six sensor-module tasks are open; Niels' September update names *depth perception* and
the *1-D module* explicitly. Each line below is the task page's own idea, compressed.

- [ ] **12 · Additional methods for depth perception.** Monty leans on depth for patch
      motion and for 3D features, but real cameras often have none, and depth cameras
      fail in sunlight and on reflective surfaces. 🍪
      Try: sensorimotor cues rather than a depth camera — parallax, convergence,
      accommodation, relative motion. The page links a talk and a discussion of how
      they combine. [page](https://docs.thousandbrains.org/docs/additional-methods-for-depth-perception)
- [ ] **13 · One-dimensional sensor module.** Project movement into 1D along the
      principal curvature, so a cable or a shirt is travel along one axis. 🍪
      Needs a policy that follows the curve and moves smoothly — random jumps break it.
      [page](https://docs.thousandbrains.org/docs/one-d-sensor-module)
- [ ] **14 · Change-detecting sensor module.** Emit a CMP message when something changes
      locally: location, direction of the change, features (edge moving vs curve). 🎂
      Only *local* change counts — global change means the sensor moved — and 3D motion
      estimated from a 2D depth image will be noisy.
      [page](https://docs.thousandbrains.org/docs/change-detecting-sm)
- [ ] **15 · Detect local and global flow.** Two sources: a small receptive field shows
      the object moving, a large one shows the sensor moving. Flow can be optical or
      texture-based, so touch works too. 🍪 Needed before behaviours, and before the
      motor system's self-motion can be trusted.
      [page](https://docs.thousandbrains.org/docs/detect-local-and-global-flow)
- [ ] **16 · Alternative segmentation strategies.** One strategy exists — `SlicMerge`,
      SLIC superpixels grown by mean LAB colour — and its two failures are documented:
      it bleeds onto a wall of similar colour, and it cannot keep a text-heavy logo
      whole. 🍪 Directions the page gives: 3D surface continuity, texture statistics,
      top-down bias, motion and parallax.
      [page](https://docs.thousandbrains.org/docs/explore-alternative-segmentation-strategies)
- [ ] **17 · Extract better features.** Today's non-morphological features are close to
      "the RGB value at the centre of the patch". The page lists the invariances any
      replacement must hold: instance, rotation, mild scale, lighting, viewpoint, blur,
      novelty. 🍪 Local binary patterns were tried and did not help — probably the
      viewpoint term — but may still suit touch.
      [page](https://docs.thousandbrains.org/docs/extract-better-features)
- [ ] **18 · Universal sensor module.** One module that extracts CMP features whatever
      the modality or dimensionality, on the bet that centre-surround responses are what
      defines an edge in vision, touch and sound alike. 🎂
      The acceptance test is concrete: it must recover the features the current 2D and
      3D modules and the ultrasound pipeline already produce.
      [page](https://docs.thousandbrains.org/docs/universal-sm-for-morphological-feature-extraction)
      (*Surface SM*, the sibling task, is already **completed**.)

From the forum:

- [ ] **19 · Only add a sense that fails differently.** Bryan Leavelle's rules, laid
      out in [1218](https://forum.thousandbrains.org/t/thoughts-after-monkeying-around-with-monty/1218):
      *"does it fail where the others fail? if it does, it's one witness counted
      twice."* Audio already works — see
      [1193](https://forum.thousandbrains.org/t/monty-can-hear-now-lyon-s-cochlea-sai-learning-module-melodies-as-graphs-transposition-invariance-falls-out/1193). 🍬 to read
- [ ] **20 · Touch: force, compliance, friction, vibration, heat.** Niels: *"any
      work adding touch-modality properties like texture/force to the MuJoCo
      pipeline would be very welcome"* — with the caveat that the YCB dataset
      would need updating or replacing. 🎂

## D. Learning modules

The roadmap area is `learning-module-improvements` — 29 tasks, five already done. These
are the ones whose summary does not fit in a title.

- [ ] **21 · Improve handling of symmetry.** Detect symmetry, keep one hypothesis of the
      ring, mark the rest so they are never initialised again. 🎂
      Viviane names two open issues (2026-08-28): the sensed pose is not fully
      deterministic, and each symmetry type needs its own number of hypotheses per
      location. [page](https://docs.thousandbrains.org/docs/improve-handling-of-symmetry) ·
      [her posts](https://forum.thousandbrains.org/t/could-exact-pose-matching-be-a-bottleneck-for-compositional-generalization/1165)
- [ ] **22 · Deal with incomplete models.** "A part that nothing competes with is never
      filled in" — a model can pass its own self-check while most of an object was
      never seen. 🍪 The fix worth copying is Daniel's (see 33).
      [page](https://docs.thousandbrains.org/docs/deal-with-incomplete-models)
- [ ] **23 · Model repeating patterns.** Bed-sheet or carpet patterns sit between a
      structured object and a raw sensor feature: too structured for a sensor module,
      and today the pattern has to be learned over and over. 🎂
      [page](https://docs.thousandbrains.org/docs/model-repeating-patterns)
- [ ] **24 · Learning and forgetting speed parameter.** Every module learns
      instantaneously today, but a hierarchy needs both: a fast representation of the
      current room that can be thrown away, and stable models that must not drift.
      🎂 RFC first. [page](https://docs.thousandbrains.org/docs/learning-and-forgetting-speed-parameter)
- [ ] **25 · Event detection to reset the timer.** One module recognising a significant
      event — a new note, a canonical object state, a large feature change — resets a
      semi-global interval timer shared by many modules. 🍪 beginner-friendly.
      [page](https://docs.thousandbrains.org/docs/event-detection-to-reset-timer)
- [ ] **26 · Sample offspring hypotheses.** Sample around the current best hypotheses
      instead of starting from scratch, so promising poses get refined the way a
      particle filter refines its particles. 🍪
      [page](https://docs.thousandbrains.org/docs/sample-offspring-hypotheses)
- [ ] **27 · Learn hot spots on objects.** The points that would disambiguate two
      similar objects are expensive to compute, so store them with the model and reuse
      them next time. 🍪 beginner-friendly.
      [page](https://docs.thousandbrains.org/docs/learn-hot-spots-on-objects)
- [ ] **28 · Merge input channels in learned graphs.** The hypothesis space is already
      shared across channels (PR 851); the stored graphs are still one per channel per
      object. 🎂 RFC first.
      [page](https://docs.thousandbrains.org/docs/merge-input-channels-in-learned-graphs)
- [ ] **29 · Support scale invariance.** Recognise an object at a scale it was never
      learned at. 🎂 Companion talk: the 2026/09 video discussion
      [1232](https://forum.thousandbrains.org/t/2026-09-ideas-around-implementing-scale-invariance-in-monty/1232)
- [ ] **30 · Vote on state.** A hypothesis that includes state *A* should only add
      evidence for state *A* of the object. 🍪 the only voting item that fits in an
      afternoon. [page](https://docs.thousandbrains.org/docs/vote-on-state)
- [ ] **31 · Clean up and simplify voting.** The vote code is nested; comparing
      hypothesised orientations first would skip most of the K-D tree searches that
      dominate its cost. 🍪 a refactor with a metric attached.
      [page](https://docs.thousandbrains.org/docs/clean-up-and-simplify-voting)

## E. Compositional objects and continual learning

This is where the community is furthest ahead of the code.

- [ ] **32 · Global-first recognition.** Daniel Wu's five steps in
      [1204](https://forum.thousandbrains.org/t/from-single-parts-to-compositional-objects-the-whole-first-then-the-details/1204):
      (1) how far does whole shape alone narrow the candidates, (2) put that
      candidate list into recognition, (3) look where the top two differ most,
      (4) "new" = every candidate ruled out, split off the unseen part, (5) learn
      while recognising. Numbers so far: top-5 87→95%, but top-3 stuck at 79%
      because of one cube-base family. 🎂
- [ ] **33 · "Nothing left unseen" instead of "not confused" as the definition of
      learned enough.** Daniel's fix for incomplete records: 7 of 23 objects were
      incomplete, afterwards 1 of 23. Cost: 62 s median first learning. 🍪 to copy
- [ ] **34 · A continual-learning loop that repairs itself.**
      [1192](https://forum.thousandbrains.org/t/from-zero-labels-to-42-42-an-unsupervised-continual-learning-loop-on-14-geometric-parts/1192):
      42/42 with zero labels in 104 minutes. Mechanisms: write-when-confident,
      targeted write-in, trusted-band write gate, sentinel checks, plateau
      termination. **A PR is promised** — check before rebuilding. 🎂
- [ ] **35 · Learn roughly, then look closer only after a mistake.** Daniel's
      hypothesis that continual learning needs *a little* external feedback rather
      than full supervision. No code yet; cheap to test. 🍪
- [ ] **36 · Compositional dataset and metrics.**
      [make-dataset-to-test-compositional-objects](https://docs.thousandbrains.org/docs/make-dataset-to-test-compositional-objects) ·
      🎂 evergreen; Niels' September update asks for "a larger dataset of objects
      with 2D + 3D compositional arrangements"
- [ ] **37 · Send class id or similarity-encoding id in compositional
      experiments.** 🍪 beginner-friendly
- [ ] **38 · Read "How compositional models will work in Monty"** before touching
      32–37: [1124](https://forum.thousandbrains.org/t/how-compositional-models-will-work-in-monty/1124). 🍬

## F. Motor system and attention

- [ ] **39 · Model-free distant-agent exploration policy.** Start from the salience
      map — saccade to salient regions, let that salience decay — and with no model
      signals left fall back to a systematic sweep. 🍪 beginner-friendly.
      [page](https://docs.thousandbrains.org/docs/model-free-distant-agent-exploration-policy)
- [ ] **40 · Model-based exploration policy.** Let the learning modules aim the sensor
      at the frontier of what they know: the edge of a model whose points have few
      neighbours. Thin objects look like frontier everywhere, so the heuristic needs a
      guard. 🎂 [page](https://docs.thousandbrains.org/docs/model-based-exploration-policy)
- [ ] **41 · Policy to quickly move to a new object.** Once something is recognised,
      leave it: mix a salience map with a higher module's knowledge of how sub-objects
      relate. 🍪 → 🎂
      [page](https://docs.thousandbrains.org/docs/policy-to-quickly-move-to-a-new-object)
- [ ] **42 · Switching between learning- and inference-focused policies.** Today a
      system cannot move from a naive scan to a targeted search, though the modules
      know whether they are matching or exploring. 🍪 Scope first — the page says the
      item may belong with the LM goal generator rather than the motor system.
      [page](https://docs.thousandbrains.org/docs/implement-switching-between-learning-and-inference-focused-policies)
- [ ] **43 · Theory for decomposing goals into subgoals.** *Scoping* — a theory
      page, not code. 🍪
- [ ] **44 · Outline how to apply attention.**
      [outline-how-to-apply-attention](https://docs.thousandbrains.org/docs/outline-how-to-apply-attention) ·
      🍪 *scoping*, but the thread already holds the mechanism: Daniel reads Niels'
      2026 note on attention as "attention spreads from broad to narrow" (1204).
- [ ] **45 · Multi-agent infrastructure.** One agent could be a hand whose fingers move
      semi-independently while a distant agent saccades over the same object — and
      sometimes both look at one place, which is what voting still needs while its
      connections are being learned. 🎂
      [page](https://docs.thousandbrains.org/docs/add-infrastructure-for-multiple-agents-that-move-independently)

*In progress, don't start:* GPU support, configs easier to use, models with fewer
points, RL policy in a simplified action space — read the design notes, don't
duplicate the work.

## G. Theory and measurement

- [ ] **46 · Measurement-first tools for "seeing" the cortex.**
      [1154](https://forum.thousandbrains.org/t/we-need-better-tools-to-see-the-cortex-a-measurement-first-path/1154):
      what would we measure to know a column is doing its job? 🍪
- [ ] **47 · AATM — can identity emerge from coalitions of partial
      representations?** Thirty posts, the third-longest thread of 2026, and the one
      where the vocabulary gets argued over most carefully:
      [1146](https://forum.thousandbrains.org/t/aatm-can-object-identity-emerge-from-continuous-coalitions-of-partial-sensorimotor-representations/1146). 🎂
- [ ] **48 · Voting on real data — what makes a good witness?**
      [1160](https://forum.thousandbrains.org/t/voting-on-real-data-1-why-my-naive-committee-failed-and-what-i-think-a-good-witness-needs/1160).
      The published answer: voting buys *speed*, not accuracy, and only when
      sensors do not overlap. 🍪
- [ ] **49 · Where does a new sense really help?** The "zero-shot on BOP YCB-V"
      and "recognition through movement" threads
      ([1157](https://forum.thousandbrains.org/t/running-monty-zero-shot-on-real-rgb-d-data-bop-ycb-v-what-breaks-and-what-cheap-fixes-buy/1157),
      [1158](https://forum.thousandbrains.org/t/recognition-through-movement-on-real-rgb-d-data-what-one-moving-sensor-buys-and-the-failure-it-introduces/1158)) —
      a dataset of failures waiting to be turned into fixes. 🍪
- [ ] **50 · Formal verification of the core.**
      [1050](https://forum.thousandbrains.org/t/developments-with-formal-verification/1050):
      object manifolds, Lie-group actions, belief states as measures, sheaf-theoretic
      voting — in Lean. Nobody has picked it up. 🎂
- [ ] **51 · Text, language and interpretability.**
      [1055](https://forum.thousandbrains.org/t/text-language-and-interpretability-in-monty/1055). 🍪
- [ ] **52 · Egocentric models of local space from retinal input.**
      [368](https://forum.thousandbrains.org/t/building-egocentric-models-of-local-space-from-retinal-input/368) —
      a reading task before it is a coding task. 🍬

## H. Community, docs, and reaching people

- [ ] **53 · Find recurring forum questions and fix the docs.** Evergreen; start by
      asking MemPalace which questions repeat, then open one docs PR. 🍬
- [ ] **54 · Build a tutorial.** Evergreen, video + writing. 🍪
- [ ] **55 · Insert glossary terms into the docs.** 🍬 small, open
- [ ] **56 · Auto-display contributors in the README.** 🍬 small, open
- [ ] **57 · Organise a local meetup.** 🍬 small, evergreen
- [ ] **58 · Better documentation platform.** 🎂 large, open
- [ ] **59 · Better website platform.** 🎂 large, open
- [ ] **60 · Condensed videos about the project.** 🍪 evergreen — and the forum has
      a standing "All the Shorts!" thread for exactly this

---

## Open questions — no plan yet

The roadmap itself says it is not exhaustive: *"There are many topics where we are
still actively brainstorming."* The unshaped ones live on
[open-questions](https://docs.thousandbrains.org/docs/open-questions), and they are the
cheapest thing to be curious about, because nobody has spent a week on them yet.

- **Scale** — how is an object recognised irrespective of its scale, and how is its
  scale known?
- **Cross-modal transfer** — how can one learn an object by sight and recognise it by
  touch, without rewiring sensor→learning-module connections?
- **Memory** — how do consolidation and forgetting actually work?
- **Object boundaries** — where does an object begin and end, and what makes something
  a sub-component?
- **Physics** — where is the model of general physics: does every learning module learn
  the physics its objects need, or are some modules specialised?
- **Goals** — how are goals decomposed into sub-goals, how are they defined and
  communicated, and how does the motor system choose among the goals many modules
  produce?
- **Routing** — what is the routing mechanism, and where does attention enter it?
- **Voting** — can we assume models of the same object in different modules were
  learned in the same reference frame?

Longer thinking lives in the [Excalidraw board](https://link.excalidraw.com/readonly/9iANwzrO9EdPxJpCE5LS)
and in the brainstorming videos on the
[project's YouTube channel](https://www.youtube.com/@thousandbrainsproject). A legacy
planning spreadsheet still exists and is being phased out in favour of the roadmap page.

## Parked — don't start these

- **Paused (7):** re-anchor hypotheses · use off-object observations · use
  out-of-model movements · improve bounded-evidence performance · object behaviour
  test bed · faster-than-KDTree search · evaluate on Omniglot
- **In progress (4):** GPU support · configs easier to use · models with fewer
  points · RL policy
- **Won't do:** build HabitatSim from source (Tristan, 2026-10-27). Desired
  effect 321 dropped.
- **Scoping (3):** goals → subgoals theory · attention outline · recognise before
  moving on

## Already done — don't rebuild

Tristan closes desired effects in-thread, so the tree is not a wish list:

- WXYZ-only quaternions, via a `Rotation` wrapper (May 2026 — not the Python upgrade)
- unit tests fast: 591 tests in ~20 s (Q1 2026)
- motor system and policies decoupled from `EnvironmentInterface`
- learning modules free of episode time quantisation
- `MontyForGraphMatching` decoupled from a specific motor policy
- running an experiment from outside `tbp.monty`, documented (~May 2026)
- Experiment and Platform free of Dataset and Dataloader
- Surface SM · particle-filter-like resampling · dynamic hypothesis-space size
- the Future Work widget

---

## Where these land in this port

| Opening | What it means here |
| --- | --- |
| 1 telemetry | `Monty.Studio.Logging` already builds handlers from config; a `snapshot/1` handler is the prototype |
| 2 sensor pipeline | 8 sensor modules, no shared transforms — the RFC applies almost verbatim |
| 3 no inheritance | nothing to delete; ask instead which `Monty.Runtime.*` behaviour is an algorithm |
| 5, 6 CMP | messages are plain maps already; the cost is staying compatible with Monty's snapshots |
| 11 W&B | `WandbWrapper` + `from_config/1`, and the `mark_obs` "exact image or our rendering" decision |
| 21–37 learning | these change the learning module; they arrive here only after they land in `monty-orig` |

The port's own ordering lives in `docs/roadmap.md`. This page only records what the
outside world is asking for.

## Read first — twelve threads

1. [776 Platform Current Reality Tree](https://forum.thousandbrains.org/t/platform-current-reality-tree/776) — the problem space
2. [818 Platform Future Reality Tree](https://forum.thousandbrains.org/t/platform-future-reality-tree/818) — the injection list
3. [1014 What Monty features or injections to work on next](https://forum.thousandbrains.org/t/what-monty-features-or-injections-to-work-on-next/1014)
4. [1076 Telemetry configurable down to the module level](https://forum.thousandbrains.org/t/333-telemetry-collection-is-configurable-down-to-the-python-module-level/1076)
5. [1209 Major updates to our future work research items](https://forum.thousandbrains.org/t/major-updates-to-our-future-work-research-items/1209)
6. [1204 From single parts to compositional objects](https://forum.thousandbrains.org/t/from-single-parts-to-compositional-objects-the-whole-first-then-the-details/1204)
7. [1192 From zero labels to 42/42](https://forum.thousandbrains.org/t/from-zero-labels-to-42-42-an-unsupervised-continual-learning-loop-on-14-geometric-parts/1192)
8. [1165 Could exact-pose matching be a bottleneck?](https://forum.thousandbrains.org/t/could-exact-pose-matching-be-a-bottleneck-for-compositional-generalization/1165)
9. [1218 Thoughts after monkeying around with Monty](https://forum.thousandbrains.org/t/thoughts-after-monkeying-around-with-monty/1218)
10. [1193 Monty can hear now](https://forum.thousandbrains.org/t/monty-can-hear-now-lyon-s-cochlea-sai-learning-module-melodies-as-graphs-transposition-invariance-falls-out/1193)
11. [1146 AATM: object identity from coalitions](https://forum.thousandbrains.org/t/aatm-can-object-identity-emerge-from-continuous-coalitions-of-partial-sensorimotor-representations/1146)
12. [208 Elixir-based subsystem(s) for Monty?](https://forum.thousandbrains.org/t/elixir-based-subsystem-s-for-monty/208) — the thread this port answers

## Where the corpus is

The whole crawl is loaded into **MemPalace, wing `tbp_forum`** — 792 source files,
11,515 drawers: 566 threads, 3,073 posts, 178 docs pages, 94 roadmap tasks, one digest
per team member.

| Room | Contents |
| --- | --- |
| `research-and-theory` · `monty-code` · `video-discussions` | one file per thread, with its source URL and every post by author and date |
| `general` · `miscellaneous` · `policies` · `site-feedback` · `uncategorized` | the remaining categories, same shape |
| `introductions` | the introductions subcategory and the few threads that fit nowhere else |
| `team` | one digest per TBP team member: every post they wrote, with dates and thread links |
| `roadmap` | one file per future-work area, one section per task with its metadata |
| `docs-site` | the published docs: the roadmap page plus all 178 task and reference pages |
| `plan` | how the archive was made, what is still open in it, and how to refresh it |

Ask it rather than grepping:

- `mempalace_search("telemetry pipeline", wing="tbp_forum")`
- `mempalace_search("symmetry pose", wing="tbp_forum", room="research-and-theory")`

Every file names its source URL, so anything quoted here can be checked in one hop.

The files themselves live in the neighbouring `ex.tbp.monty.input` folder: `out/` is the
corpus as MemPalace sees it (`out/roadmap`, `out/docs-site`, one folder per category),
`raw/` and `posts/` are the crawl's intermediate forms, and the three scripts that
regenerate the lot (`crawl.py`, `build.py`, `scrape_docs.py`) sit beside them.

---

## Appendix — every roadmap task, all 94

Nothing is left out above; this is the same list the
[project roadmap](https://docs.thousandbrains.org/docs/project-roadmap) shows, in one
scannable table. `paused`, `in-progress`, `scoping` and `completed` are TBP's own
statuses.

| Area | Task | Status | Size | Skills |
| --- | --- | --- | --- | --- |
| cmp hierarchy | [Add Top-Down Connections](https://docs.thousandbrains.org/docs/add-top-down-connections) | open | large | python · monty-advanced · research |
| cmp hierarchy | [Evaluate on Omniglot Dataset](https://docs.thousandbrains.org/docs/evaluate-on-omniglot-dataset) | paused | medium | python · monty-beginner · research |
| cmp hierarchy | [Extend Percept Filtering to LM-to-LM Messages](https://docs.thousandbrains.org/docs/extend-percept-filtering-to-lm-to-lm-messages) | open | medium | python · monty-advanced |
| cmp hierarchy | [Figure out Performance Measures and Supervision in Heterarchy](https://docs.thousandbrains.org/docs/figure-out-performance-measure-and-supervision-in-heterarchy) | completed | medium | python · monty-advanced |
| cmp hierarchy | [Global Interval Timer](https://docs.thousandbrains.org/docs/global-interval-timer) | open | medium | python · monty-beginner |
| cmp hierarchy | [Include State in CMP](https://docs.thousandbrains.org/docs/include-state-in-cmp) | open | small | python |
| cmp hierarchy | [Run & Analyze Experiments with more LMs in Heterarchy Testbed](https://docs.thousandbrains.org/docs/run-analyze-experiments-with-more-lms-in-heterarchy-testbed) | open | medium | python · monty-beginner · research |
| cmp hierarchy | [Send Class ID or Similarity Encoding ID in Compositional Experiments](https://docs.thousandbrains.org/docs/send-class-id-or-similarity-encoding-id-in-compositional-experiments) | open | medium | python · monty-beginner · research |
| cmp hierarchy | [Separate Location and Feature Messages in CMP](https://docs.thousandbrains.org/docs/separate-location-and-feature-messages-in-cmp) | open | large | python · refactoring · monty-advanced |
| cmp hierarchy | [Test Learning at Different Speeds Depending on Level in Hierarchy](https://docs.thousandbrains.org/docs/test-learning-at-different-speeds-depending-on-level-in-hierarchy) | open | medium | research · python · monty-beginner |
| environment | [Create Dataset and Metrics to Evaluate Categories and Generalization](https://docs.thousandbrains.org/docs/create-dataset-and-metrics-to-evaluate-categories-and-generalization) | open | large | 3d-modeling · python · monty-beginner · research |
| environment | [Create Dataset to Test new Feature-Morphology Pairs](https://docs.thousandbrains.org/docs/create-dataset-to-test-new-feature-morphology-pairs) | open | small | 3d-modeling |
| environment | [Make Dataset to Test Compositional Objects](https://docs.thousandbrains.org/docs/make-dataset-to-test-compositional-objects) | evergreen | medium | python · 3d-modeling |
| environment | [Object Behavior Test Bed](https://docs.thousandbrains.org/docs/object-behavior-test-bed) | paused | medium | python · simulator |
| environment | [Set Up Replicable Real World Test Bed](https://docs.thousandbrains.org/docs/replicable-real-world-test-bed) | open | large | python · robotics-hardware |
| environment | [Set up Environment that Allows for Object Manipulation](https://docs.thousandbrains.org/docs/set-up-environment-that-allows-for-object-manipulation) | open | medium | python · simulator |
| environment | [Set Up Object Manipulation Benchmark Tasks and Evaluation Measures](https://docs.thousandbrains.org/docs/set-up-object-manipulation-benchmark-tasks-and-evaluation-measures) | open | large | python · monty-beginner · research |
| environment | [Simplify Simulator Protocol](https://docs.thousandbrains.org/docs/simplify-simulator-protocol) | completed | large | python · refactoring |
| framework | [Add GPU Support for Monty](https://docs.thousandbrains.org/docs/add-gpu-support-for-monty) | in-progress | large | python · CUDA |
| framework | [Add Infrastructure for Multiple Agents that Move Independently](https://docs.thousandbrains.org/docs/add-infrastructure-for-multiple-agents-that-move-independently) | open | large | python · monty-advanced |
| framework | [Add More Wandb Logging for Unsupervised Learning](https://docs.thousandbrains.org/docs/add-more-wandb-logging-for-unsupervised-learning) | open | unknown | python · wandb |
| framework | [Combine Dataloader and Dataset class into EnvironmentInterface](https://docs.thousandbrains.org/docs/combine-dataloader-and-dataset-into-environment-interface) | completed | medium | python · refactoring |
| framework | [Find Faster Alternative to KDTree Search](https://docs.thousandbrains.org/docs/find-faster-alternative-to-kdtree-search) | paused | unknown | python |
| framework | [Generalize Dimensionality of Monty's Computations](https://docs.thousandbrains.org/docs/generalize-dimenensionality-of-monty-computations) | open | unknown | python · spatial-transformations |
| framework | [Improve Terminology Including Directory and Experiment Names](https://docs.thousandbrains.org/docs/improve-terminology-including-directory-and-experiment-names) | evergreen | medium | monty-beginner · monty-advanced |
| framework | [Make Configs Easier to Use](https://docs.thousandbrains.org/docs/make-configs-easier-to-use) | in-progress | large | python · refactoring · monty-beginner · monty-advanced |
| framework | [Profile and Speed up Monty](https://docs.thousandbrains.org/docs/profile-and-optimize-monty) | evergreen | unknown | python · performance-optimization |
| framework | [Use State Class Inside of LMs](https://docs.thousandbrains.org/docs/use-state-class-inside-of-lms) | open | unknown | python · refactoring |
| learning module | [Better Model Surface Representation](https://docs.thousandbrains.org/docs/better-model-surface-representation) | open | unknown | python · research · monty-beginner |
| learning module | [Deal with Incomplete Models](https://docs.thousandbrains.org/docs/deal-with-incomplete-models) | open | unknown | python · research · monty-beginner |
| learning module | [Deal with Moving Objects](https://docs.thousandbrains.org/docs/deal-with-moving-objects) | open | large | python · research · monty-advanced |
| learning module | [Dynamic Adjustment of Hypothesis Space Size](https://docs.thousandbrains.org/docs/dynamic-adjustment-of-hypothesis-space-size) | completed | large | python · research · monty-beginner |
| learning module | [Evaluate Alternative Tessellation Methods of 3D Space](https://docs.thousandbrains.org/docs/evaluate-alternative-tessellation-methods-for-3d-space) | open | large | python · research · monty-beginner |
| learning module | [Event Detection to Reset Timer](https://docs.thousandbrains.org/docs/event-detection-to-reset-timer) | open | medium | python · research · monty-beginner |
| learning module | [Explore Alternative Internal Representations for LMs](https://docs.thousandbrains.org/docs/explore-alternative-internal-representations-for-lms) | evergreen | unknown | python · research · monty-advanced |
| learning module | [Hybrid Node and Edge Matching](https://docs.thousandbrains.org/docs/hybrid-node-and-edge-matching) | open | large | python · research · monty-advanced |
| learning module | [Implement and Test Rapid Evidence Decay as Form of Unsupervised Memory Resetting](https://docs.thousandbrains.org/docs/implement-and-test-rapid-evidence-decay-as-form-of-unsupervised-memory-resetting) | completed | medium | python · research · monty-beginner |
| learning module | [Improve Bounded Evidence Performance](https://docs.thousandbrains.org/docs/improve-bounded-evidence-performance) | paused | medium | python · research · monty-beginner |
| learning module | [Improve Handling of Symmetry](https://docs.thousandbrains.org/docs/improve-handling-of-symmetry) | open | unknown | python · research · monty-advanced |
| learning module | [Include State in Hypotheses](https://docs.thousandbrains.org/docs/include-state-in-hypotheses) | open | large | python · research · monty-advanced |
| learning module | [Include State in Models](https://docs.thousandbrains.org/docs/include-state-in-models) | open | medium | python · monty-advanced · refactoring |
| learning module | [Learn Hot Spots on Objects](https://docs.thousandbrains.org/docs/learn-hot-spots-on-objects) | open | medium | python · monty-beginner · research |
| learning module | [Learning and Forgetting Speed Parameter](https://docs.thousandbrains.org/docs/learning-and-forgetting-speed-parameter) | open | unknown | python · research · monty-advanced |
| learning module | [Less Dependency on First Observation](https://docs.thousandbrains.org/docs/less-dependency-on-first-observation) | completed | large | python · research · monty-beginner |
| learning module | [Merge Input Channels in Learned Graphs](https://docs.thousandbrains.org/docs/merge-input-channels-in-learned-graphs) | open | large | python · refactoring · monty-advanced |
| learning module | [Model Repeating Patterns](https://docs.thousandbrains.org/docs/model-repeating-patterns) | open | unknown | python · research · monty-beginner |
| learning module | [Re-Anchor Hypotheses for Robustness to Noise and Distortions](https://docs.thousandbrains.org/docs/re-anchor-hypotheses) | paused | large | python · research · monty-beginner |
| learning module | [Sample Offspring Hypotheses](https://docs.thousandbrains.org/docs/sample-offspring-hypotheses) | open | medium | python · research · monty-beginner |
| learning module | [Speed Detection to Adjust Timer](https://docs.thousandbrains.org/docs/speed-detection-to-adjust-timer) | open | large | python · research · monty-advanced |
| learning module | [Support Scale Invariance](https://docs.thousandbrains.org/docs/support-scale-invariance) | open | large | python · research · monty-advanced · literature-review |
| learning module | [Test Grid Object Models for Unsupervised Learning](https://docs.thousandbrains.org/docs/test-grid-object-models-for-unsupervised-learning) | open | medium | research · monty-beginner |
| learning module | [Test Particle-Filter-Like Resampling of Hypothesis Space](https://docs.thousandbrains.org/docs/test-particle-filter-like-resampling-of-hypothesis-space) | completed | large | python · monty-advanced · research |
| learning module | [Unsupervised Learning in a Hierarchy](https://docs.thousandbrains.org/docs/unsupervised-learning-in-a-hierarchy) | open | unknown | python · research · monty-advanced |
| learning module | [Unsupervised Learning with Burst Sampling](https://docs.thousandbrains.org/docs/unsupervised-learning-with-burst-sampling) | open | medium | python · research · monty-beginner |
| learning module | [Use Better Priors for Hypothesis Initialization](https://docs.thousandbrains.org/docs/use-better-priors-for-hypothesis-initialization) | open | large | python · research · monty-advanced |
| learning module | [Use Constrained Grid Object Models for All Benchmark Experiments](https://docs.thousandbrains.org/docs/use-constrained-grid-object-models-for-all-benchmark-experiments) | open | medium | research · monty-advanced |
| learning module | [Use Models with Fewer Points](https://docs.thousandbrains.org/docs/use-models-with-fewer-points) | in-progress | large | python · research · monty-advanced |
| learning module | [Use Off-Object Observations](https://docs.thousandbrains.org/docs/use-off-object-observations) | paused | medium | python · research · monty-beginner · refactoring |
| learning module | [Use Out of Model Movements](https://docs.thousandbrains.org/docs/use-out-of-model-movements) | paused | medium | python · research · monty-beginner |
| monty demos | [Improve Monty's Performance on Ultrasound](https://docs.thousandbrains.org/docs/improve-montys-performance-on-ultrasound) | evergreen | medium | python · computer-vision · research · monty-beginner |
| monty tooling | [Improve tbp.plot Visualizations During Learning and Inference](https://docs.thousandbrains.org/docs/improve-tbp-plot-visualizations-during-learning-and-inference) | evergreen | medium | python · visualizations |
| motor system | [Implement Efficient Saccades Driven by Model-Free and Model-Based Signals](https://docs.thousandbrains.org/docs/implement-efficient-saccades-driven-by-model-free-and-model-based-signals) | completed | large | research · literature-review · python · monty-advanced · refactoring · computer-vision |
| motor system | [Implement Switching Between Learning and Inference-Focused Policies](https://docs.thousandbrains.org/docs/implement-switching-between-learning-and-inference-focused-policies) | open | unknown | python · monty-advanced · refactoring |
| motor system | [Interpret Goal States in Motor System & Switch Policies](https://docs.thousandbrains.org/docs/interpret-goal-states-in-motor-system-switch-policies) | completed | unknown | python · monty-advanced · refactoring |
| motor system | [Learn Policy using RL and Simplified Action Space](https://docs.thousandbrains.org/docs/learn-policy-using-rl) | in-progress | large | python · monty-beginner · research · reinforcement-learning |
| motor system | [Model-Based Exploration Policy](https://docs.thousandbrains.org/docs/model-based-exploration-policy) | open | unknown | python · monty-advanced · spatial-transformations · research |
| motor system | [Model-Free Distant Agent Exploration Policy](https://docs.thousandbrains.org/docs/model-free-distant-agent-exploration-policy) | open | medium | python · monty-beginner |
| motor system | [Policy to quickly move to a new object](https://docs.thousandbrains.org/docs/policy-to-quickly-move-to-a-new-object) | open | unknown | python · monty-advanced · research |
| motor system | [Policy to Recognize an Object Before Moving onto a New Object](https://docs.thousandbrains.org/docs/policy-to-recognize-an-object-before-moving-on-to-a-new-object) | scoping | large | research · python · monty-advanced |
| motor system | [Theory for Decomposing Goals into Subgoals](https://docs.thousandbrains.org/docs/theory-for-decomposing-goals-into-subgoals) | scoping | unknown | research · literature-review · neuroscience |
| oss communication | [Auto-Display Contributors in README](https://docs.thousandbrains.org/docs/auto-display-contributors-in-readme) | open | small | github-actions · javascript · css |
| oss communication | [Better Documentation Platform](https://docs.thousandbrains.org/docs/better-documentation-platform) | open | large | github-actions · python · github-readme-sync-tool · s3 · javascript · html · css · markdown · yaml |
| oss communication | [Better Website Platform](https://docs.thousandbrains.org/docs/better-website-platform) | open | large | github-actions · s3 · javascript · html · css · web-frameworks · css-frameworks |
| oss communication | [Build a Tutorial](https://docs.thousandbrains.org/docs/build-a-tutorial) | evergreen | medium | video-production · writing · python |
| oss communication | [Find Forum Questions Themes & Improve Docs](https://docs.thousandbrains.org/docs/find-forum-questions-themes-improve-docs) | evergreen | medium | data-analysis · writing |
| oss communication | [Future Work Widget](https://docs.thousandbrains.org/docs/future-work-widget) | completed | medium | github-actions · python · github-readme-sync-tool · s3 · javascript · html · css |
| oss communication | [Insert Glossary Terms in Docs](https://docs.thousandbrains.org/docs/insert-glossary-terms-in-docs) | open | small | github-readme-sync-tool · css · javascript |
| oss communication | [Make More Condensed Videos About the Project & Monty](https://docs.thousandbrains.org/docs/make-more-condensed-videos-about-the-project-monty) | evergreen | medium | video-production · audio-editing |
| oss communication | [Organize Local Meetup](https://docs.thousandbrains.org/docs/organize-local-meetup) | evergreen | small | event-planning · networking |
| oss communication | [Organize & Start Podcast Series](https://docs.thousandbrains.org/docs/organize-start-podcast-series) | open | large | interviewing · writing · audio-editing · video-production |
| oss communication | [Robust Docs Preview Cleanup](https://docs.thousandbrains.org/docs/robust-docs-preview-cleanup) | open | medium | github-actions · bash |
| sensor module | [Additional Methods for Depth Perception](https://docs.thousandbrains.org/docs/additional-methods-for-depth-perception) | open | medium | python · computer-vision · monty-beginner |
| sensor module | [Change Detecting SM](https://docs.thousandbrains.org/docs/change-detecting-sm) | open | large | python · research · computer-vision · monty-beginner |
| sensor module | [Detect Local and Global Flow](https://docs.thousandbrains.org/docs/detect-local-and-global-flow) | open | medium | python · research · computer-vision · monty-beginner |
| sensor module | [Explore Alternative Segmentation Strategies](https://docs.thousandbrains.org/docs/explore-alternative-segmentation-strategies) | evergreen | medium | python · computer-vision |
| sensor module | [Extract Better Features](https://docs.thousandbrains.org/docs/extract-better-features) | evergreen | medium | python · research · computer-vision · monty-beginner |
| sensor module | [One-D Sensor Module](https://docs.thousandbrains.org/docs/one-d-sensor-module) | open | medium | python · research · monty-beginner · computer-vision |
| sensor module | [Surface SM](https://docs.thousandbrains.org/docs/surface-sm) | completed | large | python · research · monty-beginner · computer-vision |
| sensor module | [Universal SM for Morphological Feature Extraction](https://docs.thousandbrains.org/docs/universal-sm-for-morphological-feature-extraction) | open | large | python · research · computer-vision |
| voting | [Can we change the CMP to use displacements instead of locations?](https://docs.thousandbrains.org/docs/can-we-change-the-cmp-to-use-displacements-instead-of-locations) | open | medium | monty-advanced |
| voting | [Clean up and Simplify Voting](https://docs.thousandbrains.org/docs/clean-up-and-simplify-voting) | open | medium | python · monty-advanced · refactoring |
| voting | [Generalize Voting to Associative Connections](https://docs.thousandbrains.org/docs/generalize-voting-to-associative-connections) | open | large | research · python · monty-advanced |
| voting | [Outline How to Apply Attention](https://docs.thousandbrains.org/docs/outline-how-to-apply-attention) | scoping | medium | research · literature-review · monty-advanced |
| voting | [Vote on State](https://docs.thousandbrains.org/docs/vote-on-state) | open | medium | python · research · monty-beginner |

