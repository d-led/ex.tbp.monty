defmodule ExTbpMonty.NodeTest do
  @moduledoc """
  What the node module promises: the answer to "am I in a cluster" is the VM's
  answer, and a node that is not says what would make it one.
  """
  use ExUnit.Case, async: true

  alias ExTbpMonty.Node

  test "the answer is the VM's own, not a setting" do
    assert Node.distributed?() == (node() != :nonode@nohost)
    assert Node.name() == node()
  end

  test "a node with no name is told the variable and the command line" do
    if Node.distributed?() do
      assert Node.why_not() == nil
    else
      assert Node.why_not() =~ "was not started with a name"
      assert Node.why_not() =~ "NODE_NAME"
      assert Node.why_not() =~ "elixir --sname monty"
    end
  end

  test "the peers are the VM's peers" do
    # `:erlang.nodes/0` rather than `Node.list/0`: inside this module `Node` names
    # the module under test, and a test that reached the real one through the alias
    # would be asserting that a function calls itself.
    assert Node.peers() == :erlang.nodes()
  end

  test "the settings report unset variables as unset, not as defaults" do
    settings = Node.settings()

    assert Map.has_key?(settings, "NODE_NAME")
    assert Map.has_key?(settings, "PLUGIN_SCOPE")

    if System.get_env("PLUGIN_SCOPE") == nil do
      assert settings["PLUGIN_SCOPE"] == nil
    end
  end
end
