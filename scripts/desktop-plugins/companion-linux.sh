#!/bin/sh
#
# The launcher inside a companion plugin folder on Linux: start this node, joined
# to the window beside it.
#
#   Double-click it (or its `.desktop` entry). Nothing to configure.
#
# The macOS launcher is `companion-app.sh`, and it is a different file because a
# macOS app is a bundle: the launcher is `Contents/MacOS/<name>`, the release is
# `Contents/Resources/<node>`, and a click goes through LaunchServices. Linux has
# no bundle, so the same three things sit in one folder:
#
#   ex.tbp.monty.plugin.example/
#     ex.tbp.monty.plugin.example          this launcher
#     node                                 one line: example_plugin
#     example_plugin/                      the release, with its own runtime
#     ex.tbp.monty.plugin.example.desktop  the entry a file manager opens
#
# and the window is the binary (or AppImage) beside that folder. Everything else
# is the same contract as the macOS one, for the same reason:
#
# * the node name is what `/health` says, because the window names itself per
#   launch (`monty-studio-<instance id>`) and several copies run on one machine;
# * this node's own name is `<node>_app@127.0.0.1` — not the release's, because
#   `epmd` keys on the bare name and a checkout runs the same plugin as
#   `example_plugin@127.0.0.1`, and long on the loopback, because a short name
#   is resolved through DNS when the two dial each other;
# * the cookie is the window's own `releases/COOKIE`, because `mix release` writes
#   one per build and a peer with a different one is refused — which arrives as
#   "nothing happened", the one failure nobody can diagnose;
# * a click when the window is down opens it and waits: reporting "no window"
#   about one that is a double-click away is not what a companion is for.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
name=$(basename "$here")
folder=$(cd "$here/.." && pwd)

if [ ! -r "$here/node" ]; then
  printf '%s\n' "$name is not a plugin folder: node is missing beside the launcher" >&2
  exit 1
fi

node=$(tr -d ' \t\r\n' <"$here/node")
app_node="${node}_app"
tmp=${TMPDIR:-/tmp}
log="${tmp%/}/monty-studio-$node.log"

# Appended, never truncated: a second click must not delete the log the node
# already running is writing.
: >>"$log" 2>/dev/null || log=/dev/null

say() {
  printf '%s\n' "$*" >>"$log" 2>/dev/null || true
  printf '%s\n' "$*" >&2
}

die() {
  say "$*"
  say "log: $log"
  exit 1
}

# The window: the binary beside this folder, an AppImage beside it, or whatever
# `MONTY_STUDIO_APP` names. A companion that searched the disk would join whichever
# window it found first, and which one that is would be nobody's decision.
window="${MONTY_STUDIO_APP:-}"

if [ -z "$window" ]; then
  for candidate in "$folder/ex-tbp-monty-desktop" "$folder"/*.AppImage; do
    if [ -x "$candidate" ] && [ -f "$candidate" ]; then
      window=$candidate
      break
    fi
  done
fi

[ -n "$window" ] && [ -x "$window" ] ||
  die "There is no Monty Studio window beside $name. Put the two in the same folder, or set MONTY_STUDIO_APP to the window's binary."

# Where the window's release is: beside its own binary, whether that is a folder
# this distribution unpacked or an AppImage that unpacks itself.
window_dir=$(dirname "$window")
release_dir="$window_dir/rel/ex_tbp_monty"

release="$here/$node"
[ -x "$release/bin/$node" ] ||
  die "This folder carries no $node release. It was packaged without one: rebuild it with scripts/package.sh."

window_port() {
  if [ -n "${MONTY_DESKTOP_PORT:-}" ]; then
    printf '%s' "$MONTY_DESKTOP_PORT"
    return 0
  fi

  settings="${XDG_CONFIG_HOME:-${HOME:-}/.config}/ex-tbp-monty/desktop_port"

  if [ -r "$settings" ]; then
    port=$(tr -d ' \t\r\n' <"$settings")

    case "$port" in
      '' | *[!0-9]*) : ;;
      *)
        printf '%s' "$port"
        return 0
        ;;
    esac
  fi

  printf '42800'
}

command -v curl >/dev/null 2>&1 || die "There is no curl to ask the window with."

# `-s` and not `-f`: the name in the body is what this needs, and a window that
# answers 503 still names the node it is.
answered() {
  curl -s --max-time 2 "http://127.0.0.1:$1/health" 2>/dev/null || true
}

port=$(window_port)
said=$(answered "$port")

if [ -z "$said" ]; then
  say "opening $window, then waiting for it to answer on port $port"
  # `setsid` where it exists: the window has to outlive this launcher, and a
  # terminal that closes sends SIGHUP to what it started.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$window" >>"$log" 2>&1 &
  else
    "$window" >>"$log" 2>&1 &
  fi

  for _ in $(seq 1 60); do
    said=$(answered "$port")

    if [ -n "$said" ]; then
      break
    fi

    sleep 1
  done
fi

[ -n "$said" ] ||
  die "Nothing answered on 127.0.0.1:$port, so there is no window to join. If the window took another port, write it in ~/.config/ex-tbp-monty/desktop_port, or start it with MONTY_DESKTOP_PORT."

target=$(printf '%s' "$said" | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')

[ -n "$target" ] ||
  die "The window on port $port answered without a node name: it was started with MONTY_STUDIO_CLUSTER=0, so it has nobody to join."

cookie="${MONTY_CLUSTER_SECRET:-${MONTY_COOKIE:-}}"

if [ -z "$cookie" ]; then
  cookie_file="$release_dir/releases/COOKIE"
  [ -r "$cookie_file" ] ||
    die "There is no cookie to join the window with: $cookie_file is not readable. A window started with MONTY_CLUSTER_SECRET has to give the companion the same variable."
  cookie=$(tr -d '\r\n' <"$cookie_file")
fi

# Pressing it twice is not an error: a running node answers, and answers is the
# whole question. A release started with `start` is not a daemon, so there is no
# pid file to look for.
if RELEASE_COOKIE="$cookie" RELEASE_DISTRIBUTION=name RELEASE_NODE="${app_node}@127.0.0.1" \
  "$release/bin/$node" rpc "true" >/dev/null 2>&1; then
  say "$name is already running, and is in the cluster."
  exit 0
fi

# A name `epmd` already holds that did not answer above is another VM, and the
# release started below would die with "the name … seems to be in use by another
# Erlang node" — a sentence a click has nowhere to show.
epmd_bin=$(ls "$release"/erts-*/bin/epmd 2>/dev/null | head -1)

if [ -n "$epmd_bin" ] && "$epmd_bin" -names 2>/dev/null | grep -q "^name ${app_node} at "; then
  die "A node called $app_node is already running on this machine, and it answers with a cookie this app does not have. Stop it, then start this one again."
fi

say "$name: joining $target (the window answers on port $port)"

# A launcher defaults each `RELEASE_*` only while it is unset, so one inherited
# from a release's own shell sends this node looking for a release folder of that
# name and version, where it dies on its first line.
unset RELEASE_VSN RELEASE_NAME RELEASE_ROOT RELEASE_NODE RELEASE_DISTRIBUTION RELEASE_TMP RELEASE_MODE

cd "$release"
exec env RELEASE_COOKIE="$cookie" RELEASE_DISTRIBUTION=name \
  RELEASE_NODE="${app_node}@127.0.0.1" MONTY_SEEDS="$target" \
  "./bin/$node" start >>"$log" 2>&1
