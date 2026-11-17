#!/bin/sh
#
# The launcher inside a companion plugin app: start this node, joined to the
# window beside it.
#
#   Double-click the app. Nothing to configure and nothing to type.
#
# A companion app is `Example Plugin.app` or `Flyverse Plugin.app`, installed
# beside `Monty on the BEAM.app`. `scripts/package.sh` builds both into
# `artifacts/<platform>/`, the `.pkg` puts all three in `/Applications`, and the
# `.dmg` holds all three to drag across. This file is what the packaging puts at
# `Contents/MacOS/<the app's name>`, unchanged in both apps;
# `Contents/Resources/node` is the one line that names the release each one
# starts.
#
# ## Where the window is
#
# Beside the app and nowhere else: `MONTY_STUDIO_APP` is the one way to name a
# different one, which is how a checkout tries this without installing anything. A
# companion that searched the disk would join whichever window it found first, and
# which one that is would be nobody's decision.
#
# ## The two things it cannot guess
#
# * **the node name.** The window names itself `monty-studio-<instance id>` per
#   launch, because several copies run on one machine, so the name cannot be
#   written here. `/health` answers with it.
# * **the cookie.** `mix release` writes a `releases/COOKIE` per build, so all
#   three of these releases have different ones, and a node answering with the
#   wrong cookie is refused — and a refusal arrives as "nothing happened", which
#   is the one failure nobody can diagnose. The window's is read from its own
#   release.
#
# ## How the two meet
#
# The release dials the name it is given — `ExamplePlugin.Join`, one attempt every
# few seconds — and an OTP connection is mutual, so the window sees the plugin as
# well. It is *not* gossip: the window's own libcluster gossip is how one window
# finds another, and gossip would not carry this node anyway, because a peer found
# that way with a different cookie is refused just the same.
#
# ## A click when the window is down
#
# Opens it and waits for it to answer, then joins. Reporting "no window" about a
# window that is one double-click away is not what a companion is for.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
resources=$(cd "$here/../Resources" && pwd)
name=$(basename "$(dirname "$(dirname "$here")")" .app)
folder=$(cd "$here/../../.." && pwd)

if [ ! -r "$resources/node" ]; then
  printf '%s\n' "$name is not a plugin app: Contents/Resources/node is missing" >&2
  exit 1
fi

node=$(tr -d ' \t\r\n' <"$resources/node")
tmp=${TMPDIR:-/tmp}
log="${tmp%/}/monty-studio-$node.log"

# Appended, never truncated: a second click must not delete the log the node that
# is already running is writing. `start-plugins.sh` keeps the same file the same
# way, so the two routes leave one history rather than two.
: >>"$log" 2>/dev/null || log=/dev/null

# Everything this says goes to two places: the log (which a person can open) and
# stderr (which macOS keeps in the unified log). A message that only went to
# stderr is a click that appeared to do nothing, because a click has no terminal.
say() {
  printf '%s\n' "$*" >>"$log" 2>/dev/null || true
  printf '%s\n' "$*" >&2
}

# And a dialog, because that is what a person sees from a click. `display alert`
# is StandardAdditions rather than an automation of another application, so it
# needs no permission; where there is no `osascript` the sentence is in the log.
#
# Two ways out of it, and both are for a machine rather than a person: a shell
# that ran this one already has the sentence on stderr (`-t 2`), and a scripted
# run whose stderr is a file says `MONTY_COMPANION_SILENT=1`. A dialog nobody is
# there to dismiss is a launcher that hangs.
alert() {
  say "$*"

  if [ -n "${MONTY_COMPANION_SILENT:-}" ] || [ -t 2 ]; then
    return 0
  fi

  command -v osascript >/dev/null 2>&1 || return 0

  quoted=$(printf '%s' "$*" | sed 's/[\\"]/\\&/g')
  osascript -e "display alert \"$name\" message \"$quoted\" as warning" >/dev/null 2>&1 || true
}

