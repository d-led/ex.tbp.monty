#!/usr/bin/env bash
#
# Refuses a release that carries anything a run, a tool or a build wrote.
#
#   scripts/check-release.sh _build/desktop/rel/ex_tbp_monty
#   scripts/check-release.sh "Monty on the BEAM.app/Contents/Resources/rel/ex_tbp_monty"
#
# `mix release` copies an application's `priv` **whole**, so whatever a checkout
# happened to have in `priv` ships: a desktop bundle was once several gigabytes of
# development run recordings, dialyzer pictures and an embedded interpreter, none
# of which the program needs to start. The rule this enforces is the project's:
# a release carries the application and the couple of small STEP parts that make
# the CAD world demonstrable, and every data prerequisite is *downloaded* into
# the user's data folder (`Monty.Paths`), never packaged.
#
# It is a check and not a `rm`, deliberately. Deleting the two folders somebody
# remembered is how the other ones stayed; a build that would carry them fails
# here and names what it found, so the fix happens where the data was written.
set -euo pipefail

release=${1:?a release directory, e.g. _build/desktop/rel/ex_tbp_monty}

[ -d "$release" ] || {
  echo "no release at $release" >&2
  exit 1
}

# Output, not application: a run's recordings, an exported memory, a dialyzer
# picture, an interpreter's environment, bytecode caches, a coverage database.
forbidden_names=(studio_runs libraries plts uv .venv __pycache__ node_modules)
forbidden_files=('*.plt' '*.plt.hash' '*.coverdata' 'run.log' '*.jsonl.gz')

blew_up=0

report() {
  echo "  $1" >&2
  blew_up=1
}

for name in "${forbidden_names[@]}"; do
  while IFS= read -r found; do
    [ -n "$found" ] && report "${found#"$release"/}"
  done < <(find "$release" -name "$name" -maxdepth 6 2>/dev/null)
done

for pattern in "${forbidden_files[@]}"; do
  while IFS= read -r found; do
    [ -n "$found" ] && report "${found#"$release"/}"
  done < <(find "$release" -name "$pattern" -maxdepth 6 2>/dev/null)
done

if [ "$blew_up" -ne 0 ]; then
  cat >&2 <<'SAYS'
the release carries data that is not the application.

  Run output and exported memory belong in the user's data folder — the one
  `scripts/start-desktop.sh --where` prints (`Monty.Paths`): a run's log and
  frames under `runs/`, an exported memory under `data/libraries/`. Dialyzer
  pictures belong in `_build/plts`. The Python interpreter is a prerequisite that
  is downloaded, because `config/pythonx.exs` is only imported for development
  and the tests.

  Nothing is deleted here on purpose: a build that quietly cleaned up after the
  last one is how the next folder went unnoticed. Remove what is named above from
  the checkout's `priv/` (or from `_build/desktop/rel` and rebuild), and the
  release will be the application again.
SAYS
  exit 1
fi

echo "release carries the application only: $(du -sh "$release" | cut -f1) in $release"
