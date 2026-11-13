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

  Joining is last in the list and runs first in practice — a supervisor starts
  its children in order — so a node that cannot reach the cluster still offers
  its plugins to itself, and the poller keeps trying.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [FlyversePlugin.Networks, FlyversePlugin.Join] ++
        Enum.map(FlyversePlugin.plugins(), &{FlyversePlugin.Offer, &1})

    Supervisor.start_link(children, strategy: :one_for_one, name: FlyversePlugin.Supervisor)
  end
end
