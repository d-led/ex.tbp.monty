#!/usr/bin/env bash
#
# Refuses a release that carries anything a run, a tool or a build wrote.
#
#   scripts/check-release.sh _build/desktop/rel/ex_tbp_monty
#   scripts/check-release.sh "Monty on the BEAM.app/Contents/Resources/rel/ex_tbp_monty"
#
# `mix release` copies an application's `priv` **whole**, so whatever a checkout
# happened to have in `priv` ships: a desktop bundle was once four gigabytes of
# development run recordings, and dialyzer pictures beside them. The rule this
# enforces is the project's: a release carries the application and the couple of
# small STEP parts that make the CAD world demonstrable, and every data
# prerequisite is *downloaded* into the user's data folder (`Monty.Paths`), never
# packaged.
#
# The application's `priv` is the only one searched, because that is the only one
# a checkout writes. A dependency's `priv` is its own business, and `pythonx`'s
# carries the interpreter this project means to ship: `config/pythonx.exs` has uv
# build a CPython and its wheels at compile time, roughly 300 MB of a 370 MB
# desktop bundle, and a MuJoCo world does not step without it.
set -euo pipefail

release=${1:?a release directory, e.g. _build/desktop/rel/ex_tbp_monty}

[ -d "$release" ] || {
  echo "no release at $release" >&2
  exit 1
}

shopt -s nullglob
privs=("$release"/lib/ex_tbp_monty-*/priv)

if [ ${#privs[@]} -eq 0 ]; then
  echo "no application priv in $release" >&2
  exit 1
fi

# Output, not application: a run's recordings, an exported memory, a dialyzer
# picture, an interpreter's environment, bytecode caches, a coverage database.
forbidden_names=(studio_runs libraries plts python uv .venv __pycache__ node_modules)
forbidden_files=('*.plt' '*.plt.hash' '*.coverdata' 'run.log' '*.jsonl.gz')

blew_up=0

# Naming what it found is the point — the next build stops carrying it — but a
# folder with forty thousand recordings in it is one finding, not forty
# thousand: five paths and "and more" is enough to find the writer.
report() {
  echo "  $1" >&2
  blew_up=1
}

# `namer <name>` reports the paths its standard input gives it — as many as five
# and a count of the rest — so a folder with forty thousand recordings in it is
# one finding rather than forty thousand lines to read.
namer() {
  local name=$1 seen=0

  while IFS= read -r found; do
    seen=$((seen + 1))

    if [ "$seen" -le 5 ]; then
      report "${found#"$release"/}"
    fi
  done

  if [ "$seen" -gt 5 ]; then
    echo "  … and more paths match $name" >&2
  fi

  return 0
}

for priv in "${privs[@]}"; do
  for name in "${forbidden_names[@]}" "${forbidden_files[@]}"; do
    # `head` stops `find` walking a tree that holds only the same finding again.
    namer "$name" < <(find "$priv" -name "$name" 2>/dev/null | head -6)
  done
done

# A recording is never the application, wherever it was dropped, so these two are
# searched for in the whole release — with the application's `priv` pruned, since
# it has just been searched with more rules and would be reported twice, and with
# the interpreter and the runtime pruned, because a release holds only generated
# output in them and walking a hundred thousand files to say so is the cost of
# the whole check.
for name in 'run.log' '*.jsonl.gz'; do
  namer "$name" < <(
    find "$release" \
      -path "${privs[0]}" -prune -o \
      -path "$release/lib/pythonx-*" -prune -o \
      -path "$release/erts-*" -prune -o \
      -name "$name" -print 2>/dev/null | head -6
  )
done

if [ "$blew_up" -ne 0 ]; then
  cat >&2 <<'SAYS'
the release carries data that is not the application.

  Run output and exported memory belong in the user's data folder — the one
  `scripts/start-desktop.sh --where` prints (`Monty.Paths`): a run's log and
  frames under `runs/`, an exported memory under `data/libraries/`. Dialyzer
  pictures belong in `_build/plts`.

  The interpreter is not one of these. The one this project ships is built by
  `config/pythonx.exs` into `pythonx`'s own `priv/uv`, and what is refused here
  is an interpreter environment of the *application's* own, in the place a
  checkout writes to.

  Nothing is deleted here on purpose: a build that quietly cleaned up after the
  last one is how the next folder went unnoticed. Remove what is named above from
  the checkout's `priv/` (or from `_build/desktop/rel` and rebuild), and the
  release will be the application again.
SAYS
  exit 1
fi

echo "release carries the application only: $(du -sh "$release" | cut -f1) in $release"
