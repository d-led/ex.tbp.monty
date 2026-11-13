defmodule FlyversePlugin.RegistrationTest do
  @moduledoc """
  The plugins are in the cluster's registry because their own processes put them
  there, which is what a studio's Settings page reads.

  The application is started by `mix test`, so nothing here starts it again: what
  is asserted is the registration the running node really made.
  """

  use ExUnit.Case, async: true

  test "every plugin this node offers is found by its kind and name" do
    for plugin <- FlyversePlugin.plugins() do
      description = plugin.describe()

      assert {:ok, provider} =
               MontyPlugin.Registry.lookup(description["kind"], description["name"])

      assert provider.node == node()
      assert provider.describe == {:ok, description}
    end
  end

  test "a name nobody offers is a sentence naming what is on offer" do
    assert {:error, sentence} = MontyPlugin.Registry.lookup(:motor_policy, "nobody.none")
    assert sentence =~ "flyverse_plugin.lif_steering"
  end

  test "the policy is registered on the node that holds its simulation" do
    assert {:ok, provider} =
             MontyPlugin.Registry.lookup(:motor_policy, FlyversePlugin.Policy.name())

    assert {:ok, description} = provider.describe
    assert description["placement"] == :owner_only
    assert :erlang.node(provider.pid) == node()
  end
end
