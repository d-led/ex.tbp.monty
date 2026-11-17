#!/usr/bin/env bash
# Builds what a person can actually install, for one platform at a time:
#
#   macOS    Monty on the BEAM.app, the two companion plugin apps beside it, a
#            zip of all three, a disk image holding them, and a `.pkg` installer
#            that puts them in /Applications
#
# The three are not the same offer:
#
#   .zip   what CI uploads and `scripts/run-desktop.sh` downloads — the one
#          that needs no release to exist first
#   .pkg   double-click, the three apps appear in /Applications, and they arrive
#          without the quarantine flag (see `installer_package`)
#   .dmg   the by-hand form: drag the three apps across
#
# All of them carry the same bundle — the window, the Elixir release, the BEAM,
# the embedded Python, and the two sample plugin nodes `Settings → Cluster`
# starts — so the only difference is how a person picks it up. macOS also gets
# `Example Plugin.app` and `Flyverse Plugin.app`: the same two nodes as a
# double-click each, beside the window they join (`companion_apps`).
#
#   scripts/package.sh                 # the platform this machine is
#   scripts/package.sh osx-arm64       # one named runtime
#   scripts/package.sh all             # everything this machine can build
#   scripts/package.sh --no-dmg        # skip the disk image
#   scripts/package.sh --no-zip        # skip the zip (the app is still built)
#   scripts/package.sh --no-pkg        # skip the installer package
#
# A platform is built on a machine of that platform: the release carries a
# compiled Python, two Rust NIFs and a webview shell, none of which cross-compile
# cheaply. `all` therefore means "the host", and a platform that is named but not
# this machine's is refused rather than faked — `docs/desktop.md` says what Linux
# and Windows still need.
#
# The build asks for what it needs before it starts: `scripts/start-desktop.sh`
# names the tools that are missing and installs the four that can install
# themselves — Hex, rebar, the npm packages and the Tauri CLI — and fetches the
# dependencies before the first step that reads them.
#
# Everything lands in `artifacts/`, which is not committed.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly artifacts=artifacts
# The window's product name, which is the name of the bundle and of nothing else.
readonly product="Monty on the BEAM"
readonly bundle="src-tauri/target/release/bundle/macos/$product.app"

make_dmg=true
make_zip=true
make_pkg=true
rids=()

host_rid() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo osx-arm64 ;;
    Darwin-x86_64) echo osx-x64 ;;
    Linux-aarch64) echo linux-arm64 ;;
    Linux-x86_64) echo linux-x64 ;;
    *) echo unsupported ;;
  esac
}

for argument in "$@"; do
  case "$argument" in
    --no-dmg) make_dmg=false ;;
    --no-zip) make_zip=false ;;
    --no-pkg) make_pkg=false ;;
    all) rids+=("$(host_rid)") ;;
    osx-arm64 | osx-x64 | linux-arm64 | linux-x64 | win-x64) rids+=("$argument") ;;
    *)
      echo "usage: scripts/package.sh [all|osx-arm64|osx-x64|linux-arm64|linux-x64|win-x64] [--no-dmg] [--no-zip] [--no-pkg]" >&2
      exit 64
      ;;
  esac
done

