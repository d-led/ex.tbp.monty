#!/usr/bin/env bash
# Runs the desktop window: one bundle, with its server and its Python inside, no
# runtime to install.
#
#   curl -fsSL https://raw.githubusercontent.com/d-led/ex.tbp.monty/main/scripts/run-desktop.sh | bash
#
# The download lands in the folder this is run from, in a directory of its own —
# nothing is copied anywhere, nothing is registered, and deleting the folder is
# the whole of removing it. Run it again and it opens what is already there;
# `--update` takes the newest build first. What it takes is the newest **release
# asset**: CI packages the desktop only as a smoke test that packaging works and
# uploads nothing, so a build is published from a checkout (`docs/desktop.md`) and
# the release is where it lives.
#
#   --update               download the newest build even if one is here
#   --base-url URL|DIR     take ex-tbp-monty-<rid>.zip from here instead of the
#                          newest release (a directory makes it a copy, not a
#                          download: how the packaging is tried without a round
#                          trip)
#   --rid RID              another platform's build (`osx-arm64`, `linux-x64`),
#                          which is how the Linux bundle is tried from a Mac
#   --no-launch            unpack and say where the window is, do not open it
#                          (what CI runs to test this script)
#
#   EX_TBP_MONTY_DIR       where it lands (default: ./ex-tbp-monty-<rid>)
#   EX_TBP_MONTY_REPO      owner/repo to download from (default: d-led/ex.tbp.monty)
#   EX_TBP_MONTY_NO_LAUNCH 1 does what `--no-launch` does
#
# The macOS app is not signed or notarised yet (docs/desktop.md), so the first
# launch asks once: right-click, Open, Open. Everything after that is a normal
# double-click, or this script again.
#
# On macOS the download holds three apps — the window, and the two companion
# plugin apps that join it — and they are unpacked into the same folder, because
# a companion looks for its window beside itself and nowhere else. Double-click
# one of those to add that node to the window's cluster.

set -euo pipefail

repo="${EX_TBP_MONTY_REPO:-d-led/ex.tbp.monty}"
base_url="${EX_TBP_MONTY_BASE_URL:-}"
rid="${EX_TBP_MONTY_RID:-}"
update=0
launch_it=1
[ "${EX_TBP_MONTY_NO_LAUNCH:-}" = 1 ] && launch_it=0

while [ $# -gt 0 ]; do
    case "$1" in
        --update) update=1; shift ;;
        --no-launch) launch_it=0; shift ;;
        --base-url) base_url="${2:?--base-url needs a URL or a directory}"; shift 2 ;;
        --rid) rid="${2:?--rid needs a runtime id such as linux-x64}"; shift 2 ;;
        -h | --help)
            # Everything above the first blank line, so the range cannot go stale
            # when a flag is added.
            sed -n '2,/^$/{/^$/d;p;}' "$0" | sed 's/^# \{0,1\}//'
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

# Where the newest release's copy of an asset is, asked of the GitHub API. Read
# with `sed` rather than `jq`: a machine that has `curl` does not necessarily have
# `jq`, and a download URL cannot contain a double quote. Empty is the honest
# answer when there is no release, or no such asset in it.
release_asset() {
    curl -fsSL --max-time 30 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null |
        sed -n 's/.*"browser_download_url": *"\([^"]*\)".*/\1/p' |
        grep -- "/$1\$" | head -1 || true
}

if [ "$update" -eq 0 ] && [ -e "$instance" ]; then
    echo "$instance is already here."
