#!/usr/bin/env bash
#
# Builds the two sample plugin nodes into `_build/desktop/plugins/`, where the
# window carries them.
#
#   scripts/build-plugins.sh
#
# Why releases and not escripts: `ex_tbp_monty_core` compiles native kernels, and
# an escript cannot load one. Why here and not in `package.sh`: `bundle.resources`
# in the three tauri configs copies `_build/desktop/plugins` into the bundle, so
# the folder has to exist before `cargo tauri build` runs.
#
# Each is ~19 MB — a whole runtime of its own — and the launcher that starts them
# is copied in beside them (`scripts/desktop-plugins/`). What a person gets is two
# nodes that answer the plugin contract, so Monty Studio's Settings → Cluster
# shows three nodes instead of one: the demonstration the contract is for.
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
