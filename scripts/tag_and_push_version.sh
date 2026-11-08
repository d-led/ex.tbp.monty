#!/bin/bash
# Tag the current commit with the version in VERSION and push the tag.
#
#   ./scripts/tag_and_push_version.sh            # tag and push
#   ./scripts/tag_and_push_version.sh --dry-run  # say what it would do
#
# The tag is what `.github/workflows/publish.yml` releases from, and it refuses
# to tag a commit whose CI is not green: a hex release is permanent, and a
# version number spent on a broken build cannot be taken back.
set -e

cd "$(dirname "$0")/.."

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Error: not in a git repository"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: the working tree is not clean — commit or stash first:"
  git status --short
  exit 1
fi

VERSION=$(tr -d '[:space:]' < VERSION)
[ -n "$VERSION" ] || { echo "Error: could not read VERSION"; exit 1; }

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
if ! command -v gh > /dev/null 2>&1; then
  echo "Error: gh is not installed, so CI cannot be checked for $SHA"
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
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  echo "Would tag $TAG at $SHA and push it"
  exit 0
fi

git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "Pushed $TAG. The publish workflow releases the core to Hex from it."
