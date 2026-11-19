defmodule ExamplePlugin.JoinTest do
  @moduledoc """
  What the node says about the cluster it is in.

  libcluster does the connecting, so there is nothing here to drive: the case
  that matters is the sentence a person reads, at boot and when a peer arrives
  or leaves.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExamplePlugin.Join

  test "a node in no cluster says so, once, when it starts" do
    # A node that is in no cluster is the failure nobody can see: it runs, it
    # answers `rpc`, and every page says one node. The line names what it looked
    # for, so "it never joined" has something to find.
    log =
      capture_log(fn ->
        join = start_supervised!({Join, name: :join_without_peers})
        assert :sys.get_state(join) == []
      end)

    assert log =~ "not in a cluster"
    assert log =~ "MONTY_SEEDS"
  end

  test "the sentence names the peers it is in a cluster with" do
    assert Join.describe([:"node1@127.0.0.1", :"node2@127.0.0.1"]) ==
             "in a cluster with node1@127.0.0.1, node2@127.0.0.1"
  end
end
