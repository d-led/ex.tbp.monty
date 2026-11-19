defmodule FlyversePlugin.Application do
  @moduledoc """
  The pack, one process per plugin, and the node joining the cluster.

  `FlyversePlugin.Networks` comes first because it is what a policy opens: the
  connectome is loaded once for the VM and shared, since the loader keeps its
  arrays for the life of the process. The plugins register from their own
  `init/1` (`FlyversePlugin.Offer`), so a registration lasts exactly as long as
  the process offering it — a plugin that dies takes its name out of the cluster
  with it, which is what `:pg` does and the reason the registry is `:pg` rather
  than a `Registry`.

  The cluster comes next; the cookie is set before the topology that dials with
  it starts, and the topology before the plugins, so a node that joins a studio
  is in it by the time its plugins are offered. A node nobody asked to cluster
  starts neither — `FlyversePlugin.Cluster.topologies/0` is empty, and the tree
  is the one a single node has.
  """

  use Application

  @impl true
  def start(_type, _args) do
    FlyversePlugin.Cluster.set_cookie()

    children =
      [FlyversePlugin.Networks, FlyversePlugin.Cluster, FlyversePlugin.Join] ++
        Enum.map(FlyversePlugin.plugins(), &{FlyversePlugin.Offer, &1})

    Supervisor.start_link(children, strategy: :one_for_one, name: FlyversePlugin.Supervisor)
  end
end
