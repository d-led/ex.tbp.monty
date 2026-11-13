defmodule FlyversePlugin.Experiment do
  @moduledoc """
  Monty's ten-similar-objects experiment, with the connectome as its motor
  system: a copy of a standard experiment that changes one thing.

  `base_10simobj_surf_agent` is Monty's own experiment — ten similar objects, a
  surface agent, its learning module, its MuJoCo world, its training and
  evaluation epochs — and this definition is that experiment with its motor
  system replaced by `FlyversePlugin.Policy` on the node that offers it. The
  learning module is the config's, so the run is still a recognition: the
  connectome decides where to look, the framework's evidence matching decides
  what was seen.

  ## What "a copy" can mean, and what it cannot

  A definition has to name something the studio can compose, because
  `Monty.Studio.PluginExperiment` composes the base on the **studio's** node
  against that node's `conf/` tree. A plugin cannot ship a YAML file into another
  application's config tree, and there is no request in the plugin contract that
  would carry one — so copying the experiment means naming it, and pinning the
  numbers a run must not inherit silently (the seed).

  Everything else stays the config's and is read from it: the ten objects, the
  three training epochs, one evaluation epoch per rotation, the pretrained model
  path, the termination criteria, the world. A run's record names the config it
  stepped and the plugin that defined the run, so the two halves are never
  confused for each other.

  What the definition does **not** name is a learning module: one is advertised
  rather than routed, so a definition naming one is refused by name. That is not
  a limitation to work around — it is the same boundary that makes this plugin a
  motor policy (`FlyversePlugin` on why a connectome is not an evidence map).

  ## What it does not claim

  A four-neuron demonstrator pack steering a ten-object recognition run is not a
  fly solving Monty's benchmark, and this definition is not evidence that the
  connectome can. It is the standard experiment, stepped with a policy whose
  actions come from spikes, so that the seam can be seen working end to end.
  """

  @behaviour FlyversePlugin.Plugin

  @doc "The name a cluster registers it under, and the name a run asks for."
  @spec name() :: String.t()
  def name, do: "flyverse_plugin.10simobj_surf_agent"

  @doc "What a cluster asks about it."
  @impl FlyversePlugin.Plugin
  @spec describe() :: MontyPlugin.description()
  def describe do
    %{
      "name" => name(),
      "kind" => :experiment,
      "version" => FlyversePlugin.version(),
      "placement" => :anywhere,
      "needs" => [:monty]
    }
  end

  @doc """
  The run it would perform.

  `seed` is the base config's own seed, written down rather than inherited: a
  definition that said one thing and ran under another would be a record that
  disagrees with itself. There is no `episodes` key because a definition cannot
  ask for fewer episodes — the studio performs one episode of the experiment the
  base config describes, and a number here that nothing read would be a promise
  the record could not keep.
  """
  @spec run() :: map()
  @impl FlyversePlugin.Plugin
  def run do
    %{
      "base" => "base_10simobj_surf_agent",
      "learning_modules" => [],
      "motor_system" => FlyversePlugin.Policy.name(),
      "seed" => 42
    }
  end

  @doc "A definition keeps nothing."
  @impl FlyversePlugin.Plugin
  def initial_state, do: %{}
end
