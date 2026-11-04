#!/usr/bin/env bash
# Installs the desktop window: one bundle, with its server inside, no runtime to
# install.
#
#   curl -fsSL https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/install-desktop.sh | bash
#
# What it installs is the newest build of `main` — there is no release to wait
# for. A tagged release keeps the same file in the releases page, which is what
# to use for a version that has to stay put.
#
#   EX_TBP_MONTY_APP_DIR   where to put it (default: ~/Applications on macOS,
#                          ~/.local/opt on Linux)
#   EX_TBP_MONTY_REPO      owner/repo to download from (default: d-led/ex.tbp.monty)
#   EX_TBP_MONTY_BRANCH    which branch's build to take (default: main)
#   EX_TBP_MONTY_WORKFLOW  the workflow that builds it (default: ci)
#   EX_TBP_MONTY_BASE_URL  a directory holding ex-tbp-monty-<rid>.zip itself,
#                          which skips nightly.link
#   EX_TBP_MONTY_RID       install another platform's build (`osx-arm64`,
#                          `linux-x64`) — how a Linux bundle is tried from a
#                          Mac, with BASE_URL pointing at the download
#
# The macOS app is not signed or notarised yet (docs/desktop.md), so it asks
# once: right-click, Open, Open. Everything after that is a normal double-click.

set -euo pipefail

repo="${EX_TBP_MONTY_REPO:-d-led/ex.tbp.monty}"
branch="${EX_TBP_MONTY_BRANCH:-main}"
workflow="${EX_TBP_MONTY_WORKFLOW:-ci}"

case "${EX_TBP_MONTY_RID:-}" in
    "") rid="" ;;
    osx-* | linux-*) rid="$EX_TBP_MONTY_RID" ;;
    *)
        echo "EX_TBP_MONTY_RID is a runtime id such as osx-arm64 or linux-x64, not $EX_TBP_MONTY_RID." >&2
        exit 64
        ;;
esac

if [ -z "$rid" ]; then
    case "$(uname -s)" in
        Darwin) os=osx ;;
        Linux) os=linux ;;
        *)
            echo "The desktop window is built for macOS and Linux: there is no $(uname -s) build to install." >&2
            echo "What exists is in docs/desktop.md. A checkout can build its own copy:" >&2
            echo "  scripts/start-desktop.sh" >&2
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        arm64 | aarch64) arch=arm64 ;;
        x86_64 | amd64) arch=x64 ;;
        *)
            echo "No $(uname -m) build exists: the two are Apple Silicon (arm64) and x86-64." >&2
            exit 1
            ;;
    esac

    rid="$os-$arch"
fi

case "$rid" in
    osx-*) default_dir="$HOME/Applications" ;;
    linux-*) default_dir="$HOME/.local/opt" ;;
esac

app_dir="${EX_TBP_MONTY_APP_DIR:-$default_dir}"
asset="ex-tbp-monty-$rid"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() {
    case "$1" in
        # A `BASE_URL` may be a directory on this machine (`/mnt/builds`), which
        # is how the packaging is tried without a network round trip.
        #
        # The timeouts are the difference between a slow download and a script
        # that never returns: a connection nightly.link accepts and then leaves
        # idle would otherwise sit there for as long as the machine is on, which
        # reads as an infinite loop. 300 MB on a slow line is minutes; half an
        # hour is not a download any more.
        *://*)
            curl -fL --progress-bar \
                --connect-timeout 15 --retry 3 --retry-delay 2 \
                --max-time 1800 "$1" -o "$2"
            ;;
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
# its own (`BASE_URL` skips that wrapper), and the artefact is a zip of the
# bundle, because an `.app` keeps its symlinks and executable modes only in one.
# `ditto` does the macOS half; Linux has no `ditto`, so the same step goes
# through whatever that machine has.
#
# Said out loud, because both steps take a while and a script that prints
# nothing for a minute reads as one that has hung.
unpack() {
    if command -v ditto >/dev/null 2>&1; then
        ditto -x -k "$1" "$2"
    elif command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$1" -d "$2"
    else
        bsdtar -x -f "$1" -C "$2"
    fi
}

echo "Unpacking the download ..."
mkdir -p "$work/unpacked"
if ! unpack "$work/$asset.zip" "$work/unpacked"; then
    echo "The download is not a zip this machine can open, so nothing was installed." >&2
    echo "The likeliest reason is that the build does not exist yet: " >&2
    echo "  https://github.com/$repo/actions/workflows/$workflow" >&2
    exit 1
fi

instance=""
case "$rid" in
    osx-*)
        bundle_zip="$(find "$work/unpacked" -maxdepth 1 -name '*.zip' -print -quit)"
        if [ -n "$bundle_zip" ]; then
            echo "Expanding the application (about 550 MB) ..."
            mkdir -p "$work/app"
            unpack "$bundle_zip" "$work/app"
        else
            mv "$work/unpacked" "$work/app"
        fi

        bundle="$(find "$work/app" -maxdepth 1 -name '*.app' -print -quit)"
        if [ -z "$bundle" ]; then
            echo "The download did not contain an application. Nothing was installed." >&2
            exit 1
        fi

        name="$(basename "$bundle")"
        rm -rf "${app_dir:?}/$name"
        mv "$bundle" "$app_dir/$name"
        instance="$app_dir/$name"

        # A bundle that a *browser* downloaded carries the quarantine flag, which
        # stops it from starting. `curl` does not set one, so the usual run has
        # nothing to clear: ask the bundle once, rather than walking fifteen
        # thousand files to delete an attribute none of them has.
        #
        # Where there is one, the deletion is batched (`{} +`) instead of one
        # process a file (`{} \;`). A shell with per-binary shims — pyenv, rbenv,
        # asdf put one in front of every program on the PATH — turns each of
        # those into a launcher of its own, and the walk then spends twenty
        # minutes on what takes a second, with nothing on screen to say why.
        if xattr -p com.apple.quarantine "$instance" >/dev/null 2>&1; then
            echo "Clearing the quarantine flag ..."
            find "$instance" -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
        fi
        ;;
    linux-*)
        # What the Linux build leaves is a tarball holding the window with its
        # release beside it — the bundle Tauri makes is a `.deb`, which is a
        # distribution's business to install, and it travels in the same
        # download for whoever wants that instead.
        tarball="$(find "$work/unpacked" -maxdepth 2 -name '*.tar.gz' -print -quit)"
        if [ -z "$tarball" ]; then
            echo "The download did not contain an application. Nothing was installed." >&2
            exit 1
        fi

        echo "Expanding the application (about 550 MB) ..."
        mkdir -p "$app_dir"
        tar xzf "$tarball" -C "$app_dir"
        instance="$app_dir/$(basename "$tarball" .tar.gz)"

        if [ ! -x "$instance/ex-tbp-monty-desktop" ]; then
            echo "The application unpacked, but its window is not executable: $instance" >&2
            exit 1
        fi
        ;;
esac

echo "Installed $instance"
case "$rid" in
    osx-*)
        echo "Open it with:  open -a \"$instance\""
        echo "Where it keeps its data:  ~/Library/Application Support/ex-tbp-monty"
        ;;
    linux-*)
        echo "Open it with:  \"$instance/ex-tbp-monty-desktop\""
        echo "Where it keeps its data:  ${XDG_DATA_HOME:-$HOME/.local/share}/ex-tbp-monty"
        echo "The same download holds a .deb, if you would rather your package manager tracked it."
        ;;
esac
