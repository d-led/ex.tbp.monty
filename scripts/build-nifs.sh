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

# The crates are the directory's, not a list kept here: a crate added to the
# package is a crate this build has to produce, and a list is how a new one came
# to be missing from CI while twelve tests failed with `{:error, :not_built}`.
for manifest in packages/ex_tbp_monty_core/native/*/Cargo.toml; do
  crate="$(basename "$(dirname "$manifest")")"

  if [ ! -f "$native/$crate.so" ]; then
    echo "nifs: $crate did not land in $native — is cargo on PATH?" >&2
    echo "nifs: scripts/install-rust.sh puts a toolchain where this shell can see it" >&2
    exit 1
  fi
done

# A library that is there is not a library that loads. A `.so` whose thread-local
# block is larger than the loader's static surplus fails at `dlopen` with "cannot
# allocate memory in static TLS block", and every caller then sees a NIF that is
# not there — measured on the Linux runner on 2026-11-20, where the file existed
# and only the tests said so. Every native module is asked here, by the name it
# exposes for exactly this question.
MIX_ENV="${MIX_ENV:-dev}" mix run --no-start -e '
  Application.ensure_loaded(:ex_tbp_monty_core)

  modules =
    :ex_tbp_monty_core
    |> :application.get_key(:modules)
    |> elem(1)
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :available, 0)))

  down =
    Enum.reject(modules, fn module ->
      try do
        module.available()
      rescue
        _not_loaded -> false
      end
    end)

  if down == [] do
    IO.puts("nifs: #{length(modules)} load")
  else
    IO.puts(:stderr, "nifs: cannot load #{inspect(down)}")
    System.halt(1)
  end
'
