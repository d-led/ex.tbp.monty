#!/usr/bin/env bash
# The shared libraries this build needs, built whether or not a cache brought one.
#
#   scripts/build-nifs.sh
#
# `mix compile` treats a restored `_build` as up to date and never reruns the
# rustler compiler, so a build tree that lost `priv/native/*.so` stays lost: the
# Elixir modules are there, the shared libraries are not, and the first sign of
# it is forty tests failing with "KdTreeNif.loaded?/0 is undefined". Asking for
# the native package by name is the step a cache cannot skip; this does that and
# then says whether the libraries actually landed.
set -euo pipefail

cd "$(dirname "$0")/.."

# The dependencies first, in their own order: `deps.compile <app> --force`
# compiles that application alone, and a job that has only fetched its
# dependencies has no `Rustler` for the crates to `use` — which is how the types
# job failed on the two NIF modules while every test job built them.
mix compile

mix deps.compile ex_tbp_monty_core --force

native="_build/${MIX_ENV:-dev}/lib/ex_tbp_monty_core/priv/native"

for crate in kd_tree_nif matcher_nif; do
  if [ ! -f "$native/$crate.so" ]; then
    echo "nifs: $crate did not land in $native — is cargo on PATH?" >&2
    echo "nifs: scripts/install-rust.sh puts a toolchain where this shell can see it" >&2
    exit 1
  fi
done

echo "nifs: built $native/{kd_tree_nif,matcher_nif}.so"
