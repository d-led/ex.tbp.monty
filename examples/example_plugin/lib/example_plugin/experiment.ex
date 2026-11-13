defmodule ExamplePlugin.Experiment do
  @moduledoc """
  The run this plugin asks a cluster for: a config's name, and the modules it
  wants for it.

  An `:experiment` plugin is the definition of a run rather than a step of one —
  `MontyPlugin` on kinds — so it is asked once and not again. What it answers is
  data (`run/0`), which is what makes it useful over a cluster: a caller reads
  the definition without compiling anything in, and a test can ask whether every
  module the definition names is offered by the same node that offers the
  definition.

  `"base"` names an experiment the application this example lives in ships
  (`priv/monty/conf/experiment/base_10simobj_surf_agent.yaml`), and the two
  module names are the other two plugins of this node. A definition that named
  modules nobody offered would be a run that cannot start, which is the one thing
  this test of the example refuses.
  """

  @doc "The name a cluster registers it under, and the name a run asks for."
  @spec name() :: String.t()
  def name, do: "example_plugin.10simobj_surf_agent_one_episode"

  @doc "What a cluster asks about it."
  @spec describe() :: MontyPlugin.description()
  def describe do
    %{
      "name" => name(),
      "kind" => :experiment,
      "version" => ExamplePlugin.version(),
      "placement" => :anywhere,
      "needs" => [:monty]
    }
  end

  @doc """
  The run it would perform.

  `episodes` and `seed` are there for the same reason the rest is: a definition a
  person cannot read is a definition nobody can argue with.
  """
  @spec run() :: map()
  def run do
    %{
      "base" => "base_10simobj_surf_agent",
      "learning_modules" => [ExamplePlugin.LearningModule.name()],
      "motor_system" => ExamplePlugin.Policy.name(),
      "episodes" => 1,
      "seed" => 42
    }
  end
end
