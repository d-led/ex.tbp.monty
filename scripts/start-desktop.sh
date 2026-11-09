#!/usr/bin/env bash
#
# Opens the desktop window.
#
#   scripts/start-desktop.sh               build both halves, then open the window
#   scripts/start-desktop.sh --in-browser  build the release, then serve it here
#   scripts/start-desktop.sh --where       build the release, then print where its data is
#   scripts/start-desktop.sh --bundle      build the double-clickable .app, then print its path
#   scripts/start-desktop.sh --app         build the .app, then open it
#
# What it opens is the native window: `src-tauri`, which starts the Elixir
# release as its sidecar, reads the address that release prints, and points a
# webview at it. The window adds no behaviour — every screen is the sidecar's,
# which is also the binary a headless machine runs (`--in-browser`), so the
# desktop and the server cannot drift apart.
#
# Nothing here is captured, backgrounded or piped: every command writes to this
# terminal as it runs, and the first one that fails stops the script with that
# command's status and that command's own complaint.
#
# A machine that has never built this asks for four things and is given the rest:
# `mix`, `cargo`, `npm` and the Xcode command line tools are named if they are
# absent, while Hex, rebar, the dependencies and the Tauri CLI install themselves.
# The first message a fresh checkout prints should be what to install, not a build
# that dies at its last step.

set -euo pipefail

cd "$(dirname "$0")/.."

name=ex_tbp_monty
release="_build/desktop/rel/$name"
binary="$PWD/$release/bin/$name"
sidecar="$PWD/$release/bin/server"
window="src-tauri/target/debug/ex-tbp-monty-desktop"

# The double-clickable app: the window plus a copy of the release inside it, so
# it runs without this checkout and without this script. macOS has one file to
# name; Linux has a directory of bundles, one per format Tauri can make.
bundle="src-tauri/target/release/bundle/macos/Monty on the BEAM.app"

# Bundling is a separate config, merged only for `--app`: `bundle.active` in the
# main config makes `cargo build` — the debug window this script opens every run
# — fail in tauri-build's resource phase, and the debug window has no use for a
# bundle. What each platform makes is that file's own `targets`, and nothing
# here repeats it: a `--bundles` flag alongside the config overrode the list,
# which is how an AppImage named in `tauri.bundle.linux.json` was never built
# while the job stayed green.
case "$(uname -s)" in
  Darwin)
    bundle_config="$PWD/src-tauri/tauri.bundle.conf.json"
    ;;
  Linux)
    bundle_config="$PWD/src-tauri/tauri.bundle.linux.json"
    ;;
  *)
    echo "scripts/start-desktop.sh bundles macOS and Linux; this is $(uname -s)." >&2
    echo "Windows has its own: scripts/start-desktop.ps1 -Bundle." >&2
    exit 69
    ;;
esac

mode=open

usage() {
  echo "scripts/start-desktop.sh [--in-browser | --where | --bundle | --app]"
  echo
  echo "  (no flags)     build the release and the window, then open the window"
  echo "  --in-browser   build the release, then serve it in this terminal"
  echo "  --where        build the release, then print where its data is"
  echo "  --bundle       build the .app bundle, then print where it is"
  echo "  --app          build the .app bundle, then open it"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-browser) mode=browser; shift ;;
    --where) mode=where; shift ;;
    --bundle) mode=bundle; shift ;;
    --app) mode=app; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      echo "unknown option: $1"
      usage
      exit 64
      ;;
  esac
done

# Every directory of the assembled release that holds a shared library, as a
# search path. Absolute, because the loader resolves a relative entry against
# whatever directory the process it is set for happens to run in — and linuxdeploy
# runs from `src-tauri`. `-printf` is GNU find's, which is what this branch runs
# on.
bundled_library_path() {
  find "$PWD/_build/desktop/rel/ex_tbp_monty" -name '*.so*' -printf '%h\n' | sort -u | paste -sd:
}