if [ ${#rids[@]} -eq 0 ]; then
  rids+=("$(host_rid)")
fi

version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs | head -1)
version=${version:-0.1.0}

echo "$product $version: ${rids[*]}"

mkdir -p "$artifacts"

# Finder draws a bundle's icon from the LaunchServices record, and a bundle that
# was assembled a minute ago has none until something reads its Info.plist —
# which is why an app built here shows a blank icon until it has been launched
# once. Reading it now is the whole fix.
register() {
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

  touch "$1"

  if [ -x "$lsregister" ]; then
    "$lsregister" -f "$1" >/dev/null 2>&1 || echo "  could not register $1 with LaunchServices" >&2
  fi
}

# Removing something a previous run wrote, and a packaging run has to be
# repeatable over whatever that was.
#
# The write bit comes back first because what a run leaves is not this script's
# to assume: a release keeps read-only launchers (`bin/*` is 0555) and its
# `COOKIE` at 0400, and `rm -rf` empties a directory only if that directory is
# writable. A tree a crash left half-written is the same problem in a worse
# shape. Failure here is loud on purpose — `rm`'s own words, and `set -e` stops
# the run — because packing on top of a tree that could not be replaced is how a
# stale artefact gets shipped as a new one.
clean() {
  local path=$1

  [ -e "$path" ] || return 0
  chmod -R u+w "$path" 2>/dev/null || true
  rm -rf "$path"
}

# One bundle: the stylesheet, the scripts, `mix release`, and the window with
# that release copied inside it. `start-desktop.sh` owns those steps — this
# script must not have a second version of them.
#
# Tauri's bundler downloads its own tooling the first time it bundles — AppImage's
# `linuxdeploy` on Linux, NSIS and WiX on Windows — from GitHub's release CDN, and
# that CDN answered `http status: 504` on three consecutive CI runs (2026-11-08)
# while every other job passed. Bundling is idempotent, so the retry is the honest
# answer: it costs the minutes a re-run would have cost and fails the same way if
# the CDN is down for good.
build_app() {
  local attempt built=false

  # A bundle from an earlier run is not this run's answer. Tauri's bundler can
  # fail with the folder from last time still there (a copy over read-only
  # launchers is `Permission denied (os error 13)`), and the check below then read
  # that stale bundle as success — a packaging run that reported nothing wrong and
  # shipped nothing new.
  if [ -e "$bundle" ] && ! clean "$bundle"; then
    echo "cannot replace $bundle: something is holding it" >&2
    echo "  quit the app if it is open, then run this again" >&2
    return 1
  fi

  for attempt in 1 2 3; do
    if ./scripts/start-desktop.sh --bundle; then
      built=true
      break
    fi

    echo "bundling failed (attempt $attempt of 3), retrying in $((attempt * 30))s" >&2
    sleep $((attempt * 30))
  done

  if [ "$built" != true ]; then
    echo "the bundle step failed every attempt; the reason is above" >&2
    return 1
  fi

  # macOS answers with the one product this script knows the name of; Linux
  # leaves the window and its release beside each other, which is what the
  # tarball below packs.
  if [ -d "$bundle" ] || [ -x "src-tauri/target/release/ex-tbp-monty-desktop" ]; then
    return 0
  fi

  echo "the build said it finished and there is neither $bundle nor the window" >&2
  exit 1
}

# The two sample plugin nodes every shape has to carry, by the name each release
# uses for itself.
readonly plugin_nodes="example_plugin flyverse_plugin"

# The bundle, asked rather than assumed. `start-desktop.sh --bundle` builds these
# two and `bundle.resources` copies the folder into the window, which is what
# Settings → Cluster starts — but a bundle that lost them is still a valid
# bundle, and three artefacts were shipped from trees built before that step
# existed and nobody noticed. So the packaging checks its own output: a missing
# node is this script's failure, said here, not a demo a person finds empty.
carries_plugins() {
  local root=$1 node

  for node in $plugin_nodes; do
    if [ ! -x "$root/$node/bin/$node" ]; then
      echo "the bundle carries no plugins/$node/bin/$node" >&2
      echo "  looked in: $root" >&2
      echo "  they are built by scripts/build-plugins.sh during bundling, and" >&2
      echo "  scripts/start-desktop.sh --bundle is the step that runs it" >&2
      echo "  see docs/desktop.md" >&2
      ls "$root" 2>/dev/null | sed 's/^/    /' >&2
      return 1
    fi
  done
}

# The window's two companion plugin apps, by the name each shows and the release
# each one runs. An array and not a space-separated string: both names contain a
# space, and a list that is split on one makes `Example Plugin` into two apps.
companions=("Example Plugin:example_plugin" "Flyverse Plugin:flyverse_plugin")
readonly companions

# A companion app is a **launcher**, not a copy of a node: it starts the release
# the window already carries (`Contents/Resources/plugins/<node>`), so the two
# runtimes are still there once. What it adds is the click — the by-hand route in
# a bundle, which asks the window who it is (`/health`), reads the cookie it
# answers with (`releases/COOKIE`), and hands both to the release.
#
# It cannot work without the window beside it, because joining one is the whole
# of what it does; `MONTY_STUDIO_APP` is the one way to point it elsewhere, which
# is how a checkout tries it without installing anything.
#
# `scripts/desktop-plugins/companion-app.sh` is the launcher, the same file in both
# apps; `Contents/Resources/node` is the one line that tells them apart. The
# executable is named after the app rather than after the script, because that is
# the name Activity Monitor, Console and `ps` show for a node somebody is looking
# for.
companion_apps() {
  local rid=$1 pair name node app identifier

  for pair in "${companions[@]}"; do
    name=${pair%%:*}
    node=${pair##*:}
    app="$artifacts/$rid/$name.app"
    identifier="dev.ex-tbp-monty.plugin.$(printf '%s' "$node" | tr '_' '-')"

    clean "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

    cp scripts/desktop-plugins/companion-app.sh "$app/Contents/MacOS/$name"
    chmod +x "$app/Contents/MacOS/$name"
    printf '%s\n' "$node" >"$app/Contents/Resources/node"

    # The window's icon, not a new one: a missing one costs the picture and not
    # the app, so it is said rather than refused.
    if [ -f "$bundle/Contents/Resources/icon.icns" ]; then
      cp "$bundle/Contents/Resources/icon.icns" "$app/Contents/Resources/icon.icns"
    else
      echo "  $name.app wears the generic icon: the bundle has no Contents/Resources/icon.icns" >&2
    fi

    # The icons are the window's own, on purpose: these are its companions, and
    # three generic document icons in the Dock say less than three of the product
    # they belong to. What tells them apart is the name under the icon.
    cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleDisplayName</key>
	<string>$name</string>
	<key>CFBundleExecutable</key>
	<string>$name</string>
	<key>CFBundleIdentifier</key>
	<string>$identifier</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$name</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>CFBundleIconFile</key>
	<string>icon.icns</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.13</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

    register "$app"
    echo "  $app"
  done
}

# Asked of the trees this script just wrote, for the reason `carries_plugins`
# asks: an app whose launcher is not executable opens with "The application
# cannot be opened", and nothing on the way says which step lost it.
carries_companion_apps() {
  local root=$1 pair name

  for pair in "${companions[@]}"; do
    name=${pair%%:*}
    if [ ! -x "$root/$name.app/Contents/MacOS/$name" ]; then
      echo "the companion app $name.app has no launcher at Contents/MacOS/$name" >&2
      ls "$root/$name.app/Contents" 2>/dev/null | sed 's/^/    /' >&2
      return 1
    fi
  done
}

# What a Linux person gets: a tarball holding the window with its release beside
# it, which runs from anywhere, the `.deb` a distribution's package manager
# installs, and the AppImage — the release squeezed into one executable, which
# runs where nothing is installed at all. `tar`, not `zip`: the release's own
# launchers are 0555 and a zip that loses that produces an application that
# cannot start its server.
linux_bundle() {
  local rid=$1 folder="$artifacts/$1/ex-tbp-monty-$1" target="$artifacts/$1/ex-tbp-monty-$1.tar.gz"

  clean "$folder"
  rm -f "$target"
  mkdir -p "$folder"
  cp src-tauri/target/release/ex-tbp-monty-desktop "$folder/"
  cp -R src-tauri/target/release/rel "$folder/"
  # And the two sample plugin nodes, which `bundle.resources` copied out beside
  # the release: the folder is the window without an installer, so it holds
  # everything the AppImage does — `scripts/boot-check.sh` asserts it.
  cp -R src-tauri/target/release/plugins "$folder/"

  tar czf "$target" -C "$artifacts/$1" "ex-tbp-monty-$1"
  echo "  $target"

  # Two installable shapes beside the folder: the `.deb` a package manager
  # tracks, and the AppImage that runs where nothing is installed at all. The
  # AppImage is the release squeezed into one executable, so it needs no
  # unpacking step — it is the only artefact a person can download and run.
  bundle_one src-tauri/target/release/bundle/deb '*.deb' "$1"
  bundle_one src-tauri/target/release/bundle/appimage '*.AppImage' "$1"
}

# One file the bundle step made, moved beside the folder this platform ships.
# Missing is not a failure here and is not silent either: the sentence names the
# shape and where the reason is.
bundle_one() {
  local from=$1 pattern=$2 rid=$3 file

  file=$(find "$from" -name "$pattern" -print -quit 2>/dev/null || true)

  if [ -n "$file" ]; then
    cp "$file" "$artifacts/$rid/"
    echo "  $artifacts/$rid/$(basename "$file")"
  else
    # Fatal on purpose: the config asked the bundler for this shape, so a job
    # that went green without it would be shipping less than it says it does.
    echo "the bundle step made no ${pattern#\*}, and the bundle config asks for one" >&2
    echo "  see docs/desktop.md" >&2
    return 1
  fi
}

# `ditto`, not `zip`: an `.app` holds symlinks and executable modes, and a zip
# that flattens either produces an app that opens and cannot start its server.
#
# The folder is the source and the archive is written outside it: this folder now
# holds three apps, `ditto` archives one directory at a time, and writing the
# archive into the directory being read would have it archive the file it is
# still writing. The three land at the archive's root, which is the shape
# `run-desktop.sh` unpacks and the shape one app had before them.
zip_app() {
  local rid=$1 target="$artifacts/$1/ex-tbp-monty-$1.zip" beside="$artifacts/.ex-tbp-monty-$1.zip"

  rm -f "$target" "$beside"
  ditto -c -k --sequesterRsrc "$artifacts/$rid" "$beside"
  mv "$beside" "$target"
  echo "  $target"
}

# The installer a person double-clicks. What it buys over the zip is not the
# double-click: the quarantine flag is set by whatever *downloaded* the file, on
# that file — the installer then writes the payload itself, so the app it lays
# down never carries one and macOS has nothing to assess at its first launch.
#
# A `postinstall` script running `xattr -d com.apple.quarantine` is the trick
# that circulates for this. It is not needed for a payload installed this way,
# and the usual form of it (`xattr -rd`) does not exist: macOS `xattr` takes
# `-c`, `-d`, `-l`, `-p`, `-w`, `-s`, `-x`, and no `-r`, so the recursive line
# fails with "option -r not recognized" on the app it was meant to fix.
#
# What the package does *not* fix: the `.pkg` itself is unsigned, so the first
# double-click is still right-click → Open. Signing with a Developer ID is the
# fix (`docs/desktop.md`), and it is also what the app payload needs.
#
# The payload is a cpio archive, which keeps modes and symlinks for the same
# reason `zip_app` needs `ditto`.
installer_package() {
  local rid=$1 target="$artifacts/$1/monty-on-the-beam-$version.pkg" stage

  if ! command -v pkgbuild >/dev/null 2>&1; then
    echo "  no pkgbuild: no installer package for $rid" >&2
    return 0
  fi

  # The staging root is a temporary directory, not one inside `artifacts/`:
  # given a root that sits beside the package it is writing, `pkgbuild` produced a
  # 4.5 MB package of a 550 MB app, complaining "write: Permission denied" about
  # files it had just walked. The same tree in `$TMPDIR` makes a complete one.
  #
  # It prints "write: Permission denied" a few times whatever the root — a
  # three-file tree copied the same way earns four of them, and its payload still
  # lists every file. So the warnings are not the signal; the size is.
  stage="$(mktemp -d "${TMPDIR:-/tmp}/ex-tbp-monty-pkg.XXXXXX")"

  # The install location is `/`, so the paths inside the root are the paths on
  # the disk: `Applications/…` in the root is `/Applications/…` after installing.
  # All three apps go in, because a companion app finds its window by being beside
  # it — installing only the window would install a plugin you cannot click.
  mkdir -p "$stage/Applications"
  cp -R "$artifacts/$rid"/*.app "$stage/Applications/"

  # A release keeps read-only directories (the installers and the COOKIE are
  # 0555/0400), and a tree like that cannot be walked *and cleaned up* by the
  # tools that follow. The staged copy is ours to write.
  chmod -R u+w "$stage"

  # A package from an earlier run goes before this one is written: a run that
  # died before `pkgbuild` leaves a file of the right name that is not this run's
  # answer, and the next upload would take it for one.
  rm -f "$target"

  pkgbuild --root "$stage" \
    --identifier dev.ex-tbp-monty.desktop \
    --version "$version" \
    --install-location / \
    --filter '\.DS_Store$' \
    "$target"

  rm -rf "$stage"
  echo "  $target"
}

# A disk image with the app and a link to /Applications beside it — the form a
# person installs from by hand. The file is hyphenated because it travels in URLs
# and `curl` command lines; the bundle inside keeps its product name, because
# that is what the Finder shows.
disk_image() {
  # Two statements and not one `local`: macOS ships bash 3.2, where every
  # expansion in a `local a=$1 b="$x/$a"` line is evaluated against the `local`
  # that has only just been declared — so `$rid` there is unset, and `set -u`
  # ends the run with "rid: unbound variable" instead of making a disk image.
  local rid=$1 stage target
  stage="$artifacts/$rid/.dmg"
  target="$artifacts/$rid/monty-on-the-beam-$version.dmg"

  if ! command -v hdiutil >/dev/null 2>&1; then
    echo "  no hdiutil: no disk image for $rid" >&2
    return 0
  fi

  clean "$stage"
  rm -f "$target"
  mkdir -p "$stage"
  # The window and its two companion apps: each companion looks for the window in
  # the folder it was dragged into, so a disk image holding one of the three would
  # produce a plugin that says it has no window to join.
  cp -R "$artifacts/$rid"/*.app "$stage/"
  ln -s /Applications "$stage/Applications"

  # Not `-quiet`: a run failed here with the pager empty and the job's only line
  # "Process completed with exit code 1", which says nothing about why. The
  # progress line is worth more than the silence.
  hdiutil create -volname "$product $version" -srcfolder "$stage" \
    -format UDZO -ov "$target"
  rm -rf "$stage"
  echo "  $target"
}

for rid in "${rids[@]}"; do
  if [ "$rid" != "$(host_rid)" ]; then
    echo "scripts/package.sh builds $rid only on a $rid machine; this one is $(host_rid)." >&2
    echo "What a platform still needs is in docs/desktop.md." >&2
    exit 1
  fi

  echo "$rid"

  # Whatever the last run left, gone: this script's answer is the folder it
  # writes now, and a re-run has to produce that and not a mixture of the two.
  clean "$artifacts/$rid"
  clean "$artifacts/.ex-tbp-monty-$rid.zip"
  mkdir -p "$artifacts/$rid"

  case "$rid" in
    osx-*)
      build_app
      carries_plugins "$bundle/Contents/Resources/plugins" || exit 1
      cp -R "$bundle" "$artifacts/$rid/"
      register "$artifacts/$rid/$product.app"
      echo "  $artifacts/$rid/$product.app"

      # And the two nodes the window carries, one double-click each, beside the
      # window: the same releases the cluster page starts, started the way a
      # person who does not read a terminal can start them.
      companion_apps "$rid"
      carries_companion_apps "$artifacts/$rid" || exit 1

      if [ "$make_zip" = true ]; then
        zip_app "$rid"
      fi

      if [ "$make_pkg" = true ]; then
        installer_package "$rid"
      fi

      if [ "$make_dmg" = true ]; then
        disk_image "$rid"
      fi
      ;;
    linux-*)
      build_app
      carries_plugins "src-tauri/target/release/plugins" || exit 1
      linux_bundle "$rid"
      ;;
    *)
      echo "no $rid packaging here: this script makes macOS and Linux bundles." >&2
      echo "Windows has its own: scripts/package.ps1. See docs/desktop.md." >&2
      exit 1
      ;;
  esac
done

echo "done: $(find "$artifacts" -mindepth 2 -maxdepth 2 | wc -l | tr -d ' ') artifacts in $artifacts/<platform>/"
