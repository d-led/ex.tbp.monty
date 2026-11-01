#!/usr/bin/env bash
#
# The Elixir that `mix` needs, when this machine has none.
#
#   scripts/install-elixir.sh
#
# No arguments. A machine with Elixir 1.20 or newer on PATH is left alone and
# this prints nothing; otherwise it runs Elixir's own installer, which unpacks a
# prebuilt OTP and Elixir under ~/.elixir-install/installs — per user, no root,
# and the same release on every platform, where a package manager would hand out
# whatever it happens to ship.
#
# A script cannot change its caller's PATH, so the last thing it does is print
# the two directories to prepend (Elixir's, then OTP's, which `elixir` calls).
# The caller does the exporting:
#
#   if bin="$(scripts/install-elixir.sh)"; then PATH="$bin:$PATH"; fi
set -euo pipefail

# `mix.exs` says `elixir: "~> 1.20"`, and the Dockerfile pins the same OTP
# minor, so a build here and a build there are the same interpreter.
ELIXIR_VERSION=1.20.5
OTP_VERSION=29.1

ROOT="${HOME}/.elixir-install"
OTP_DIR="${ROOT}/installs/otp/${OTP_VERSION}"
# The installer names the Elixir directory after the OTP *major*: 1.20.5-otp-29.
ELIXIR_DIR="${ROOT}/installs/elixir/${ELIXIR_VERSION}-otp-${OTP_VERSION%%.*}"

enough() {
  command -v elixir >/dev/null 2>&1 || return 1

  local version major minor
  version="$(elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9]*\.[0-9]*\).*/\1/p' | tail -n 1)"

  [ -n "$version" ] || return 1
  major="${version%%.*}"
  minor="${version#*.}"

  [ "$major" -eq 1 ] && [ "$minor" -ge 20 ]
}

if enough; then
  exit 0
fi

echo "install-elixir: installing Elixir ${ELIXIR_VERSION} with OTP ${OTP_VERSION} under ${ROOT}" >&2

installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT

curl --proto '=https' --tlsv1.2 -fsSL https://elixir-lang.org/install.sh -o "$installer"

# Its own chatter ("unpacking …", "Run this …") belongs beside ours, not in the
# answer the caller is reading for a PATH.
sh "$installer" "elixir@${ELIXIR_VERSION}" "otp@${OTP_VERSION}" >&2

for binary in "${OTP_DIR}/bin/erl" "${ELIXIR_DIR}/bin/mix"; do
  if [ ! -x "$binary" ]; then
    echo "install-elixir: the installer ran but ${binary} is missing" >&2
    exit 1
  fi
done

printf '%s:%s\n' "${ELIXIR_DIR}/bin" "${OTP_DIR}/bin"
