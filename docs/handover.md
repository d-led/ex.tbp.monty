# Hand-over — moved into MemPalace on 2026-11-14

The hand-over is no longer a file in this repository. Every section of the file
that used to be here — the preamble and §1 to §55, 58 pieces in all — is now a
drawer in MemPalace:

| what                               | where                                                                                                      |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| wing                               | `ex.tbp.monty`                                                                                             |
| room                               | `handover`                                                                                                 |
| the current state, kept up to date | `drawer_ex.tbp.monty_handover_8fbec177134c01cb3b6901fc` — the canonical drawer, written 2026-11-14 evening |
| one drawer per section             | `hand-over §N — <title>`, 530 drawers, each naming its source file                                         |

**Read the canonical drawer first.** It is the current tree, the current open
list and what landed that day. The section drawers are what it was distilled
from: the measurements, the retractions and the reasons — which is what a section
can do that a summary cannot.

## How to read it

```
mempalace search "abandoned run steps RunStream"    # by what you remember
mempalace search "hand-over §47"                    # one section, by number
```

From an agent, `mempalace_search` with `wing: "ex.tbp.monty"`, `room: "handover"`.
A section's first drawer carries its title, the validity check below and then the
text; the rest of that section follows as numbered chunks with the same
`source_file`.

The split files the drawers were mined from live outside the repository, at
`~/Library/Application Support/mempalace-sources/ex.tbp.monty/handover/`, with a
`mempalace.yaml` beside them that maps that folder to the room. They are kept
because a drawer records its source path and `mempalace sync` prunes drawers whose
source is gone — deleting that folder would delete the drawers.

## What was checked when it moved

Each section was filed with a validity line: its commits looked for in this
checkout and the sibling ones, its paths on disk, its module names in `defmodule`
declarations, its `§`-references against the sections that exist. What that found,
and what is worth knowing before trusting an old section:

- **`§7`, `§9`, `§16` and `§17` are not in the file and never were** — the
  sections that cite them (§6, §15, §18, §37) point at nothing. They were numbered
  over, or written in a window that was lost; either way the citation is dangling
  and the drawer says so.
- **Six numbers are used twice**: §3, §5, §6, §14, §15 and §35. The later section
  of each pair is the revision — its heading usually says `closed` or `superseded
by §34` — and the earlier one carries a `Superseded` line saying so.
- **Some pointers are stale because _Monty_ moved, not because the finding was
  wrong**: `test/evidence_lm/…`, `test/graph_learning/…` and `test/base_config/…`
  no longer exist upstream (Monty regrouped `tests/unit`), and `conf/experiment` is
  now `src/tbp/monty/conf/experiment`. Sections §6, §11, §12, §19, §20, §23, §24
  and §27 are the ones affected.
- **`lib/monty/module_map/data.ex` is now
  `packages/ex_tbp_monty_core/lib/monty/module_map/data.ex`** (§11).
- **Two tokens that look like commits are run ids**: `06087316560f` (§47) and
  `9750c01e` (§50).
- Every other section's commits, paths and cross-references resolved at the move.

Nothing was dropped for being stale: a section that could not be verified is in
the palace with the failure written on it, because the failure is part of the
record.

## Why it is not a file any more

The file had reached 4 300 lines and 275 kB, and the part a reader needs — what is
true now — was competing with three days of archaeology for the same page. The
palace answers the two questions separately: search for what you remember, or read
the canonical drawer for the state. Git history still has the whole file, at
`git log --follow -- docs/handover.md`, for anyone who wants the original order and
line numbers.
