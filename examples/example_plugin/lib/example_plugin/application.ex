defmodule ExamplePlugin.Application do
  @moduledoc """
  One process per plugin, and the node joining the cluster the studio is in.

  The plugins register from their own `init/1` (`ExamplePlugin.Offer`), so a
  registration lasts exactly as long as the process offering it: a plugin that
  dies takes its name out of the cluster with it, which is what `:pg` does and
  the reason the registry is `:pg` rather than a `Registry`.

  Joining comes last in the list and runs first in practice — a supervisor starts
  its children in order — so a node that cannot reach the cluster still offers
  its plugins to itself, and the poller in `ExamplePlugin.Join` keeps trying.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExamplePlugin.Join | Enum.map(ExamplePlugin.plugins(), &{ExamplePlugin.Offer, &1})
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ExamplePlugin.Supervisor)
  end
end