else
    mkdir -p "$dir"

    if [ -n "$base_url" ]; then
        echo "Taking $asset from $base_url ..."
        fetch "$base_url/$asset.zip" "$dir/$asset.zip"
    else
        latest="$(release_asset "$asset.zip")"

        if [ -z "$latest" ]; then
            echo "no released $asset.zip on $repo." >&2
            echo "  A build is published from a checkout: scripts/package.sh writes it into" >&2
            echo "  artifacts/<platform>/, and the release carries what that wrote." >&2
            echo "  https://github.com/$repo/releases" >&2
            exit 1
        fi

        echo "Taking $asset from the newest release: $latest"
        fetch "$latest" "$dir/$asset.zip"
    fi

    # Said out loud, because both steps take a while and a script that prints
    # nothing for a minute reads as one that has hung.
    echo "Unpacking the download ..."
    work="$dir/.unpacked"
    rm -rf "$work"
    mkdir -p "$work"

    # The unpacker's exit code is not the gate — what the application needs is.
    # A zip of sixteen thousand files can carry an entry its tool cannot read
    # (ERTS ships `.pdb` debug symbols, one of which fails) and still hand over
    # everything, and a build that does not exist yet unpacks into an empty
    # directory. Both are answered by looking for the application below, and the
    # unpacker's own words are kept for the case where it is not there.
    unpack "$dir/$asset.zip" "$work" 2>"$work/unpack.log" || true

    # What the download held, said only when something the application needs is
    # missing: the top of the tree, and the unpacker's last words.
    say_what_it_held() {
        echo "The download did not contain an application. Nothing was run." >&2
        echo "What it does hold:" >&2
        find "$work" -maxdepth 2 -print 2>/dev/null | head -12 >&2
        if [ -s "$work/unpack.log" ]; then
            echo "The unpacker said:" >&2
            tail -5 "$work/unpack.log" >&2
        fi
        echo "Whether that build exists is on the releases page:" >&2
        echo "  https://github.com/$repo/releases" >&2
    }

    case "$rid" in
        osx-*)
            # The window's zip by name: the download carries one zip per app now,
            # and "the first `find` prints" would pick a plugin's.
            bundle_zip="$(find "$work" -maxdepth 2 -name "$asset.zip" -print -quit)"
            if [ -n "$bundle_zip" ]; then
                echo "Expanding the application (about 370 MB) ..."
                mkdir -p "$work/app"
                unpack "$bundle_zip" "$work/app" 2>>"$work/unpack.log" || true
                from="$work/app"
            else
                from="$work"
            fi

            # Named, not guessed. The download carries the window's two companion
            # plugin apps beside it, so "the first `.app` find prints" picks one of
            # three bundles by whatever order the directory happens to be in — and
            # a plugin app renamed to the window's name is a download that unpacks
            # and opens the wrong thing.
            found="$(find "$from" -maxdepth 2 -name 'Monty on the BEAM.app' -print -quit)"

            if [ -z "$found" ]; then
                say_what_it_held
                exit 1
            fi

            rm -rf "$instance"
            mv "$found" "$instance"

            # The companion apps belong beside the window — that is where each of
            # them looks for it — so they come along. By glob and not by name:
            # this script has no business knowing how many there are.
            for companion in "$(dirname "$found")"/*.app; do
                [ -d "$companion" ] || continue
                rm -rf "$dir/$(basename "$companion")"
                mv "$companion" "$dir/"
            done

            # And each plugin app is a download of its own. When the download a
            # person took carries them too, they go beside the window for the same
            # reason: a companion finds its window in its own folder.
            for extra in "$work"/*.zip; do
                [ -e "$extra" ] || continue
                [ "$(basename "$extra")" = "$asset.zip" ] && continue

                stage="$work/extra"
                rm -rf "$stage"
                mkdir -p "$stage"
                unpack "$extra" "$stage" 2>/dev/null || true

                for app in "$stage"/*.app; do
                    [ -d "$app" ] || continue
                    rm -rf "$dir/$(basename "$app")"
                    mv "$app" "$dir/"
                done
            done

            # A bundle that a *browser* downloaded carries the quarantine flag,
            # which stops it from starting. `curl` does not set one, so the usual
            # run has nothing to clear: ask each bundle once, rather than walking
            # fifteen thousand files to delete an attribute none of them has.
            #
            # Where there is one, the deletion is batched (`{} +`) instead of one
            # process a file (`{} \;`). A shell with per-binary shims — pyenv,
            # rbenv, asdf put one in front of every program on the PATH — turns
            # each of those into a launcher of its own, and the walk then spends
            # twenty minutes on what takes a second, with nothing on screen to
            # say why.
            for app in "$dir"/*.app; do
                [ -d "$app" ] || continue
                if xattr -p com.apple.quarantine "$app" >/dev/null 2>&1; then
                    echo "Clearing the quarantine flag ..."
                    find "$app" -exec xattr -d com.apple.quarantine {} + 2>/dev/null || true
                fi
            done
            ;;
        linux-*)
            # What the Linux build leaves is a tarball holding the window with
            # its release beside it — the bundle Tauri makes is a `.deb`, which a
            # distribution installs, and it travels in the same download for
            # whoever wants that instead.
            tarball="$(find "$work" -maxdepth 2 -name '*.tar.gz' -print -quit)"
            if [ -z "$tarball" ]; then
                say_what_it_held
                exit 1
            fi

            echo "Expanding the application (about 370 MB) ..."
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
if [ "$launch_it" -eq 0 ]; then
    echo "Not launching: $instance"
else
    echo "Running $instance"
    launch
fi

case "$rid" in
    osx-*) echo "Where it keeps its data:  ~/Library/Application Support/ex-tbp-monty" ;;
    linux-*) echo "Where it keeps its data:  ${XDG_DATA_HOME:-$HOME/.local/share}/ex-tbp-monty" ;;
esac
