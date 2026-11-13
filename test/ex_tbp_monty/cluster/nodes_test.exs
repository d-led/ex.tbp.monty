defmodule ExTbpMonty.Cluster.NodesTest do
  @moduledoc """
  What a page is told about the cluster: this node, the peers that answered, and
  the difference between a node nobody could reach and a node that is not there.

  The poller is not started in this suite — a node that runs alone has none, and
  `snapshot/0` answers anyway — so every case here is about the shape of the list
  rather than about a process.
  """

  use ExUnit.Case, async: true

  alias ExTbpMonty.Cluster.Nodes

  test "a node that runs alone is a cluster of one, and its version is its own" do
    assert [entry] = Nodes.snapshot()

    assert %{node: name, self: true, alive: true, version: version} = entry
    assert name == node()
    assert is_binary(version)
    assert Nodes.count() == 1
  end

  test "the entries are this node first, then the peers by name" do
    entries = Nodes.of([:"zed@127.0.0.1", :"amy@127.0.0.1"], &answered(&1, "0.1.3"))

    assert Enum.map(entries, & &1.name) == ["amy_127.0.0.1", "zed_127.0.0.1"]
    assert Enum.all?(entries, & &1.alive)
  end

  test "a node's entry carries the same name as its data folder" do
    # A reader who sees a node in the settings and a folder on disk is looking at
    # one thing, so the two names come from one function.
    [entry] = Nodes.of([node()])

    assert entry.name == ExTbpMonty.Node.safe_name(node())
  end

  test "a peer that did not answer is listed, and is not alive" do
    # "there is a node I cannot reach" and "there is no node" are different
    # sentences, and a list that dropped the first would be a lie about the
    # cluster.
    [entry] = Nodes.of([:"gone@127.0.0.1"], fn _name -> nil end)

    assert %{alive: false, version: nil, name: "gone_127.0.0.1"} = entry
  end

  test "this node is never asked over the network" do
    [entry] = Nodes.of([node()], fn _name -> flunk("asked the local node") end)

    assert %{self: true, alive: true} = entry
  end

  test "a peer is asked once per node, and its answer's version is the entry's" do
    parent = self()

    entries =
      Nodes.of([:"a@127.0.0.1", :"a@127.0.0.1", :"b@127.0.0.1"], fn name ->
        send(parent, {:asked, name})

        answered(name, "9.9.9")
      end)

    assert Enum.map(entries, & &1.version) == ["9.9.9", "9.9.9"]
    assert_received {:asked, :"a@127.0.0.1"}
    assert_received {:asked, :"b@127.0.0.1"}
    refute_received {:asked, _another}
  end

  test "it tells a peer its own name and build" do
    assert %{node: name, version: version} = Nodes.identity()

    assert name == node()
    assert is_binary(version)
  end

  defp answered(_node, version), do: %{version: version}
end
