#!/usr/bin/env bash
#
# Builds the two sample plugin nodes into `_build/desktop/plugins/`, where
# `scripts/package.sh` picks each of them up to wrap in an application of its own.
#
#   scripts/build-plugins.sh
#
# Why releases and not escripts: `ex_tbp_monty_core` compiles native kernels, and
# an escript cannot load one. The window does not carry them and never will: a
# plugin is a node, and the distribution ships it as a companion app you can
# click, beside the window rather than inside it.
#
# Each is ~19 MB — a whole runtime of its own — and the by-hand launcher is copied
# in beside them (`scripts/desktop-plugins/`) for the times there is no app to
# click. What a person gets is two nodes that answer the plugin contract, so Monty
# Studio's Settings → Cluster shows three nodes instead of one: the demonstration
# the contract is for.
set -euo pipefail
cd "$(dirname "$0")/.."

out="_build/desktop/plugins"
rm -rf "$out"
mkdir -p "$out"

for example in example_plugin flyverse_plugin; do
  echo "building examples/$example"
  (
    cd "examples/$example"
    MIX_ENV=prod mix deps.get >/dev/null
    MIX_ENV=prod mix release --overwrite >/dev/null
  )

  cp -R "examples/$example/_build/prod/rel/$example" "$out/$example"
done

cp scripts/desktop-plugins/start-plugins.sh scripts/desktop-plugins/start-plugins.ps1 "$out/"
cp scripts/desktop-plugins/README.md "$out/"
chmod +x "$out/start-plugins.sh"

du -sh "$out"/* | sed 's/^/  /'