# One line before and one after, so a long build is visibly alive and a slow step
# is visibly the slow one. No redirection: the tools' own output is the thing
# worth reading when something goes wrong.
steps=0
run() {
  local started=$SECONDS
  steps=$((steps + 1))
  echo
  echo "[$steps] $1"
  shift
  "$@"
  echo "[$steps] ok in $((SECONDS - started))s"
}

# Building every time is deliberate. The window carries its own copy of the
# release (`bundle.resources` in tauri.bundle.conf.json, refreshed by
# `cargo build`), so an Elixir-only change that skipped the release step would
# leave the window starting the copy it made hours earlier.

# What a build cannot happen without, asked once here rather than discovered
# fifteen steps in as "no such file". `npm` is as load-bearing as the other two:
# `assets/js` imports packages, and esbuild resolves them from
# `assets/node_modules`.
require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "missing: $1 — $2"
  exit 69
}

require mix "Elixir and Mix — https://elixir-lang.org/install.html"
require cargo "the Rust toolchain — https://rustup.rs"
require npm "Node.js — https://nodejs.org (the scripts import npm packages)"

# rustler compiles this project's two NIFs with the system toolchain, and a Mac
# without the command line tools fails deep inside `mix release` with a linker
# error rather than a message about what is missing.
if [[ "$(uname -s)" == Darwin ]] && ! xcode-select -p >/dev/null 2>&1; then
  echo "missing: the Xcode command line tools — xcode-select --install"
  exit 69
fi

print_where() {
  "$binary" eval '
    alias Monty.Paths

    IO.puts("folder:      #{Paths.root()}")
    IO.puts("database:    #{Paths.database()}")
    IO.puts("data:        #{Paths.data()}")
    IO.puts("models:      #{Paths.models()}")
    IO.puts("memory:      #{Paths.libraries()}")
    IO.puts("runs:        #{Paths.artifacts()}")
  '
}

# Hex and rebar are what `mix deps.get` runs on, and a machine that has never
# built an Elixir project has neither — the fetch then stops to ask whether to
# install them, and a prompt inside a script is a hang. `--if-missing` installs
# them once and leaves an offline machine that has them alone.
run "the Hex package manager (a fresh machine has none)" mix local.hex --if-missing

run "rebar, for the dependencies that build with it" mix local.rebar --if-missing

# First, because everything after it reads the dependencies: a fresh clone has
# none, and `mix compile` — the next step — cannot start without them.
run "fetching the dependencies (a fresh clone has none)" \
  env MIX_ENV=desktop mix deps.get

run "compiling the desktop build" \
  env MIX_ENV=desktop mix compile

