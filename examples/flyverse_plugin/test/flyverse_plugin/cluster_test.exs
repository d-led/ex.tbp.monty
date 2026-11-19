defmodule FlyversePlugin.ClusterTest do
  @moduledoc """
  What this node was told to join, and what it does about it — the one
  12-factor decision this example makes that a test can hold without a second VM.

  Not `async`: the cases read variables the whole VM shares, and some of them
  unset one.
  """

  use ExUnit.Case, async: false

  alias Elixir.Cluster.Strategy.Epmd
  alias FlyversePlugin.Cluster

  setup do
    before = System.get_env("MONTY_SEEDS")
    on_exit(fn -> restore(before) end)
    :ok
  end

  test "seeds are the node names the deployment wrote, in the spelling OTP uses" do
    System.put_env("MONTY_SEEDS", "node1@127.0.0.1, node2@127.0.0.1")

    assert Cluster.seeds() == [:"node1@127.0.0.1", :"node2@127.0.0.1"]
  end

  test "a node nobody asked to cluster joins nothing, and opens no socket" do
    System.delete_env("MONTY_SEEDS")

    assert Cluster.seeds() == []
    assert Cluster.topologies() == []
  end

  test "one seed is dialled, and nothing is discovered beside it" do
    System.put_env("MONTY_SEEDS", "monty-studio-1a2b3c@127.0.0.1")

    topologies = Cluster.topologies()

    assert topologies[:seeds][:strategy] == Epmd
    assert topologies[:seeds][:config][:hosts] == [:"monty-studio-1a2b3c@127.0.0.1"]

    # The seed is the whole of it. A gossip topology would let a studio that is
    # open on this machine join itself to this node without anyone asking, which
    # is the one thing this example must not do: the two clusters stay separate
    # until a person connects them.
    assert Keyword.keys(topologies) == [:seeds]
  end

  test "the cookie is set before a topology starts, and an unnamed node sets none" do
    # The suite runs in a VM with no name, which is the case that has to answer
    # rather than raise: `Node.set_cookie/1` refuses an unnamed VM.
    refute Node.alive?()

    assert Cluster.set_cookie() == :ok
  end

  defp restore(nil), do: System.delete_env("MONTY_SEEDS")
  defp restore(value), do: System.put_env("MONTY_SEEDS", value)
end
