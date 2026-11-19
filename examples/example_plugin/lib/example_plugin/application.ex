defmodule ExamplePlugin.Application do
  @moduledoc """
  One process per plugin, and the node joining the cluster the studio is in.

  The plugins register from their own `init/1` (`ExamplePlugin.Offer`), so a
  registration lasts exactly as long as the process offering it: a plugin that
  dies takes its name out of the cluster with it, which is what `:pg` does and
  the reason the registry is `:pg` rather than a `Registry`.

  The cluster comes first, in both senses: the cookie is set before the topology
  that dials with it starts, and the topology starts before the plugins, so a
  node that joins a studio is in it by the time its plugins are offered. A node
  nobody asked to cluster starts neither — `ExamplePlugin.Cluster.topologies/0`
  is empty, and the tree is the one a single node has.
  """

  use Application

  @impl true
  def start(_type, _args) do
    ExamplePlugin.Cluster.set_cookie()

    children =
      [ExamplePlugin.Cluster, ExamplePlugin.Join] ++
        Enum.map(ExamplePlugin.plugins(), &{ExamplePlugin.Offer, &1})

    Supervisor.start_link(children, strategy: :one_for_one, name: ExamplePlugin.Supervisor)
  end
end
