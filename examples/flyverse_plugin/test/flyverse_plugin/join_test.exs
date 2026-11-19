defmodule FlyversePlugin.JoinTest do
  @moduledoc """
  What the node says about the cluster it is in.

  libcluster does the connecting, so there is nothing here to drive: the case
  that matters most is the one with nowhere to join — a node in no cluster runs,
  answers `rpc`, and says nothing anywhere unless `Join` says it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlyversePlugin.Join

  test "a node with nothing to reach says so once, rather than staying silent" do
    log =
      capture_log(fn ->
        join = start_supervised!({Join, name: :flyverse_join_without_peers})
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
