#!/usr/bin/env bash
#
# Format everything that has a formatter: `mix format` owns the Elixir and the
# HEEx, prettier owns the markdown and the JavaScript.
#
#   scripts/reformat.sh            rewrite in place
#   scripts/reformat.sh --check    say what is unformatted, change nothing
#
# The markdown is why this script exists. Prettier lines the tables up, and
# `--prose-wrap preserve` keeps every paragraph wrapped the way it was written —
# the diff is the tables and the list markers, not the prose.
#
# Prettier is a convenience, not a dependency. With no `npx` on PATH, or no way
# to fetch prettier (an offline checkout), the markdown and JavaScript are left
# exactly as they are and the script says so and succeeds; `mix format` has
# already run. Nothing here runs in CI — `scripts/quality.sh` is read-only on
# purpose.
#
# Left alone on purpose: `priv/monty/` is Monty's own tree, copied file for file
# and checked by `mix monty.inputs --check`; `assets/vendor/` is code we did not
# write. JSON, CSS and HEEx are out of scope — `mix format` owns the last, the
# first two are generated or Tailwind's.

set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  sed -n '3,4p;6,7p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'
}

check=0

case "${1:-}" in
  "") ;;
  --check) check=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown option: $1" >&2
    usage >&2
    exit 64
    ;;
esac

banner() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

banner "Elixir and HEEx (mix format)"

if [[ $check -eq 1 ]]; then
  mix format --check-formatted
else
  mix format
fi

banner "the examples (projects of their own)"

# `examples/*` are projects with their own `mix.exs` and their own
# `.formatter.exs`, and the root `mix format` above reaches neither — its inputs
# are the root's `lib`, `test`, `config` and `mix_tasks`. CI formats each example
# inside its own directory, so without this the local check passes and the
# `example <name>` leg fails at `mix format --check-formatted` before a test
# runs. It did: `0d8d8b1` committed an unformatted example test and `68d7ac6`
# went red on it.
for project in examples/*/mix.exs; do
  [[ -f $project ]] || continue
  directory=$(dirname "$project")

  # The formatter wants the project's own deps resolved, and an example nobody
  # has fetched yet is skipped the way prettier is skipped below.
  if [[ ! -d $directory/deps ]]; then
    echo "skipped: $directory has no deps — fetch them there first"
    continue
  fi

  echo "  $directory"
  if [[ $check -eq 1 ]]; then
    (cd "$directory" && mix format --check-formatted)
  else
    (cd "$directory" && mix format)
  fi
done

banner "markdown and JavaScript (prettier)"

# `npx` ships with node; this project has node only for the asset build, so its
# absence is normal and is not a failure.
if ! command -v npx >/dev/null 2>&1; then
  echo "skipped: no npx on PATH — markdown and JavaScript left as they are"
  exit 0
fi

prettier=(npx --yes prettier@3 --prose-wrap preserve)

# Asked before it is used, so an offline machine reads as "no prettier here"
# rather than as a formatting failure.
if ! "${prettier[@]}" --version >/dev/null 2>&1; then
  echo "skipped: prettier could not be fetched — markdown and JavaScript left as they are"
  exit 0
fi

if [[ $check -eq 1 ]]; then
  mode=--check
else
  mode=--write
fi

# The globs are prettier's, not the shell's: it expands `**` itself and skips a
# pattern that matches nothing.
"${prettier[@]}" "$mode" "*.md" "docs/**/*.md" "assets/js/**/*.js"
