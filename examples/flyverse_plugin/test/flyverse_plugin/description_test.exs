defmodule FlyversePlugin.DescriptionTest do
  @moduledoc """
  What these plugins say about themselves, which is the part of a plugin a
  cluster can check: a description is a map, so nothing in the compiler holds it
  to the contract.

  A case per property rather than one case for both, because the failure a
  reader needs is *which* plugin and *which* field.
  """

  use ExUnit.Case, async: true

  # Placement is the one field that differs, and it is the point of the
  # difference: a simulation is a term this node's BEAM understands, so a policy
  # that steps one says `:owner_only`; a definition is data, so it can be read
  # anywhere.
  @expected %{
    FlyversePlugin.Experiment => %{kind: :experiment, placement: :anywhere},
    FlyversePlugin.Policy => %{kind: :motor_policy, placement: :owner_only}
  }

  for {plugin, expected} <- @expected do
    describe "#{inspect(plugin)}.describe/0" do
      test "says enough for a cluster to use it" do
        assert :ok = MontyPlugin.conforms?(unquote(plugin).describe())
      end

      test "reports this application's version, so a run records what answered" do
        assert unquote(plugin).describe()["version"] == FlyversePlugin.version()
      end

      test "declares the kind and the placement it is offered as" do
        assert unquote(plugin).describe()["kind"] == unquote(expected.kind)
        assert unquote(plugin).describe()["placement"] == unquote(expected.placement)
      end

      test "asks for the framework it is made of" do
        assert unquote(plugin).describe()["needs"] == [:monty]
      end
    end
  end

  test "each plugin is registered under a name that carries this host" do
    names = Enum.map(FlyversePlugin.plugins(), & &1.describe()["name"])

    assert names == Enum.uniq(names)
    assert Enum.all?(names, &String.starts_with?(&1, "flyverse_plugin."))
  end

  # Not an oversight, and this is where it is held: a connectome answers with
  # spikes, not with evidence per hypothesis, so a learning module offered here
  # would be a number invented to fill a shape (`FlyversePlugin` on why).
  test "no learning module is offered, because a connectome is not one" do
    offered = Enum.map(FlyversePlugin.plugins(), & &1.describe()["kind"])

    assert :learning_module not in offered
    assert Enum.sort(offered) == [:experiment, :motor_policy]
  end

  test "the definition asks for the policy this node offers" do
    definition = FlyversePlugin.Experiment.run()
    names = Enum.map(FlyversePlugin.plugins(), & &1.describe()["name"])

    assert definition["motor_system"] in names
    assert definition["learning_modules"] == []
    assert definition["base"] == "base_10simobj_surf_agent"
    assert is_integer(definition["seed"])
  end

  # A definition cannot ask for fewer episodes than its config describes, and a
  # key nothing read would be a promise the record could not keep.
  test "the definition says only what a run reads" do
    assert Map.keys(FlyversePlugin.Experiment.run()) |> Enum.sort() ==
             ["base", "learning_modules", "motor_system", "seed"]
  end
end
