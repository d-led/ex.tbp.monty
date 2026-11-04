#!/usr/bin/env bash
# Builds what a person can actually install, for one platform at a time:
#
#   macOS    Monty on the BEAM.app, a zip of it, a disk image holding it, and a
#            `.pkg` installer that puts it in /Applications
#
# The three are not the same offer:
#
#   .zip   what CI uploads and `scripts/run-desktop.sh` downloads — the one
#          that needs no release to exist first
#   .pkg   double-click, app appears in /Applications, and it arrives without the
#          quarantine flag (see `installer_package`)
#   .dmg   the by-hand form: drag the app across
#
# All of them carry the same bundle — the window, the Elixir release, the BEAM,
# the embedded Python — so the only difference is how a person picks it up.
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

# One bundle: the stylesheet, the scripts, `mix release`, and the window with
# that release copied inside it. `start-desktop.sh` owns those steps — this
# script must not have a second version of them.
build_app() {
  ./scripts/start-desktop.sh --bundle

  # macOS answers with the one product this script knows the name of; Linux
  # leaves the window and its release beside each other, which is what the
  # tarball below packs.
  if [ -d "$bundle" ] || [ -x "src-tauri/target/release/ex-tbp-monty-desktop" ]; then
    return 0
  fi

  echo "the build said it finished and there is neither $bundle nor the window" >&2
  exit 1
}

# What a Linux person gets: a tarball holding the window with its release beside
# it, which runs from anywhere, and the `.deb` the bundle step made, which a
# distribution's package manager installs. `tar`, not `zip`: the release's own
# launchers are 0555 and a zip that loses that produces an application that
# cannot start its server.
linux_bundle() {
  local rid=$1 folder="$artifacts/$1/ex-tbp-monty-$1" target="$artifacts/$1/ex-tbp-monty-$1.tar.gz" deb

  rm -rf "$folder" "$target"
  mkdir -p "$folder"
  cp src-tauri/target/release/ex-tbp-monty-desktop "$folder/"
  cp -R src-tauri/target/release/rel "$folder/"

  tar czf "$target" -C "$artifacts/$1" "ex-tbp-monty-$1"
  echo "  $target"

  deb=$(find src-tauri/target/release/bundle/deb -name '*.deb' -print -quit 2>/dev/null || true)
  if [ -n "$deb" ]; then
    cp "$deb" "$artifacts/$1/"
    echo "  $artifacts/$1/$(basename "$deb")"
  else
    echo "  no .deb: the bundle step made none. See docs/desktop.md." >&2
  fi
}

# `ditto`, not `zip`: an `.app` holds symlinks and executable modes, and a zip
# that flattens either produces an app that opens and cannot start its server.
zip_app() {
  local rid=$1 target="$artifacts/$1/ex-tbp-monty-$1.zip"

  rm -f "$target"
  ditto -c -k --sequesterRsrc --keepParent "$bundle" "$target"
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
  stage="$(mktemp -d "${TMPDIR:-/tmp}/ex-tbp-monty-pkg.XXXXXX")"

  # The install location is `/`, so the paths inside the root are the paths on
  # the disk: `Applications/…` in the root is `/Applications/…` after installing.
  mkdir -p "$stage/Applications"
  cp -R "$bundle" "$stage/Applications/"

  # A release keeps read-only directories (the installers and the COOKIE are
  # 0555/0400), and a tree like that cannot be walked *and cleaned up* by the
  # tools that follow. The staged copy is ours to write.
  chmod -R u+w "$stage"

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
  local rid=$1 stage="$artifacts/$rid/.dmg" target="$artifacts/$rid/monty-on-the-beam-$version.dmg"

  if ! command -v hdiutil >/dev/null 2>&1; then
    echo "  no hdiutil: no disk image for $rid" >&2
    return 0
  fi

  rm -rf "$stage" "$target"
  mkdir -p "$stage"
  cp -R "$bundle" "$stage/"
  ln -s /Applications "$stage/Applications"

  hdiutil create -quiet -volname "$product $version" -srcfolder "$stage" \
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

  rm -rf "$artifacts/$rid"
  mkdir -p "$artifacts/$rid"

  case "$rid" in
    osx-*)
      build_app
      cp -R "$bundle" "$artifacts/$rid/"
      register "$artifacts/$rid/$product.app"
      echo "  $artifacts/$rid/$product.app"

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
