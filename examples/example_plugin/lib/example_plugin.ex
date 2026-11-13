defmodule ExamplePlugin do
  @moduledoc """
  A plugin, offering the three things a run is assembled from.

  The Elixir Monty Studio says a run is made of modules that need not live in the
  same node (`MontyPlugin`): an **experiment**, the **learning modules** it steps,
  and the **motor policies** that decide where to sense next. This application is
  the smallest honest answer to that: one node, three plugins, each of them a real
  one rather than a stub.

    * `ExamplePlugin.Experiment` — the run it asks for, as data: a config's name
      and the modules it wants for it.
    * `ExamplePlugin.LearningModule` — how much evidence a hypothesis needs to be
      worth updating this step, which is
      `Monty.Frameworks.Models.EvidenceMatching.LearningModule`'s own decision,
      parsed once from the environment.
    * `ExamplePlugin.Policy` — where the sensor goes next, which is
      `Monty.Frameworks.Models.MotorPolicies.NaiveScanPolicy`'s square spiral.

  None of the three decides anything the framework does not already decide: what
  is added here is the description a cluster asks for, the placement that says
  whether a call may cross a node, and a process that can be reached.

  ## What it proves

  Start two studio nodes and this one (`process-compose.yaml` in the application
  this example lives in) and the plugin registers in the cluster's `:pg` scope
  from its own boot. Then:

    * Settings → Nodes lists it as a plugin node, because
      `MontyPlugin.Registry.identity/0` answers the studio's question about a
      peer that does not run the studio's code;
    * `cad_plugin_list` — the CAD server's MCP tool — names each of the three
      with the node that offers it, and `cad_plugin_describe` asks one of them
      what it says about itself;
    * `mix test` in this directory holds the three descriptions to the contract,
      registers them exactly as the release does, and steps both decisions.

  ## What it does not do

  Nothing in a studio node executes a remote plugin yet: a learning module is
  advertised, not routed, so the caller compiles the module in and the cluster's
  job is to say what is offered where. `ExamplePlugin.Experiment.run/0` is the
  definition a caller would read; performing it is the next piece of work, and it
  is named as such rather than pretended.
  """

  @plugins [ExamplePlugin.Experiment, ExamplePlugin.LearningModule, ExamplePlugin.Policy]

  @doc "The plugins this node offers, one process each."
  @spec plugins() :: [module()]
  def plugins, do: @plugins

  @doc """
  This application's version, which is what a description reports.

  Read rather than written twice: `describe/0` is a function, so the version a
  cluster sees is the version in `mix.exs` at the moment it asked.
  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:example_plugin, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
