defmodule ExTbpMonty.Core.Supervisor do
  @moduledoc """
  The processes the core needs, for a host to put in its own tree.

      children = [
        ExTbpMonty.Core.Supervisor,
        MyApp.Endpoint
      ]

  Two of them, and both are about finding a module by name:

    * `Monty.Runtime.Registry` — every sensor and learning module registers
      here, so the step coordinator can address a module across restarts;
    * `#{inspect(__MODULE__)}.model_supervisor()` — one child per running model,
      holding its module servers and step coordinator. A model is stopped by
      terminating its supervisor, so its children cannot outlive the run.

  A host that names these differently passes the supervisor name to
  `Monty.Runtime.Model.stop/2`; nothing else in the core knows a host's names.
  """

  use Supervisor

  @model_supervisor ExTbpMonty.Core.ModelSupervisor

  @doc "The supervisor a model is started under, and stopped through."
  @spec model_supervisor() :: atom()
  def model_supervisor, do: @model_supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  @impl true
  def init(_options) do
    children = [
      {Registry, keys: :unique, name: Monty.Runtime.Registry},
      {DynamicSupervisor, name: @model_supervisor, strategy: :one_for_one}
    ]

    # A node's two long-lived processes do not get the default budget of three
    # restarts in five seconds. A burst of failing runs used to be counted
    # against the model supervisor and then against this supervisor, and a node
    # that gave up took every other run on it down with a clean exit that said
    # nothing. A model is `:temporary` to whoever starts it, so deaths of models
    # are not restarts at all; this is the rest of the story for the two
    # processes that must outlive any single run.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 100, max_seconds: 5)
  end
end