die() {
  alert "$*"
  say "log: $log"
  exit 1
}

app="${MONTY_STUDIO_APP:-$folder/Monty on the BEAM.app}"

[ -d "$app" ] || die "There is no Monty Studio window beside $name.app. Put the two in the same folder — the .pkg and the .dmg install them that way — or set MONTY_STUDIO_APP to where the window is."

release="$app/Contents/Resources/plugins/$node"

[ -x "$release/bin/$node" ] || die "The window beside this app carries no plugins/$node release. Install a bundle that was packaged with the sample plugin nodes, or run scripts/package.sh again."

# The port the window prefers, read the way the window reads it:
# `MONTY_DESKTOP_PORT`, then the settings file a person can edit from Finder,
# then 42 800. A setting that is not a port is passed over rather than obeyed,
# which is what `ExTbpMonty.Desktop.Server.preferred_port/1` does with it.
window_port() {
  if [ -n "${MONTY_DESKTOP_PORT:-}" ]; then
    printf '%s' "$MONTY_DESKTOP_PORT"
    return 0
  fi

  settings="${HOME:-}/Library/Application Support/ex-tbp-monty/desktop_port"

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

# `-s` and not `-f`: a window whose database is unreachable answers `/health` with
# a 503 that still carries its node name, and a node that is in the cluster is a
# node to join whatever the database is doing.
answered() {
  curl -s --max-time 2 "http://127.0.0.1:$1/health" 2>/dev/null || true
}

port=$(window_port)
said=$(answered "$port")

if [ -z "$said" ]; then
  say "opening $app, then waiting for it to answer on port $port"
  open "$app" 2>/dev/null || die "Could not open $app."

  # Bounded: a window a few seconds from answering is worth waiting for, and the
  # one that never answers has to end in a sentence rather than a spinner.
  for _ in $(seq 1 60); do
    said=$(answered "$port")

    if [ -n "$said" ]; then
      break
    fi

    sleep 1
  done
fi

[ -n "$said" ] || die "Nothing answered on 127.0.0.1:$port, so there is no window to join. If the window had to take another port, write it in ~/Library/Application Support/ex-tbp-monty/desktop_port, or start it with MONTY_DESKTOP_PORT."

target=$(printf '%s' "$said" | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')

[ -n "$target" ] || die "The window on port $port answered without a node name: it was started with MONTY_STUDIO_CLUSTER=0, so it has nobody to join."

cookie="${MONTY_CLUSTER_SECRET:-${MONTY_COOKIE:-}}"

if [ -z "$cookie" ]; then
  cookie_file="$app/Contents/Resources/rel/ex_tbp_monty/releases/COOKIE"
  [ -r "$cookie_file" ] || die "There is no cookie to join the window with: $cookie_file is not readable. A window started with MONTY_CLUSTER_SECRET has to give the companion apps the same variable."
  cookie=$(tr -d '\r\n' <"$cookie_file")
fi

# Pressing it twice is not an error — a running node answers, and answers is the
# whole question. A release started with `start` is not a daemon, so there is no
# pid file to look for.
if RELEASE_COOKIE="$cookie" "$release/bin/$node" rpc "true" >/dev/null 2>&1; then
  alert "$name is already running, and is in the cluster."
  exit 0
fi

say "$name: joining $target (the window answers on port $port)"

# A launcher defaults each `RELEASE_*` only while it is unset or empty, so one
# inherited from a release's own shell sends this node looking for a release
# folder of that name and version, where it dies on its first line.
unset RELEASE_VSN RELEASE_NAME RELEASE_ROOT RELEASE_NODE RELEASE_DISTRIBUTION RELEASE_TMP RELEASE_MODE

# Foreground, and `exec` rather than a child: the Dock icon is the node, so
# quitting the app stops it and nothing is left holding a port behind an app
# that looks closed.
cd "$release"
exec env RELEASE_COOKIE="$cookie" MONTY_SEEDS="$target" "./bin/$node" start >>"$log" 2>&1
