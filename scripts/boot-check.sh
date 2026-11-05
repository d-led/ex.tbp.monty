#!/usr/bin/env bash
#
# Starts the release a bundle carries and asks whether it is alive.
#
#   scripts/boot-check.sh <release directory>
#
# The window is Tauri plus a sidecar, and the part that can be wrong without
# anything in this repository noticing is the sidecar: a release that carries the
# wrong runtime, a launcher whose paths lost their separators, a release whose
# `bin` folder never made it into the download. All three of those shipped once.
# What a person experiences for any of them is a window that never appears, and
# what a runner can check is the same thing without a window: start the entry
# point the bundle holds and ask `/health`.
#
# The port comes from `MONTY_DESKTOP_PORT`, which is what the desktop server
# reads. It exits 0 only when the release answers.
#
# Used by the `desktop` job in CI, which is where the Windows release is started
# on Windows — `docs/desktop.md` says what that buys.
set -euo pipefail

release="${1:?a release directory, the one the bundle carries}"
port="${MONTY_DESKTOP_PORT:-43999}"

entry="$release/bin/server"
[ -f "$entry" ] || {
  echo "no server entry point at $entry" >&2
  exit 1
}

export RELEASE_DISTRIBUTION=none
export MONTY_DESKTOP_PORT="$port"

log="$(mktemp "${TMPDIR:-/tmp}/boot-check.XXXXXX")"

# A `.bat` is what Windows has, and `cmd` is what runs it: a path with spaces in
# it (`…\Monty on the BEAM\…`) is split by `cmd` alone, so the quoting is the
# same two lines `src-tauri/src/main.rs` uses.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    # `cmd` needs a Windows path; this shell holds a POSIX one. `cygpath` is what
    # Git Bash ships for exactly that translation.
    cmd //c call "$(cygpath -w "$entry")" >"$log" 2>&1 &
    ;;
  *) "$entry" >"$log" 2>&1 & ;;
esac

pid=$!

# Whether a process with this id is still there, asked the way the platform can
# answer: `kill -0` only knows about processes this bash started on some
# platforms, and `tasklist` is what Windows has.
still_running() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -q "[0-9]"
      ;;
    *) kill -0 "$1" 2>/dev/null ;;
  esac
}

cleanup() {
  # A process tree on Windows: `cmd` starts the batch file, which starts the VM,
  # and killing the first of the three leaves the other two holding the port.
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true ;;
    *) kill "$pid" 2>/dev/null || true ;;
  esac

  # Bounded, and never `wait`: a check that waits for a process which will not
  # die is a check that hangs instead of failing. This one did on Windows — the
  # release answered `/health` and `/prerequisites` at 13:05 and the step was
  # still open when the job's hour ran out, which says nothing about the release
  # and everything about the cleanup.
  for _ in $(seq 1 10); do
    still_running "$pid" || break
    sleep 1
  done

  if still_running "$pid"; then
    echo "boot check: the release is still running (pid $pid) after being told to stop" >&2
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN*) taskkill //F //PID "$pid" >/dev/null 2>&1 || true ;;
      *) kill -9 "$pid" 2>/dev/null || true ;;
    esac
  fi

  rm -f "$log"
}
trap cleanup EXIT

answered=
for _ in $(seq 1 120); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/health" 2>/dev/null; then
    answered=1
    echo "the release answered /health on $port"
    break
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "the release stopped before it answered, saying:" >&2
    cat "$log" >&2
    exit 1
  fi

  sleep 1
done

if [ -z "$answered" ]; then
  echo "the release did not answer /health on $port within two minutes, saying:" >&2
  tail -20 "$log" >&2
  exit 1
fi

# Then the page that reads the disk, because a release can be alive and still
# have nothing to say about the disk it writes to: it did, on Windows, while
# `df` — a program that platform does not have — was how the room was read, and
# the page said "the operating system did not say how much room is left".
#
# Asked over HTTP, on every platform, because that is the way a person asks it.
page="$(curl -fsS --max-time 60 "http://127.0.0.1:$port/prerequisites")" || {
  echo "the release did not answer /prerequisites on $port" >&2
  tail -20 "$log" >&2
  exit 1
}

case "$page" in
  *"did not say how much room"*)
    echo "the release cannot name the room behind its own roots:" >&2
    grep -o "nothing in [^<]*\|did not say[^<]*" <<<"$page" >&2 || true
    exit 1
    ;;
  *" free of "*)
    echo "the release names the room left behind its roots"
    ;;
  *)
    echo "the release's /prerequisites says no room at all" >&2
    exit 1
    ;;
esac

exit 0
