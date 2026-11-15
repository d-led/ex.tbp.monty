defmodule ExTbpMonty.Cluster.ConnectTest do
  @moduledoc """
  What a typed node name has to be before it is turned into an atom and dialled.

  The shape check is the whole safety story here: `Node.connect/1` takes an atom,
  and every distinct string that reaches `String.to_atom/1` is permanent — so the
  only names that become atoms are the ones that look like names.
  """
  use ExUnit.Case, async: true

  alias ExTbpMonty.Cluster.Connect

  describe "the names in what was typed" do
    test "are separated by whatever a person copied" do
      typed = "monty-studio-1a2b3c@10.0.0.7, node2@192.168.1.7\nworker@monty.internal"

      assert Connect.parse(typed) ==
               {:ok,
                ["monty-studio-1a2b3c@10.0.0.7", "node2@192.168.1.7", "worker@monty.internal"]}
    end

    test "an IPv6 host is a host" do
      # What a Fly Machine is named with, and the reason a colon cannot be the
      # thing that ends a name.
      assert Connect.parse("app-123@fdaa:0:1::2") == {:ok, ["app-123@fdaa:0:1::2"]}
    end

    test "are refused, one by one, when one of them is not a name" do
      assert {:error, sentence} = Connect.parse("node1@127.0.0.1, http://example.com")
      assert sentence =~ ~s("http://example.com" is not a node name)
      assert sentence =~ "name@host"
    end

    test "nothing at all is a sentence about what to type" do
      assert {:error, sentence} = Connect.parse("   ")
      assert sentence =~ "name a node to connect to"
      assert {:error, _same} = Connect.parse(nil)
    end
  end

  describe "dialling" do
    test "answers every name, even when this node cannot dial at all" do
      # A node with no name is a different sentence from an unreachable one: its
      # fix is on this machine, and a reader told "no answer" would go and look at
      # the other one.
      refute ExTbpMonty.Node.distributed?(), "this test is about a node with no name"

      assert [%{name: "node2@127.0.0.1", outcome: :no_name, note: note}] =
               Connect.dial(["node2@127.0.0.1"])

      assert note =~ "was not started with a name"
    end
  end
end
