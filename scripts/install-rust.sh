#!/usr/bin/env bash
# The Rust toolchain that `mix compile` needs.
#
#   scripts/install-rust.sh
#
# No arguments, and safe to run at any point: the nearest-neighbour index is a
# NIF (`native/kd_tree_nif`) and rustler builds it while the application compiles,
# so without `cargo` the build stops. A machine that already has one is left
# alone, which is what makes this usable from a developer's shell, a container
# build and a CI job that may or may not ship Rust already.
set -euo pipefail

if command -v cargo >/dev/null 2>&1; then
  echo "rust: already installed — $(cargo --version)"
  exit 0
fi

# The official installer is the documented way to get a toolchain on every
# platform this project builds on. `--profile minimal` leaves out rust-docs and
# clippy, which a build never calls; `--default-toolchain stable` keeps every
# machine on the channel the crate is written for.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain stable

# rustup installs into $CARGO_HOME/bin and adds that directory to the shell
# profiles — which a non-interactive shell (this one, a Docker RUN, a CI step)
# never reads. So the check is done against the two places it can land.
for bin in "${CARGO_HOME:-$HOME/.cargo}/bin" /usr/local/cargo/bin; do
  if [ -x "$bin/cargo" ]; then
    PATH="$bin:$PATH"
    export PATH
  fi
done

if ! command -v cargo >/dev/null 2>&1; then
  echo "rust: the installer ran but cargo is not on PATH — start a new shell" >&2
  exit 1
fi

echo "rust: $(cargo --version)"
