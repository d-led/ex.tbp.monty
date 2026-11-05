#!/usr/bin/env bash
# Runs the desktop window: one bundle, with its server and its Python inside, no
# runtime to install.
#
#   curl -fsSL https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/run-desktop.sh | bash
#
# The download lands in the folder this is run from, in a directory of its own —
# nothing is installed, nothing is registered, and deleting the folder is the
# whole of uninstalling it. Run it again and it opens what is already there;
# `--update` takes the newest build first. What it takes is the newest build of
# `main`, and the same file attached to a tagged release, which is what to use
# for a version that has to stay put.
#
#   --update               download the newest build even if one is here
#   --base-url URL|DIR     take ex-tbp-monty-<rid>.zip from here instead of
#                          nightly.link (a directory makes it a copy, not a
#                          download: how the packaging is tried without a round
#                          trip)
#   --rid RID              another platform's build (`osx-arm64`, `linux-x64`),
#                          which is how the Linux bundle is tried from a Mac
#
#   EX_TBP_MONTY_DIR       where it lands (default: ./ex-tbp-monty-<rid>)
#   EX_TBP_MONTY_REPO      owner/repo to download from (default: d-led/ex.tbp.monty)
#   EX_TBP_MONTY_BRANCH    which branch's build to take (default: main)
#   EX_TBP_MONTY_WORKFLOW  the workflow that builds it (default: ci)
#
# The macOS app is not signed or notarised yet (docs/desktop.md), so the first
# launch asks once: right-click, Open, Open. Everything after that is a normal
# double-click, or this script again.

set -euo pipefail

repo="${EX_TBP_MONTY_REPO:-d-led/ex.tbp.monty}"
branch="${EX_TBP_MONTY_BRANCH:-main}"
workflow="${EX_TBP_MONTY_WORKFLOW:-ci}"
base_url="${EX_TBP_MONTY_BASE_URL:-}"
rid="${EX_TBP_MONTY_RID:-}"
update=0

while [ $# -gt 0 ]; do
    case "$1" in
        --update) update=1; shift ;;
        --base-url) base_url="${2:?--base-url needs a URL or a directory}"; shift 2 ;;
        --rid) rid="${2:?--rid needs a runtime id such as linux-x64}"; shift 2 ;;
        -h | --help)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 64
            ;;
    esac
done

case "$rid" in
    "") ;;
    osx-* | linux-*) ;;
    *)
        echo "--rid takes a runtime id such as osx-arm64 or linux-x64, not $rid." >&2
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

# What the workflow builds, and nothing else. A machine of another kind would
# otherwise ask `nightly.link` for an asset no job uploads, get a 404, and be told
# "the build does not exist yet" about a build nobody makes. `--base-url` is
# exempt: that is how a bundle built on this machine is tried.
if [ -z "$base_url" ]; then
    case "$rid" in
        osx-arm64 | linux-x64) ;;
        *)
            echo "There is no published $rid build: the workflow makes osx-arm64 and linux-x64." >&2
            echo "A machine of this kind makes its own — scripts/start-desktop.sh from a checkout," >&2
            echo "or scripts/package.sh $rid on a machine like this one (docs/desktop.md)." >&2
            exit 1
            ;;
    esac
fi

asset="ex-tbp-monty-$rid"
dir="${EX_TBP_MONTY_DIR:-$PWD/$asset}"

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

# Where the application sits once it is unpacked, so that "is it here already"
# and "open it" each have one answer rather than a search.
case "$rid" in
    osx-*)
        instance="$dir/Monty on the BEAM.app"
        launch() { open -a "$instance"; }
        ;;
    linux-*)
        instance="$dir/$asset"
        launch() { "$instance/ex-tbp-monty-desktop"; }
        ;;
esac

unpack() {
    if command -v ditto >/dev/null 2>&1; then
        ditto -x -k "$1" "$2"
    elif command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$1" -d "$2"
    else
        bsdtar -x -f "$1" -C "$2"
    fi
}