# The native kernels are gitignored build products in `priv/native`, written as a
# side effect of compiling the modules that `use Rustler`. A `_build` restored
# from CI's cache can carry up-to-date beams and a `priv/native` missing some of
# them, and then `mix release` assembles a release without them: it starts, and
# dies at whichever the application loads first, with "Failed to load NIF
# library".
#
# Some of them, not none. A Linux run shipped a release with `kd_tree_nif.so` and
# no `matcher_nif.so`, because the cache key named the window's Cargo.lock and not
# the crates', so one module recompiled and the other did not - and the check
# here, being "are there any kernels", was answered by the one that was there.
# Asking per crate is a question the wrong crate cannot answer.
#
# Rustler writes `kd_tree_nif.so` everywhere but Windows, where a shared library
# is a `.dll`, so each crate is looked for under this platform's spelling only.
kernels_missing() {
  local root=$1 crate name

  for crate in packages/ex_tbp_monty_core/native/*/Cargo.toml; do
    name=$(basename "$(dirname "$crate")")
    if [[ -z $(find "$root" \( -name "$name.so" -o -name "$name.dll" \) -print -quit 2>/dev/null) ]]; then
      echo "$name"
    fi
  done
}

if [ -n "$(kernels_missing priv/native)" ]; then
  run "building the native kernels (a cached build can be missing some)" \
    env MIX_ENV=desktop mix compile --force
fi

run "checking the asset toolchain (installs it once, then finds it)" \
  env MIX_ENV=desktop mix assets.install --if-missing

# Two halves, and only the second is optional on a machine that has built
# before: `assets.install` fetches the esbuild and tailwind *binaries*, while the
# packages the scripts import — driver.js among them — come from npm. A laptop
# with `assets/node_modules` already there made this look unnecessary; a fresh
# runner failed at esbuild with "Can't resolve 'driver.js/dist/driver.css'".
# `assets.build` and `assets.deploy` both start with this same line.
run "installing the packages the scripts import" \
  env MIX_ENV=desktop mix cmd --cd assets npm ci

# The screens are the server's, so the bundle has to be the server's too: CSS,
# the LiveView client, and the colocated hooks each screen carries. A release
# ships whatever `priv/static` holds and never builds it.
run "building the stylesheet" \
  env MIX_ENV=desktop mix tailwind ex_tbp_monty --minify

run "building the scripts" \
  env MIX_ENV=desktop mix esbuild ex_tbp_monty --minify

run "writing the build stamp (the footer reads it)" \
  env MIX_ENV=desktop mix build.info

# A release keeps its runtime in `erts-<vsn>`, whose name is the OTP version —
# and `mix release --overwrite` leaves an existing one alone. Two machines that
# share `_build` (a checkout mounted into a container to build the Linux bundle,
# which is how `docs/desktop.md` says to build it) then hand the second one the
# first one's `erlexec`: a Mach-O binary under Linux. The window reports it at
# the far end, as "the sidecar stopped before it said where it listens", and the
# real sentence — `erlexec: Exec format error` — is one process down.
#
# Asking the runtime to halt is the direct question, and a wrong-architecture
# binary answers it immediately. Dropping a broken one is enough: `mix release`
# copies the runtime from the OTP this machine is running.
for erts in "$release"/erts-*; do
  if [[ -d "$erts" ]] && ! "$erts/bin/erl" -noshell -eval 'halt(0)' >/dev/null 2>&1; then
    echo
    echo "the release carries a runtime this machine cannot run ($erts) — replacing it"
    rm -rf "$erts"
  fi
done

run "building the desktop release (a no-change run only reassembles it)" \
  env MIX_ENV=desktop mix release --overwrite

# And asked, rather than assumed: a release missing one kernel is a release whose
# window cannot start, and this is the last moment the build can say so with a
# sentence instead of shipping it. Per crate again, for the reason above.
missing=$(kernels_missing "$release")

if [ -n "$missing" ]; then
  echo "the release carries no native kernel for:" >&2
  echo "$missing" | sed 's/^/  /' >&2
  echo "  $release has no priv/native/*.so and no *.dll for them, and the window would start and die there" >&2
  echo "  see docs/desktop.md" >&2
  exit 1
fi

# No peers to cluster with. A distributed release has a fixed node name, so a
# second launch fails with "the name ... is in use by another Erlang node" and
# dies before it says where it listens — which the window reports as "the
# sidecar stopped before it said where it listens". Everything below runs this
# release, so it is set before the first of them.
export RELEASE_DISTRIBUTION=none

if [[ "$mode" == where ]]; then
  run "reading where the data is" print_where
  exit 0
fi

if [[ "$mode" == browser ]]; then
  echo
  echo "serving the window's own server in this terminal: it prints its address"
  echo "below, and Ctrl-C stops it. Same routes as the window, one event loop, one"
  echo "stream of output — nothing to wait for, nothing to clean up afterwards."
  echo
  exec "$sidecar"
fi

# The bundle is the same window with the release carried inside it, so it runs
# where this checkout is not: what `scripts/run-desktop.sh` puts on a machine
# and what CI uploads. `--bundle` is the build half alone, for a machine with no
# window to open; `--app` adds the opening. `open -W` waits for the app to quit,
# which is what makes this the last step of a script rather than a process left
# behind.
if [[ "$mode" == bundle || "$mode" == app ]]; then
  # `cargo tauri` is the Tauri CLI, a cargo subcommand of its own. Installing it
  # takes a few minutes once per machine; failing at the last step with "no such
  # command" throws away the build that came before it.
  if ! cargo tauri --version >/dev/null 2>&1; then
    run "installing the Tauri CLI (a fresh machine has none)" \
      cargo install tauri-cli --version "^2" --locked
  fi
  # The release is copied into the bundle by tauri-build, and it copies *over*
  # whatever is there: the previous copy keeps the release's own modes (a
  # launcher script is 0555, the `COOKIE` is 0400), so the copy fails with
  # "Permission denied (os error 13)" on every run after the first. Removing the
  # copy is cheaper than making 2 700 files writable, and nothing is lost — it is
  # a copy of `_build/desktop/rel`.
  rm -rf src-tauri/target/release/rel src-tauri/target/release/bundle

# What `linuxdeploy` needs and a build machine does not provide.
#
# The release carries a Python environment whose wheels link each other by
# soname — mujoco's extension module wants `libmujoco.so.3.17.0` from the
# directory beside it — and linuxdeploy resolves a binary's dependencies through
# the loader, which knows only the system paths. Without this the AppImage stops
# at `ERROR: Could not find dependency: libmujoco.so.3.17.0`; with it, both
# bundles are written (measured here: 510 MiB `.deb`, 427 MiB AppImage).
#
# `APPIMAGE_EXTRACT_AND_RUN=1` as well, because linuxdeploy and the AppImage
# plugin it spawns are themselves AppImages, and mounting one needs `/dev/fuse` —
# which a container and a GitHub runner do not have. Tauri passes
# `--appimage-extract-and-run` to the first of them and not to the plugin, so the
# variable is what covers the whole chain.
bundle_env=()
if [[ "$(uname -s)" == Linux ]]; then
  bundle_env=(
    APPIMAGE_EXTRACT_AND_RUN=1
    "LD_LIBRARY_PATH=$(bundled_library_path)${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  )
fi

  # `${arr[@]+"${arr[@]}"}`, because macOS ships bash 3.2, where an empty array
  # under `set -u` is an unbound variable rather than nothing to pass.
  run "building the app bundle (a minute warm, six cold — the window is rebuilt in release)" \
    env ${bundle_env[@]+"${bundle_env[@]}"} cargo tauri build --config "$bundle_config"

  if [[ "$mode" == bundle ]]; then
    echo
    # macOS has one product to name; Linux has a directory, and naming it is
    # better than naming a file whose name carries the version.
    if [[ -d "$bundle" ]]; then
      echo "$bundle"
    else
      echo "$PWD/src-tauri/target/release/bundle"
    fi
    exit 0
  fi

  echo
  echo "opening the app. Close its window to come back here; Ctrl-C leaves it running."
  echo
  run "the app" open -W "$bundle"
  exit 0
fi

run "building the window (nothing to do when neither the shell nor its config changed)" \
  cargo build --manifest-path src-tauri/Cargo.toml

# The shell is told where the sidecar is, absolutely: it would otherwise resolve
# a relative path against whatever directory it happened to be started in.
export EX_TBP_MONTY_SIDECAR="$sidecar"

# `exec` here would replace the shell with the window, so a hang shows nothing
# and an abort shows nothing either. Run it, say what happened, and pass the
# status on: a launcher that fails silently is worse than one that fails.
echo
echo "opening the window."
echo "  window:  $window"
echo "  sidecar: $sidecar"
echo "The window starts the sidecar, waits for the address it prints, and loads it."
echo "Its output follows. Ctrl-C stops both."
echo

status=0
"$window" || status=$?

echo
echo "the window exited with status $status"
exit "$status"
