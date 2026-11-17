# Hand-over: the run page's pictures, and the dogs

Two threads are in flight here. The first is blocked and needs a decision about
where a picture is attached; the second is unblocked and needs a run. This note
says what was measured, what was wrong, and exactly what is left.

## 1. The pictures, and why the page still pulls them

### The rule that governs the work

A page in this application is **pushed** to. It may not ask the server for
anything: a step arrives over the socket with the pictures it has, and the page
draws it. An `<img src="/runs/…/frames/…">` is a fetch per picture per step.

Related rule, from the same conversation: **the page never catches up.** What a
conference does with the frames it missed is drop them; the viewer renders the
newest one. It applies twice here — the picture writer drops a step whose
successor is already waiting, and the page draws the step it is handed rather
than searching backwards for a picture it can show instead.

### What the committed code does

`Draw the pictures that exist, under the step they belong to` fixed the symptom —
the broken-image icons — by making `Artifacts.pictures_at/2` answer the newest step
at or before the one asked, and have the page draw _that_. It is still a **pull**:
the moment names files, and the browser fetches them.

`A run started from a page keeps the names its episodes learned` is a separate
fix from the same day (see §3). It is not affected by this thread.

### Why the obvious change breaks

Making the page inline its pictures — `Artifacts.inlined/2` and
`pictures_inline/2` turn a step's files into `data:` URIs — was written and
backed out twice. The reason is a fact about the moment, measured rather than
assumed:

- `Replay.at(run, step)` on a fully loaded record gives
  `%{position: 1, step: 1, sensors: 1, frames: 1}` — frames present.
- The same run **as the page loads it** reaches `assign_replay` with no frames
  and no sensors, and its `timeline` is not empty even though the entries carry
  no sensors.

So whether a step has pictures depends on which read produced the record, not on
the step. Any code that repairs pictures inside the LiveView has to guess, and
the two replay tests in `test/ex_tbp_monty_web/live/run_history_live_test.exs`
("opens at the last step, with the picture that step saw", "moving the slider
shows that step, from the record") are the specification that catches the guess
being wrong.

### The change to make

Attach the picture where the moment is **built**, so nothing re-derives it
afterwards:

1. `Replay` (and the record read behind it) is where a recorded step's pictures
   should be inlined. It knows the position, and it already builds `frames` from
   `sensors`; inlining there means a moment either carries bytes or carries
   nothing.
2. With that done, `with_pictures/2` in `RunHistoryLive` disappears: no
   existence check, no file lookup, no database read, no catch-up — there is
   nothing left to repair.
3. A step whose picture was dropped draws no picture, and the panel says so. One
   line of text, no search backwards.
4. `Artifacts.pictures_at/2` keeps **exact-step** semantics. The nearest-earlier
   fallback in the committed version is the catch-up the rule forbids and should
   go with the rest.
5. The `/runs/:id/frames/*path` route stays for anything outside the browser;
   the page never names it. A test should assert that the rendered page contains
   `data:image/png;base64` and no `/frames/`.

### The defect underneath

`RunStream` numbers a step's picture folder by the stream's own counter
(`frame_key/2`, "a step's pictures keep their place in the run"). That counter
lives in the process, so **a run resumed in another VM numbers its pictures from
nought again** while the record keeps its own positions. The record then names a
folder the writer never wrote — measured on one run: the page asked for
`frames/14359`, and `frames/9579` was the newest on disk. Whatever is done about
the push, this has to be fixed too: the name a picture is kept under must be
derived from something that survives a restart (the run's own step index), not
from a process-local counter.

## 2. What the picture writer does now

`RunStream.Pictures` draws a step's pictures behind the step, in its own process,
so stepping does not wait for an encode. The committed version draws every step;
a version that drops a step whose successor is already queued was written and
backed out with the rest. Its measured rate on this machine was around one step
per second at the end of a five-episode run — four PNGs — against roughly twenty
steps per second of stepping, which is why the lag grew to thousands of steps.

A run of twenty thousand steps is eighty thousand files. Thinning the writer
(draw the newest, drop what is already behind) is a design decision that belongs
with the push, because it is what makes "the newest step always has its picture".

## 3. The dogs

### Done

- The corpus is five dogs, with three excluded for measured reasons:
  `smoothie_3d` is a room (surface over bounding-box volume 0.04 against the
  dogs' 0.62–8.92, and `orienting_angle_from_normal/4` answers 0° on a flat
  wall, which is what "almost no rotation" was); `boykin_spaniel` and
  `puppy_dog` carry 69-byte textures, which is the importer's one-pixel grey.
  The importer now reports `— NO TEXTURE (a flat grey patch)` instead of staying
  silent.
- A training phase keeps the names its graphs were built from: `Run.merge_targets/2`
  unions a phase's answers per module and per graph, `mix monty.run` merges each
  training episode into the phase's map, and the worker that steps a run started
  from a page does the same (`jobs/run.ex`), reading the names off the modules
  _before_ the episode's processes stop.

### Not done

- **No scored training run exists yet.** The five-dog phase started from the
  studio wrote a library whose graphs were all `new_object0`, which is what
  `a4b107b` fixes; that fix has not been proved end to end. The check is
  `MIX_ENV=test mix run --no-start scripts/memory_names.exs dogs_surf_unsupervised`:
  it must name five dogs, one graph each.
- Only then is recognition scorable:
  `MIX_ENV=test mix run --no-start scripts/probe_recognitions.exs dogs/inference_supervised 5`
  and `… dogs/inference_paired 5`, counting "named only the dog shown" against
  "named it among others".
- `Monty.Studio.Memories` (the divided-run merge) still writes libraries without
  `targets`.

## 4. Known defects, unrelated

- A run that ends can fail its last write with `Ecto.StaleEntryError` on the
  history row; the library is written before that, so the training completed.
- A transcript write at an episode boundary reports `:not_found`.
- The dev server must be restarted after editing `packages/ex_tbp_monty_core`,
  which is a `path:` dependency and is not hot-reloaded. Editing `lib/` while a
  run is stepping purges the module the run is in.

## 5. How to check any of this

```
scripts/run_in_flight.sh          # exit 1: a run is stepping, do not edit lib/
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
MIX_ENV=test mix dialyzer
MIX_ENV=test mix test test/monty/studio test/ex_tbp_monty_web
```

`types` and `lint` are the two jobs that fail first in CI, and both are cheap to
run before pushing. The picture fix broke them with two unreachable clauses in
`run_history_live.ex` and a leftover `IO.inspect` in a test; the follow-up fixes
those, and it is worth running the commands above before any commit that touches
the run page.