if [ "$update" -eq 0 ] && [ -e "$instance" ]; then
    echo "$instance is already here."
else
    mkdir -p "$dir"

    if [ -n "$base_url" ]; then
        echo "Taking $asset from $base_url ..."
        fetch "$base_url/$asset.zip" "$dir/$asset.zip"
    else
        latest="https://nightly.link/$repo/workflows/$workflow/$branch/$asset.zip"
        echo "Taking the newest $branch build: $latest"
        fetch "$latest" "$dir/$asset.zip"
    fi

    # Said out loud, because both steps take a while and a script that prints
    # nothing for a minute reads as one that has hung.
    echo "Unpacking the download ..."
    work="$dir/.unpacked"
    rm -rf "$work"
    mkdir -p "$work"
    if ! unpack "$dir/$asset.zip" "$work"; then
        echo "The download is not a zip this machine can open, so nothing was run." >&2
        echo "The likeliest reason is that the build does not exist yet: " >&2
        echo "  https://github.com/$repo/actions/workflows/$workflow" >&2
        exit 1
    fi

    case "$rid" in
        osx-*)
            bundle_zip="$(find "$work" -maxdepth 1 -name '*.zip' -print -quit)"
            if [ -n "$bundle_zip" ]; then
                echo "Expanding the application (about 550 MB) ..."
                mkdir -p "$work/app"
                unpack "$bundle_zip" "$work/app"
                found="$(find "$work/app" -maxdepth 1 -name '*.app' -print -quit)"
            else
                found="$(find "$work" -maxdepth 1 -name '*.app' -print -quit)"
            fi

            if [ -z "$found" ]; then
                echo "The download did not contain an application. Nothing was run." >&2
                exit 1
            fi

            rm -rf "$instance"
            mv "$found" "$instance"

            # A bundle that a *browser* downloaded carries the quarantine flag,
            # which stops it from starting. `curl` does not set one, so the usual
            # run has nothing to clear: ask the bundle once, rather than walking
            # fifteen thousand files to delete an attribute none of them has.
            #
            # Where there is one, the deletion is batched (`{} +`) instead of one
            # process a file (`{} \;`). A shell with per-binary shims — pyenv,
            # rbenv, asdf put one in front of every program on the PATH — turns
            # each of those into a launcher of its own, and the walk then spends
            # twenty minutes on what takes a second, with nothing on screen to
            # say why.
            if xattr -p com.apple.quarantine "$instance" >/dev/null 2>&1; then
                echo "Clearing the quarantine flag ..."
                find "$instance" -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
            fi
            ;;
        linux-*)
            # What the Linux build leaves is a tarball holding the window with
            # its release beside it — the bundle Tauri makes is a `.deb`, which a
            # distribution installs, and it travels in the same download for
            # whoever wants that instead.
            tarball="$(find "$work" -maxdepth 2 -name '*.tar.gz' -print -quit)"
            if [ -z "$tarball" ]; then
                echo "The download did not contain an application. Nothing was run." >&2
                exit 1
            fi

            echo "Expanding the application (about 550 MB) ..."
            rm -rf "$instance"
            tar xzf "$tarball" -C "$dir"

            if [ ! -x "$instance/ex-tbp-monty-desktop" ]; then
                echo "The application unpacked, but its window is not executable: $instance" >&2
                exit 1
            fi
            ;;
    esac

    rm -rf "$work"
fi

# The macOS `.app` is still kept out of the zip's own directory: nothing is
# registered with LaunchServices, so `open -a` on the path is the whole of it.
echo "Running $instance"
launch

case "$rid" in
    osx-*) echo "Where it keeps its data:  ~/Library/Application Support/ex-tbp-monty" ;;
    linux-*) echo "Where it keeps its data:  ${XDG_DATA_HOME:-$HOME/.local/share}/ex-tbp-monty" ;;
esac
