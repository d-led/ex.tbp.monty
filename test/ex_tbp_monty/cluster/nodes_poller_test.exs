defmodule ExTbpMonty.Cluster.NodesPollerTest do
  @moduledoc """
  The one case that needs the poller running: what a page gets *while* the poller
  is busy.

  It writes a value shared by the whole VM (`:persistent_term`), so it cannot run
  beside a case that expects no list to be there — `async: false`, and the value
  is erased afterwards.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Cluster.Nodes

  setup do
    on_exit(fn -> :persistent_term.erase({Nodes, :snapshot}) end)

    :ok
  end

  # A page reads the list, it does not ask for it. The poller is one process that
  # asks each peer in turn, and a peer that has just died answers nothing for as
  # long as its probe allows: a `GenServer.call` would put every page behind that
  # wait, and a long enough cluster would put it past the call's own timeout, which
  # is a crash for reading a list.
  test "the list is read from the last poll, even while the poller is suspended" do
    pid = start_supervised!({Nodes, []})

    assert [%{self: true, alive: true}] = Nodes.snapshot()

    :sys.suspend(pid)

    assert [%{self: true, alive: true}] = Nodes.snapshot()

    :sys.resume(pid)
  end
end
