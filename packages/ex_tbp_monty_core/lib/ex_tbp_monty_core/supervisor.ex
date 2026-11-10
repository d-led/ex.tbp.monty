defmodule ExTbpMonty.Core.Supervisor do
  @moduledoc """
  The processes the core needs, for a host to put in its own tree.

      children = [
        ExMontyTbp.Core.Supervisor,
        MyApp.Endpoint
      ]

  Two of them, and both are about finding a module by name:

    * `Monty.Runtime.Registry` — every sensor and learning module registers
      here, so the step coordinator can address a module across restarts;
    * `ExMontyTbp.Core.ModelSupervisor` — one child per running model, holding
      its module servers and step coordinator. A model is stopped by
      terminating its supervisor, so its children cannot outlive the run.

  A host that names these differently passes the supervisor name to
  `Monty.Runtime.Model.stop/1`; nothing else in the core knows a host's names.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @impl true
  def init(_options) do
    children = [
      {Registry, keys: :unique, name: Monty.Runtime.Registry},
      {DynamicSupervisor, name: ExMontyTbp.Core.ModelSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
