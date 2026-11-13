defmodule ExTbpMonty.Cluster.PeersTest do
  @moduledoc """
  What a page is told about the other nodes' work: which peers are worth asking,
  and what a peer answers when it is asked.

  The answer a peer gives is this node's own `local_in_flight/0` — the same
  function, over `:rpc` — so these cases state both halves.
  """

  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Cluster.Peers
  alias Monty.Studio.RunHistory

  @attributes %{experiment: "tutorial/first_experiment", source: "monty", steps: 3}

  test "a cluster of one has nothing to report" do
    # There is no other node whose work this page could show, and an empty panel
    # is the honest answer rather than a panel naming this node.
    assert Peers.in_flight() == []
  end

  test "a peer's runs come back under the node that has them" do
    entries = [this_node(), peer("gpu_127.0.0.1")]

    groups =
      Peers.in_flight(entries, fn _name ->
        [
          %{
            id: "abc",
            experiment: "base_config_10distinctobj_dist_agent",
            state: "running",
            steps: 12
          }
        ]
      end)

    assert [%{node: %{name: "gpu_127.0.0.1"}, runs: [run]}] = groups
    assert run.experiment == "base_config_10distinctobj_dist_agent"
    assert run.steps == 12
  end

  test "this node is not asked about its own work" do
    # Its own runs are the list this page already draws; asking itself would be a
    # row twice.
    assert Peers.in_flight([this_node()], fn _name -> flunk("asked this node") end) == []
  end

  # A peer the poller could not reach is a peer whose list the reader is not
  # shown: an empty panel beside its name says nothing a reader can act on.
  test "a peer that did not answer is not a panel" do
    assert Peers.in_flight([peer("gone_1")], fn _name -> nil end) == []

    dead = %{peer("gone_1") | alive: false}

    assert Peers.in_flight([dead], fn _name -> flunk("asked a node that is not alive") end) == []
  end

  # What a peer gets when it asks this node: the runs it has not settled, and no
  # transcript — a row of somebody else's list does not need 53 MB of pictures.
  test "this node answers with the runs it has not settled" do
    {:ok, queued} = RunHistory.start(@attributes)
    {:ok, finished} = RunHistory.start(Map.put(@attributes, :experiment, "tutorial/other"))
    {:ok, _closed} = RunHistory.finish(finished, %{"steps" => 1})

    answers = Peers.local_in_flight()

    assert [%{id: id, experiment: "tutorial/first_experiment", state: "queued", steps: 0}] =
             answers

    assert id == queued.id
  end

  defp this_node,
    do: %{node: node(), name: "this_1", self: true, alive: true, capabilities: ["monty"]}

  defp peer(name) do
    %{node: :"#{name}@127.0.0.1", name: name, self: false, alive: true, capabilities: ["monty"]}
  end
end
