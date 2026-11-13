#!/usr/bin/env bash
# One node of a local cluster: its own name, its own port, its own database file.
#
#   scripts/cluster-node.sh node1 4001
#
# The name is what makes it a node at all (`--name`, the same decision
# `NODE_NAME` makes for a release), `MONTY_CLUSTER` is what asks the application
# for the cluster's children, and `MONTY_DB=sqlite` keeps this node's runs in
# `<root>/nodes/<its name>/ex_tbp_monty.db` — the folder `ExTbpMonty.Node`
# decides, so two nodes on one machine cannot open one file.
#
# `MONTY_COOKIE` is what nodes on *different* machines agree on: without it every
# VM uses its user's `~/.erlang.cookie`, which is the same file on one machine and
# three different files on three. Two nodes that disagree about it are two
# clusters that quietly believe they are one, so the same value has to be exported
# wherever a node is started, and the settings page says where it came from.
#
# `MONTY_CAPABILITIES` is what a node says about its machine — `gpu`,
# `world:mujoco`, the tags of plugins it brings — and it is passed through rather
# than set here: which machine a node is on is the machine's fact, not this
# script's. Every node advertises `monty` regardless; the settings page lists the
# result both ways round.
#
# The database is made and migrated by this node itself, in a VM of its own that
# does not start the application. `mix ecto.create` cannot do it: an Ecto mix task
# reads configuration *before* `config/runtime.exs`, which is where a node's
# database is chosen — it would try the Postgres this checkout was written around
# and find no `database` in its config. `mix run --no-start` does read that file,
# and `Release.migrate/0` is the migration a release applies.
set -euo pipefail

cd "$(dirname "$0")/.."

name="${1:?usage: cluster-node.sh NAME PORT}"
port="${2:?usage: cluster-node.sh NAME PORT}"

export MONTY_CLUSTER=1
export MONTY_DB=sqlite
export PORT="$port"

node="${name}@127.0.0.1"

# One array of flags for both VMs: a cookie given on the command line is the same
# decision on both sides of a join, and bash 3.2 (macOS) cannot expand an empty
# array under `set -u`, hence the branch rather than `"${flags[@]}"` always.
if [ -n "${MONTY_COOKIE:-}" ]; then
  set -- --cookie "$MONTY_COOKIE"
else
  set --
fi

elixir "$@" --name "$node" -S mix run --no-start -e '
  File.mkdir_p!(Path.dirname(Monty.Paths.database()))
  :ok = ExTbpMonty.Release.migrate()
  IO.puts("cluster-node: #{Monty.Paths.database()} is migrated")
'

exec elixir "$@" --name "$node" -S mix phx.server
