defmodule Monty.Studio.CatalogPluginExperimentsTest do
  @moduledoc """
  The experiments a **plugin host** brings, as a node sees them.

  A plugin's experiment is defined by the plugin, so the cluster cannot list it
  from a config file — but it can list *which* ones exist and who has them, because
  every plugin host says so in the answer the cluster poller already asks for
  (`MontyPlugin.Registry.identity/0` → `plugins`, carried per entry by
  `ExTbpMonty.Cluster.Nodes`). This is that list: no registry of our own, no
  message beyond the poll, and nothing copied — opening one still asks the host
  that defines it (`Monty.Studio.PluginExperiment.open/2`).
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Cluster.Nodes
  alias Monty.Studio.Catalog

  # `Nodes.snapshot/0` reads the last poll out of `:persistent_term`, so a list put
  # there is the whole of "a cluster of two" for a test. It is the node's own
  # state, so it is put back.
  setup do
    previous = :persistent_term.get({Nodes, :snapshot}, :none)

    on_exit(fn ->
      case previous do
        :none -> :persistent_term.erase({Nodes, :snapshot})
        entries -> :persistent_term.put({Nodes, :snapshot}, entries)
      end
    end)

    :ok
  end

  describe "the experiments a plugin host brings" do
    test "are listed with the node that offers them, and only the experiments" do
      cluster([
        entry("node1", self: true),
        plugin_host("node2",
          plugins: [
            %{"kind" => "experiment", "name" => "flyverse_plugin.10simobj_surf_agent"},
            %{"kind" => "motor_system", "name" => "flyverse_plugin.lif_steering"}
          ]
        )
      ])

      assert Catalog.plugin_experiments() == [
               %{
                 name: "flyverse_plugin.10simobj_surf_agent",
                 host: "node2_127.0.0.1",
                 node: :"node2@127.0.0.1"
               }
             ]
    end

    # Two things of one name is one experiment, and the one this node can read is
    # the one to show: a plugin that offers a name we also ship does not become a
    # second card.
    test "do not include an experiment this node's own configs define" do
      ours = hd(Catalog.experiments()).name

      cluster([
        entry("node1", self: true),
        plugin_host("node2", plugins: [%{"kind" => "experiment", "name" => ours}])
      ])

      assert Catalog.plugin_experiments() == []
    end

    test "are listed once when two hosts offer the same experiment" do
      offered = [%{"kind" => "experiment", "name" => "two_hosts.one_experiment"}]

      cluster([
        entry("node1", self: true),
        plugin_host("node2", plugins: offered),
        plugin_host("node3", plugins: offered)
      ])

      assert [%{name: "two_hosts.one_experiment", host: host}] = Catalog.plugin_experiments()
      assert host == "node2_127.0.0.1"
    end

    test "are none on a cluster with no plugin host" do
      cluster([entry("node1", self: true), entry("node2")])

      assert Catalog.plugin_experiments() == []
    end
  end

  defp cluster(entries), do: :persistent_term.put({Nodes, :snapshot}, entries)

  defp entry(name, options \\ []) do
    %{
      node: :"#{name}@127.0.0.1",
      name: "#{name}_127.0.0.1",
      address: "#{name}@127.0.0.1",
      self: Keyword.get(options, :self, false),
      alive: true,
      version: "0.1.3",
      protocol: 1,
      capabilities: ["monty"],
      artifacts: "/tmp/runs",
      web: nil,
      plugins: []
    }
  end

  defp plugin_host(name, options) do
    Map.merge(entry(name), %{
      capabilities: ["monty", "plugin"],
      plugins: Keyword.fetch!(options, :plugins)
    })
  end
end
