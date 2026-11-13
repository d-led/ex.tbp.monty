defmodule ExTbpMonty.Cluster.CapabilitiesTest do
  @moduledoc """
  The vocabulary a cluster of unlike machines is described in.

  The variable is the environment's, so these cases cannot run beside one that
  sets it: `async: false`, and each puts it back.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Cluster.Capabilities

  setup do
    previous = System.get_env("MONTY_CAPABILITIES")
    on_exit(fn -> restore(previous) end)

    :ok
  end

  test "every node of this cluster runs this application's modules" do
    System.delete_env("MONTY_CAPABILITIES")

    assert Capabilities.declared() == ["monty"]
    assert Capabilities.from_environment() == []
  end

  test "the environment says what this machine has" do
    System.put_env("MONTY_CAPABILITIES", "gpu, world:mujoco")

    assert Capabilities.declared() == ["gpu", "monty", "world:mujoco"]
    assert Capabilities.from_environment() == ["gpu", "world:mujoco"]
  end

  test "a tag somebody typed is the tag a peer compares against" do
    System.put_env("MONTY_CAPABILITIES", "  GPU  ,World:Mujoco,")

    assert Capabilities.declared() == ["gpu", "monty", "world:mujoco"]
  end

  test "a tag written in another case still answers" do
    assert Capabilities.offers?(["gpu", "monty"], "GPU")
    refute Capabilities.offers?(["monty"], "gpu")
  end

  test "a tag is one spelling, whichever way it arrives" do
    assert Capabilities.normalise(:"World:Mujoco") == "world:mujoco"
    assert Capabilities.normalise(" two words ") == "two-words"
  end

  test "who can do what, one row per tag, a node once" do
    entries = [
      %{name: "a_1", capabilities: ["gpu", "monty"]},
      %{name: "b_2", capabilities: ["monty", "GPU"]},
      %{name: "c_3", capabilities: []}
    ]

    assert Capabilities.by_tag(entries) == [
             {"gpu", ["a_1", "b_2"]},
             {"monty", ["a_1", "b_2"]}
           ]
  end

  # A peer running a build older than this vocabulary answers with a version and
  # nothing else, and "no tags" is the honest reading of that answer.
  test "an entry that says nothing about itself has no tags" do
    assert Capabilities.of_entry(%{name: "old_1", version: "0.1.2"}) == []
    assert Capabilities.of_entry(%{name: "gone_1", capabilities: nil}) == []
  end

  defp restore(nil), do: System.delete_env("MONTY_CAPABILITIES")
  defp restore(value), do: System.put_env("MONTY_CAPABILITIES", value)
end
