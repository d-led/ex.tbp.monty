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

# Started the way the window starts it, and that is the point of this check: the
# sidecar is a *named* node now, `monty-studio-<instance id>`, and the name is what
# the sample plugins shipped beside the application dial. A release that names
# itself after the release (`sname` and nothing else) starts and answers, and then
# no plugin finds it — the failure `run-desktop.sh` would report as "the window is
# up and there is nothing to connect to".
export EX_TBP_MONTY_WINDOW=1
export MONTY_DESKTOP_PORT="$port"

# The name is pinned for this check, and the pin is what makes the rest possible:
# the second VM `rpc` starts runs the same `env.sh`, would generate an instance id
# of its own, and would then dial a node that is not there. Pinned, the check can
# assert the exact name — a launcher that ignored the variable still answers
# `/health`, with a random name, and a launcher that set nothing answers `nohost`.
export MONTY_STUDIO_INSTANCE_ID=bootcheck

# The release's own launcher, which is the `.bat` on Windows.
launcher="$release/bin/ex_tbp_monty"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) launcher="$launcher.bat" ;;
esac

log="$(mktemp "${TMPDIR:-/tmp}/boot-check.XXXXXX")"

# The window's other contract, and the reason this file has a fifo: the desktop's
# own `ExTbpMonty.Desktop.Application` stops the server when its standard input
# reaches end of file — that is the window going away — and a runner gives a
# background process a stdin already at EOF. Started that way the release is gone
# 100 ms after it names itself, silently, and this check reports "it stopped
# before it answered" about a server whose only fault was that nobody was
# holding its pipe. So the pipe is held open here and closed in `cleanup`,
# which is also how this stops the release politely.
stdin_fifo="$(mktemp -d "${TMPDIR:-/tmp}/boot-check-stdin.XXXXXX")/stdin"
mkfifo "$stdin_fifo"

# A `.bat` is what Windows has, and `cmd` is what runs it: a path with spaces in
# it (`…\Monty on the BEAM\…`) is split by `cmd` alone, so the quoting is the
# same two lines `src-tauri/src/main.rs` uses.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    # `cmd` needs a Windows path; this shell holds a POSIX one. `cygpath` is what
    # Git Bash ships for exactly that translation.
    cmd //c call "$(cygpath -w "$entry")" <"$stdin_fifo" >"$log" 2>&1 &
    ;;
  *) "$entry" <"$stdin_fifo" >"$log" 2>&1 & ;;
esac

pid=$!

# The write end, held by this shell and never written to: the release reading it
# waits for an end-of-file that does not come until this check is done.
exec 9>"$stdin_fifo"

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
  # Letting go of the pipe is the polite stop: the release reads end-of-file and
  # shuts itself down, which is the path the window uses.
  exec 9>&- 2>/dev/null || true

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
  rm -rf "$(dirname "$stdin_fifo")"
}
trap cleanup EXIT

answered=
for _ in $(seq 1 120); do
  if health="$(curl -fsS "http://127.0.0.1:$port/health" 2>/dev/null)"; then
    answered=1
    echo "the release answered /health on $port: $health"
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

# Named, and named the way a plugin finds it: `monty-studio-<instance id>`, with
# the host a short name carries. The instance id is pinned above, so the whole
# name is known here — a node that answered `nightly`, `nohost`, or
# `monty-studio-<six random hex>` is a node whose name the launcher did not take
# from the variable the desktop sets.
case "$health" in
  *'"node":"monty-studio-bootcheck@'*)
    echo "and it is a node the sample plugins can find by name"
    ;;
  *)
    echo "the release answered /health without a monty-studio node name:" >&2
    echo "  $health" >&2
    echo "  this check exported EX_TBP_MONTY_WINDOW=${EX_TBP_MONTY_WINDOW:-<unset>}" >&2
    echo "  and the release said, first:" >&2
    head -12 "$log" | sed 's/^/    /' >&2
    echo "  and last:" >&2
    tail -12 "$log" | sed 's/^/    /' >&2
    exit 1
    ;;
esac

# The two sample plugin nodes, which `bundle.resources` puts beside `rel/` in
# every shape: `Contents/Resources/plugins` inside a `.app`, `plugins/` next to
# the release in the portable folder and the AppImage. Asserted here because the
# copy is one line of JSON per platform, and a bundle without them is a demo that
# cannot be given — silently, since the window itself is complete either way.
plugins="$(dirname "$(dirname "$release")")/plugins"

for wanted in "start-plugins.sh" "start-plugins.ps1" "example_plugin/bin" "flyverse_plugin/bin"; do
  if [ ! -e "$plugins/$wanted" ]; then
    echo "the bundle carries no plugins/$wanted — see docs/desktop.md" >&2
    ls "$plugins" 2>/dev/null | sed 's/^/  /' >&2
    exit 1
  fi
done

echo "and it carries the two sample plugin nodes ($(du -sh "$plugins" | cut -f1))"

# Then the control in the window, pressed the way a page presses it, because a
# launcher starting a launcher is the one thing only a bundle can get wrong: a
# child inherits the sidecar's `RELEASE_*`, reads *this* release's version number,
# and dies looking for a folder of that name inside its own release. It said so on
# a pipe the sidecar drains at `:debug`, so what a person saw was a control that
# reported two nodes and a cluster that stayed empty.
# `rpc` runs the expression in the sidecar's own VM and does not echo the value
# back, so what the control answered is not visible here — the page is, and that
# is what a person looks at anyway. A refusal (`MONTY_STUDIO_CLUSTER=0`, a
# launcher that is not there) fails the wait below either way.
press() {
  "$launcher" rpc "$1" >/dev/null 2>&1 || true
}

# What the cluster card says, as a person reads it off the page.
cluster_says() {
  curl -fsS --max-time 5 "http://127.0.0.1:$port/settings" 2>/dev/null |
    grep -o "[0-9]* nodes in this cluster\|One node in this cluster" | head -1 || true
}

# Bounded: two nodes joining is a launch, a boot and a gossip round, which is
# slower on a loaded runner than anywhere else.
waiting_for() {
  for _ in $(seq 1 120); do
    [ "$(cluster_says)" = "$1" ] && return 0
    sleep 1
  done

  return 1
}

echo "pressing the control that starts the two sample plugin nodes"
press 'ExTbpMonty.SamplePlugins.start()'

if ! waiting_for "3 nodes in this cluster"; then
  echo "the window started the two sample plugin nodes and they did not join." >&2
  echo "  the page still says: $(cluster_says)" >&2
  echo "  the sidecar said, last:" >&2
  tail -30 "$log" | sed 's/^/    /' >&2
  exit 1
fi

echo "and both joined it: $(cluster_says)"

echo "stopping them again, the way the page's second button does"
press 'ExTbpMonty.SamplePlugins.stop()'

if ! waiting_for "One node in this cluster"; then
  echo "the two sample plugin nodes did not leave when they were stopped." >&2
  echo "  the page still says: $(cluster_says)" >&2
  exit 1
fi

echo "and they left again: $(cluster_says)"

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
