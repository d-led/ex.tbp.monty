#!/usr/bin/env bash
# Installs the desktop window: one `.app`, with its server inside, no runtime to
# install.
#
#   curl -fsSL https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/install-desktop.sh | bash
#
# What it installs is the newest build of `main` — there is no release to wait
# for. A tagged release keeps the same file in the releases page, which is what
# to use for a version that has to stay put.
#
#   EX_TBP_MONTY_APP_DIR   where to put the app (default: ~/Applications)
#   EX_TBP_MONTY_REPO      owner/repo to download from (default: d-led/ex.tbp.monty)
#   EX_TBP_MONTY_BRANCH    which branch's build to take (default: main)
#   EX_TBP_MONTY_WORKFLOW  the workflow that builds it (default: ci)
#   EX_TBP_MONTY_BASE_URL  a directory holding ex-tbp-monty-<os>-<arch>.zip
#                          itself, which skips nightly.link
#
# The app is not signed or notarised yet (docs/desktop.md), so macOS asks once:
# right-click, Open, Open. Everything after that is a normal double-click.

set -euo pipefail

repo="${EX_TBP_MONTY_REPO:-d-led/ex.tbp.monty}"
branch="${EX_TBP_MONTY_BRANCH:-main}"
workflow="${EX_TBP_MONTY_WORKFLOW:-ci}"
app_dir="${EX_TBP_MONTY_APP_DIR:-$HOME/Applications}"

case "$(uname -s)" in
    Darwin) os=osx ;;
    *)
        echo "The desktop window is built for macOS only so far: there is no $(uname -s) build to install." >&2
        echo "What exists, and what is missing, is in docs/desktop.md. A checkout can build its own copy:" >&2
        echo "  scripts/start-desktop.sh" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    *)
        echo "The desktop window is built for Apple Silicon only so far: no $arch build exists." >&2
        exit 1
        ;;
esac

asset="ex-tbp-monty-$os-$arch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() {
    case "$1" in
        # A `BASE_URL` may be a directory on this machine (`/mnt/builds`), which
        # is how the packaging is tried without a network round trip.
        *://*) curl -fL --progress-bar "$1" -o "$2" ;;
        *) cp "$1" "$2" ;;
    esac
}

mkdir -p "$app_dir"

if [ -n "${EX_TBP_MONTY_BASE_URL:-}" ]; then
    echo "Downloading $asset from $EX_TBP_MONTY_BASE_URL ..."
    fetch "$EX_TBP_MONTY_BASE_URL/$asset.zip" "$work/$asset.zip"
else
    latest="https://nightly.link/$repo/workflows/$workflow/$branch/$asset.zip"
    echo "Downloading the newest $branch build: $latest"
    fetch "$latest" "$work/$asset.zip"
fi

# Two layers, because two tools zip: nightly.link wraps the artefact in a zip of
# its own (`BASE_URL` skips that wrapper), and the artefact is a bundle zip,
# because an `.app` keeps its symlinks and executable modes only in one. `ditto`
# expands both with those intact.
#
# Said out loud, because both steps take a while and a script that prints
# nothing for a minute reads as one that has hung.
echo "Unpacking the download ..."
mkdir -p "$work/unpacked"
ditto -x -k "$work/$asset.zip" "$work/unpacked"

bundle_zip="$(find "$work/unpacked" -maxdepth 1 -name '*.zip' -print -quit)"
if [ -n "$bundle_zip" ]; then
    echo "Expanding the application (about 550 MB) ..."
    mkdir -p "$work/app"
    ditto -x -k "$bundle_zip" "$work/app"
else
    mv "$work/unpacked" "$work/app"
fi

app="$(find "$work/app" -maxdepth 1 -name '*.app' -print -quit)"
if [ -z "$app" ]; then
    echo "The download did not contain an application. Nothing was installed." >&2
    exit 1
fi

name="$(basename "$app")"
rm -rf "${app_dir:?}/$name"
mv "$app" "$app_dir/$name"

# A bundle that a *browser* downloaded carries the quarantine flag, which stops
# it from starting. `curl` does not set one, so the usual run has nothing to
# clear: ask the bundle once and say so, rather than walking fifteen thousand
# files to delete an attribute none of them has.
#
# Where there is one, the deletion is batched (`{} +`) instead of one process a
# file (`{} \;`). A shell with per-binary shims — pyenv, rbenv, asdf put one in
# front of every program on the PATH — turns each of those into a launcher of
# its own, and the walk then spends twenty minutes on what takes a second, with
# nothing on screen to say why.
if xattr -p com.apple.quarantine "$app_dir/$name" >/dev/null 2>&1; then
    echo "Clearing the quarantine flag ..."
    find "$app_dir/$name" -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
fi

echo "Installed $app_dir/$name"
echo "Open it with:  open -a \"$app_dir/$name\""
echo "Where it keeps its data:  ~/Library/Application Support/ex-tbp-monty"
