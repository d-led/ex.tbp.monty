#!/usr/bin/env bash
#
# The window, opened the way a person opens it.
#
# Every other check of a desktop build asks the *server* a question:
# `scripts/boot-check.sh` starts the release and fetches `/health` and
# `/prerequisites`, and both answered while a window showed nothing at all —
# the shape that shipped once, and the shape the sibling project shipped too,
# where the window judged its own page a foreign link and opened the browser
# instead. So this starts the executable that ships and waits for the window to
# say what it **drew**: the layout's `Painted` hook sends the page's heading and
# the ids on it to `/__painted`, and only a webview that ran the page can send
# one.
#
#   scripts/smoke-window.sh [--window PATH] [--port N] [--expect-mark ID]
#                           [--up-seconds N] [--seconds N]
#
# It asserts structure, not pixels: a screenshot of a person's desktop is not
# something a test should take, and a runner with no graphics session has no
# screen to photograph anyway.
#
# `HOME` is a scratch directory, so this never opens the catalogue the person
# running it is using. On Windows the application's folder is `%APPDATA%`, which
# no environment variable here moves — so there this wants no other copy of the
# tool open.
#
# A machine with no display (a Linux runner) gets Xvfb when it is installed. A
# window that never opens is one fault; a window that opens on nothing is
# another, and they are told apart by asking `/health` first and the paint
# report second.
set -uo pipefail

cd "$(dirname "$0")/.."

case $(uname -s) in
  Darwin) platform=macos ;;
  MINGW* | MSYS* | CYGWIN*) platform=windows ;;
  *) platform=linux ;;
esac

# What `scripts/package.sh` and `scripts/package.ps1` write, per platform. Any
# other build is named with `--window`.
case $platform in
  macos) default_window="artifacts/osx-arm64/Monty on the BEAM.app/Contents/MacOS/ex-tbp-monty-desktop" ;;
  windows) default_window="artifacts/win-x64/ex-tbp-monty-win-x64/ex-tbp-monty-desktop.exe" ;;
  *) default_window="artifacts/linux-x64/ex-tbp-monty-linux-x64/ex-tbp-monty-desktop" ;;
esac

window=$default_window
# The page a launch lands on: the front door, and the heading and boxes on it
# are what this build promises to show. A window that loads without them is a
# window showing something inert.
expect_mark=welcome-hero
port=${MONTY_DESKTOP_PORT:-43997}
up_seconds=90
seconds=60

while [[ $# -gt 0 ]]; do
  case $1 in
    --window) window=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --expect-mark) expect_mark=$2; shift 2 ;;
    --up-seconds) up_seconds=$2; shift 2 ;;
    --seconds) seconds=$2; shift 2 ;;
    -h | --help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x $window ]]; then
  echo "no window at $window" >&2
  echo "(build it with scripts/package.sh, or point --window at one)" >&2
  exit 1
fi

# The release steps around a port that is taken, and a launch that answered on
# some other number would leave this script polling nothing.
if curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/health"; then
  echo "something already answers on 127.0.0.1:$port - pass --port with a free one" >&2
  exit 1
fi

home=$(mktemp -d)
log=$(mktemp)

runner=()
if [[ $platform == linux && -z ${DISPLAY:-} ]] && command -v xvfb-run >/dev/null; then
  runner=(xvfb-run -a --server-args="-screen 0 1280x1024x24")
fi

# `WEBKIT_DISABLE_COMPOSITING_MODE` and `NO_AT_BRIDGE` are for a webview on a
# machine with no graphics hardware and no accessibility bus, which is what a
# container is: without them WebKitGTK can fail to draw anything at all, and the
# report this script waits for would never come.
#
# `MONTY_DESKTOP_PORT` is inherited by the release the window starts, which is
# how a caller outside the window learns where to ask.
launch=(
  env HOME="$home" MONTY_DESKTOP_PORT="$port"
  WEBKIT_DISABLE_COMPOSITING_MODE=1 NO_AT_BRIDGE=1
)
[[ ${#runner[@]} -gt 0 ]] && launch+=("${runner[@]}")
launch+=("$window")

"${launch[@]}" >"$log" 2>&1 &
pid=$!

stop() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$home" "$log"
}

fail() {
  echo "$1" >&2
  echo "--- what the window said:" >&2
  tail -25 "$log" >&2
  stop
  exit 1
}

up=
for i in $(seq 1 "$up_seconds"); do
  if curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    up=yes
    break
  fi

  [[ $((i % 15)) -eq 0 ]] && echo "waiting for the server on 127.0.0.1:$port (${i}s)"

  sleep 1
done

if [[ -z $up ]]; then
  if kill -0 "$pid" 2>/dev/null; then
    fail "the window is running but never served 127.0.0.1:$port within ${up_seconds}s"
  fi

  wait "$pid" 2>/dev/null
  fail "the window exited before it started a server (exit $?)"
fi

painted=
for _ in $(seq 1 "$seconds"); do
  if painted=$(curl -fsS -m 2 "http://127.0.0.1:$port/__painted" 2>/dev/null); then
    break
  fi

  painted=
  sleep 1
done

if [[ -z $painted ]]; then
  fail "the server is up but no window drew a screen - it opened on nothing"
fi

printf '%s\n' "$painted"

heading=$(printf '%s\n' "$painted" | sed -n 's/^heading: //p')
marks=$(printf '%s\n' "$painted" | sed -n 's/^marks: //p')

[[ -n $heading ]] || fail "the window drew a screen with no heading on it"

case ",$marks," in
  *",$expect_mark,"*) ;;
  *) fail "the window drew \"$heading\" but it has no '$expect_mark' (it has: ${marks:-none})" ;;
esac

echo "the window shows \"$heading\" and carries '$expect_mark'"

stop
exit 0
