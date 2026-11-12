#!/bin/bash
# Tag the current commit with the version in VERSION and push the tag.
#
#   ./scripts/tag_and_push_version.sh            # tag and push
#   ./scripts/tag_and_push_version.sh 0.1.2      # ... saying which version you mean
#   ./scripts/tag_and_push_version.sh --dry-run  # say what it would do
#   ./scripts/tag_and_push_version.sh --no-check # tag even if CI is not green
#
# A version may be named with or without its leading `v`. It is a claim about the
# commit, not a setting: the tag is always `v` + `VERSION`, and a claim the files
# disagree with is refused rather than tagged.
#
# The tag is what `.github/workflows/publish.yml` releases from, and it refuses
# to tag a commit whose CI is not green: a hex release is permanent, and a
# version number spent on a broken build cannot be taken back. `--no-check`
# lifts that refusal for the case it cannot serve — a commit whose CI cannot be
# asked about at all (no `gh`, a fork, a runner outage) — and says so on the way
# past, twice.
set -e

cd "$(dirname "$0")/.."

DRY_RUN=false
CHECK_CI=true
NAMED=""

for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN=true ;;
    --no-check) CHECK_CI=false ;;
    -*)
      echo "Error: unknown option '$argument'"
      echo "       usage: $0 [VERSION] [--dry-run] [--no-check]"
      exit 1
      ;;
    *)
      if [ -n "$NAMED" ]; then
        echo "Error: two versions named ('$NAMED' and '$argument') — name one."
        exit 1
      fi
      # `v0.1.2` and `0.1.2` are the same claim; the files spell it without the v.
      NAMED="${argument#[vV]}"
      ;;
  esac
done

VERSION=$(tr -d '[:space:]' < VERSION)
[ -n "$VERSION" ] || { echo "Error: could not read VERSION"; exit 1; }

# The command line is answered before the repository is: a version typed wrongly
# is worth saying before anything else is checked.
if [ -n "$NAMED" ] && [ "$NAMED" != "$VERSION" ]; then
  echo "Error: '$NAMED' was named, but this commit's version is '$VERSION'."
  echo "       The tag is always 'v$VERSION' — naming a version does not set it."
  echo "       To tag $NAMED, bump the version first, commit it, and run this again:"
  echo "         elixir scripts/release.exs bump patch|minor|major"
  exit 1
fi

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Error: not in a git repository"
  exit 1
fi

# Only what a commit would carry: a modified or staged file is work the tag would
# leave out, and a tag cannot be taken back. Untracked files are in no commit, so
# they are in no tag either and do not stop a release. A stash is never the
# answer — it would hide the difference between the files and the tag rather than
# state it.
DIRTY=$(git status --porcelain --untracked-files=no)

if [ -n "$DIRTY" ]; then
  echo "Error: these changes are not in the commit the tag would name:"
  echo "$DIRTY"
  echo "       Commit them first — the tag records a commit, not the files on disk."
  exit 1
fi

# The package and the file have to agree, or the tag publishes a version nobody
# reviewed.
elixir scripts/release.exs check

TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  echo "Error: $TAG already exists"
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
SHA=$(git rev-parse HEAD)

# CI, by commit rather than by branch: a green branch says the last push passed,
# this says *this* commit did. `gh` is the only way to ask, so its absence stops
# here rather than tagging on a guess.
if [ "$CHECK_CI" = false ]; then
  echo "WARNING: --no-check — CI was not asked about $SHA."
  echo "         A tag publishes to Hex, and a version spent on a broken build"
  echo "         cannot be taken back."
else
  if ! command -v gh > /dev/null 2>&1; then
    echo "Error: gh is not installed, so CI cannot be checked for $SHA"
    echo "       Pass --no-check to tag without asking."
    exit 1
  fi

  CONCLUSION=$(
    gh api "repos/{owner}/{repo}/actions/workflows/ci.yml/runs?head_sha=$SHA&per_page=1" \
      --jq '.workflow_runs[0].conclusion // "none"' 2>/dev/null || echo "unknown"
  )

  echo "commit $SHA on $BRANCH: ci conclusion ${CONCLUSION}"

  if [ "$CONCLUSION" != "success" ]; then
    echo "Error: CI for $SHA is '${CONCLUSION}' — nothing is tagged until it is 'success'."
    echo "       Watch it with: gh run list --commit $SHA"
    echo "       Pass --no-check to tag anyway."
    exit 1
  fi
fi

if [ "$DRY_RUN" = true ]; then
  echo "Would tag $TAG at $SHA and push it"
  exit 0
fi

git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "Pushed $TAG. The publish workflow releases the core to Hex from it."
