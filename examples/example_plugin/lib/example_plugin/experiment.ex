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
  (`priv/monty/conf/experiment/base_10simobj_surf_agent.yaml`), and
  `"motor_system"` names the policy plugin of this node. A definition that named
  modules nobody offered would be a run that cannot start, which is the one thing
  this test of the example refuses.

  ## Why the learning module is not in the definition

  This node offers one (`example_plugin.evidence_threshold`), and a definition
  naming it would be refused: a learning module is **advertised rather than
  routed** — a step asks it thousands of times over hypotheses and a k-d tree, so
  a node running an experiment has to have the module's code, which it does not
  have for another node's. The policy is the kind that can be called across, so
  the definition names the policy and leaves the learning modules to the config.
  `docs/plugins.md` keeps the score.
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
      "needs" => []
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
      "learning_modules" => [],
      "motor_system" => ExamplePlugin.Policy.name(),
      "episodes" => 1,
      "seed" => 42
    }
  end
end
