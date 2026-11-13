defmodule Monty.Studio.PluginExperimentTest do
  @moduledoc """
  A run a plugin defines, opened as something this node can step: the config the
  definition names, the policy it asks for, and a refusal for every module this
  node cannot serve.

  A definition is somebody else's data, so the cases are about what happens when
  it is not what we would have written: a base config that is not here, a
  learning module nobody can route, a name no host offers.
  """

  use ExUnit.Case, async: false

  alias Monty.PluginHost.Provider
  alias Monty.Studio.{PluginExperiment, RemotePolicy}

  @policy "example_plugin.spiral_scan"
  @experiment "example_plugin.one_episode"

  setup do
    MontyPlugin.Registry.clear()
    on_exit(&MontyPlugin.Registry.clear/0)

    %{hosts: [host()]}
  end

  test "the config a definition names is composed, and its policy is the run's", %{hosts: hosts} do
    policy = start_policy()

    definition = %{
      "base" => "base_10simobj_surf_agent",
      "learning_modules" => [],
      "motor_system" => @policy,
      "episodes" => 1,
      "seed" => 42
    }

    offer_experiment(definition)
    here = node()

    assert {:ok, opened} = PluginExperiment.open(@experiment, hosts: hosts)

    assert %RemotePolicy{name: @policy, node: ^here} = policy_of(opened)
    assert opened.source == :plugin
    assert opened.plugin.node == node()
    assert opened.plugin.definition == definition
    assert opened.config["experiment"]["config"]["monty_config"]
    assert opened.setup.name == @experiment
    # The policy the definition named, and the very process behind it: a second
    # lookup that found a different provider would be a different run.
    assert policy == policy_of(opened).pid
  end

  # The definition decides, not this node's `MONTY_REMOTE_POLICY`: a plugin's
  # experiment that named no motor system runs the config's own policy.
  test "a definition naming no motor system leaves the config's policy alone", %{hosts: hosts} do
    offer_experiment(%{"base" => "base_10simobj_surf_agent", "learning_modules" => []})

    assert {:ok, opened} = PluginExperiment.open(@experiment, hosts: hosts)
    assert opened.setup.remote_policy == nil
  end

  # The definition is the experiment, so the seed it names is the seed the run
  # uses — and it is the one the record will show.
  test "the seed a definition names is the seed the run starts from", %{hosts: hosts} do
    offer_experiment(%{
      "base" => "base_10simobj_surf_agent",
      "learning_modules" => [],
      "seed" => 7
    })

    assert {:ok, opened} = PluginExperiment.open(@experiment, hosts: hosts)
    assert opened.setup.seed == 7
  end

  test "a definition naming no seed keeps the base config's own", %{hosts: hosts} do
    offer_experiment(%{"base" => "base_10simobj_surf_agent", "learning_modules" => []})

    assert {:ok, mine} = Monty.Studio.open("base_10simobj_surf_agent")
    assert {:ok, opened} = PluginExperiment.open(@experiment, hosts: hosts)

    assert opened.setup.seed == mine.setup.seed
  end

  test "a learning module a run asks for is refused by name, and why", %{hosts: hosts} do
    offer_experiment(%{
      "base" => "base_10simobj_surf_agent",
      "learning_modules" => ["example_plugin.evidence_threshold"]
    })

    assert {:error, why} = PluginExperiment.open(@experiment, hosts: hosts)

    assert why =~ "example_plugin.evidence_threshold"
    assert why =~ "advertised rather than routed"
  end

  test "a base config this node does not have is refused, naming it", %{hosts: hosts} do
    offer_experiment(%{"base" => "not_a_config_here", "learning_modules" => []})

    assert {:error, why} = PluginExperiment.open(@experiment, hosts: hosts)

    assert why =~ "not_a_config_here"
    assert why =~ "cannot compose"
  end

  test "a definition with no base config is refused rather than guessed at", %{hosts: hosts} do
    offer_experiment(%{"learning_modules" => []})

    assert {:error, why} = PluginExperiment.open(@experiment, hosts: hosts)

    assert why =~ "names no base config"
  end

  test "a motor system nobody offers is refused", %{hosts: hosts} do
    offer_experiment(%{
      "base" => "base_10simobj_surf_agent",
      "learning_modules" => [],
      "motor_system" => "example_plugin.ghost"
    })

    assert {:error, why} = PluginExperiment.open(@experiment, hosts: hosts)

    assert why =~ "example_plugin.ghost"
  end

  test "a name no host offers is not an experiment here either", %{hosts: hosts} do
    assert {:error, why} = PluginExperiment.open("nobody.offers_this", hosts: hosts)

    assert why =~ "no experiment here is named"
  end

  # The studio's front door, which is how a page reaches any of this.
  test "Monty.Studio.open/1 falls through to the cluster for a name it cannot compose", %{
    hosts: hosts
  } do
    offer_experiment(%{"base" => "base_10simobj_surf_agent", "learning_modules" => []})

    assert {:ok, opened} = Monty.Studio.open(@experiment, hosts: hosts)
    assert opened.source == :plugin
    assert opened.setup.name == @experiment
  end

  defp host, do: %{node: node(), name: "this host", address: to_string(node())}

  defp offer_experiment(definition) do
    host = start_provider(name: @experiment, kind: :experiment, definition: definition)
    MontyPlugin.Registry.offer(:experiment, @experiment, {:ok, provider(host, @experiment)})
  end

  defp start_policy do
    host = start_provider(name: @policy, kind: :motor_policy)
    MontyPlugin.Registry.offer(:motor_policy, @policy, {:ok, provider(host, @policy)})
    host
  end

  defp start_provider(options) do
    start_supervised!({Provider, options})
  end

  defp provider(pid, name) do
    %{node: node(), name: name, pid: pid, describe: {:ok, %{"version" => "0.1.1"}}}
  end

  defp policy_of(opened) do
    {:ok, policy} = opened.setup.remote_policy
    policy
  end
end
