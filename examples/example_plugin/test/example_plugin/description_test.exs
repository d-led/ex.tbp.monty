defmodule ExamplePlugin.DescriptionTest do
  @moduledoc """
  What the three plugins say about themselves, which is the part of a plugin a
  cluster can check: a description is a map, so nothing in the compiler holds it
  to the contract.

  A case per property rather than one case for all three, because the failure a
  reader needs is *which* plugin and *which* field.
  """

  use ExUnit.Case, async: true

  for plugin <- ExamplePlugin.plugins() do
    describe "#{inspect(plugin)}.describe/0" do
      test "says enough for a cluster to use it" do
        assert :ok = MontyPlugin.conforms?(unquote(plugin).describe())
      end

      test "reports this application's version, so a run records what answered" do
        assert unquote(plugin).describe()["version"] == ExamplePlugin.version()
      end

      test "could be called from any node" do
        assert unquote(plugin).describe()["placement"] == :anywhere
      end

      # `needs` is what the node that serves the plugin has to carry, and a
      # plugin host's tags come from what it offers — not from the framework it
      # runs. Asking for `:monty` would make this plugin unusable by the only
      # node that can serve it.
      test "asks nothing of the node that serves it, because that node cannot say" do
        assert unquote(plugin).describe()["needs"] == []
      end
    end
  end

  test "every kind a run is assembled from is represented, and one of them twice" do
    offered = Enum.map(ExamplePlugin.plugins(), & &1.describe()["kind"])

    assert Enum.sort(Enum.uniq(offered)) == Enum.sort(MontyPlugin.kinds())
    assert Enum.count(offered, &(&1 == :motor_policy)) == 2
  end

  test "each plugin is registered under a name of its own" do
    names = Enum.map(ExamplePlugin.plugins(), & &1.describe()["name"])

    assert names == Enum.uniq(names)
  end
end
