#!/bin/sh
#
# Starts the two sample plugin nodes that ship with Monty Studio Desktop.
#
#   ./start-plugins.sh            # ask the running window who it is, then join it
#   ./start-plugins.sh node@host  # join a node the window does not know about
#   ./start-plugins.sh --stop     # end both
#
# The window is a **named node** (`monty-studio-<instance id>`), and the name is
# different every launch, so it cannot be written down here: it is asked for,
# over HTTP, at the address the window itself announces.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
port="${MONTY_DESKTOP_PORT:-42800}"
logs="${TMPDIR:-/tmp}"
examples="example_plugin flyverse_plugin"

# A running node answers `rpc`, and nothing else in this folder does: that is the
# question, and it is also how one is stopped — a release started with `start`
# is not a daemon, so there is no pid file to trust and the pid of the shell that
# launched it is not the VM's.
# The nodes were started with the window's cookie, so this is the one that can
# ask them anything — the release's own file is a different secret.
shared_cookie() {
  if [ -n "${MONTY_CLUSTER_SECRET:-${MONTY_COOKIE:-}}" ]; then
    printf '%s' "${MONTY_CLUSTER_SECRET:-${MONTY_COOKIE:-}}"
  elif [ -f "$here/../rel/ex_tbp_monty/releases/COOKIE" ]; then
    tr -d '\r\n' <"$here/../rel/ex_tbp_monty/releases/COOKIE"
  fi
}

answering() {
  RELEASE_COOKIE="$(shared_cookie)" "$here/$1/bin/$1" rpc "true" >/dev/null 2>&1
}

if [ "${1:-}" = "--stop" ]; then
  for example in $examples; do
    if answering "$example"; then
      RELEASE_COOKIE="$(shared_cookie)" "$here/$example/bin/$example" rpc "System.stop()" >/dev/null 2>&1 || true
      echo "  stopped $example"
    fi
  done
  exit 0
fi

for example in $examples; do
  if answering "$example"; then
    echo "the sample plugin nodes are already running; --stop ends them" >&2
    exit 0
  fi
done

target="${1:-}"

if [ -z "$target" ]; then
  # `curl` is on every macOS and almost every Linux; where it is not, the node
  # has to be named by hand, and that is a sentence rather than a stack trace.
  if ! command -v curl >/dev/null 2>&1; then
    echo "no curl to ask the window with; name its node: ./start-plugins.sh node@host" >&2
    exit 1
  fi

  answer=$(curl -fsS --max-time 3 "http://127.0.0.1:$port/health" 2>/dev/null || true)
  target=$(printf '%s' "$answer" | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')

  if [ -z "$target" ]; then
    echo "no window answered on 127.0.0.1:$port with a node name." >&2
    echo "  Is Monty Studio running? Its window prints the port it chose." >&2
    echo "  Was it started with MONTY_STUDIO_CLUSTER=0? Then it has no name to join." >&2
    exit 1
  fi
fi

echo "joining $target"

# The cluster's password. Every release carries a `releases/COOKIE` of its own —
# `mix release` writes one per build — so a plugin node started beside the window
# would be refused by the window's node and would say so only as "no answer".
# The window's cookie is the one to share, and it is right here: `rel/` is beside
# `plugins/` in every shape of the bundle. A deployment that set
# `MONTY_CLUSTER_SECRET` on the window has to set it here too, which is why the
# environment is asked first.
cookie="${MONTY_CLUSTER_SECRET:-${MONTY_COOKIE:-}}"
if [ -z "$cookie" ]; then
  cookie_file="$here/../rel/ex_tbp_monty/releases/COOKIE"
  if [ -f "$cookie_file" ]; then
    cookie=$(tr -d '\r\n' <"$cookie_file")
  fi
fi

if [ -z "$cookie" ]; then
  echo "no cookie to share with the window: is rel/ex_tbp_monty beside plugins/?" >&2
  exit 1
fi

for example in $examples; do
  log="$logs/monty-studio-$example.log"

  # The release names itself after itself (`sname`, `example_plugin@<host>`), and
  # `MONTY_SEEDS` is the one line its own `Join` module reads.
  ( cd "$here/$example" &&
    RELEASE_COOKIE="$cookie" MONTY_SEEDS="$target" ./bin/"$example" start >"$log" 2>&1 ) &
  echo "  $example: log in $log"
done

echo
echo "both are starting. Settings → Cluster lists them once they are in."
