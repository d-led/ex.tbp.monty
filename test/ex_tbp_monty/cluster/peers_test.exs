defmodule ExTbpMonty.Cluster.PeersTest do
  @moduledoc """
  What a page is told about the other nodes' work: which peers are worth asking,
  and what a peer answers when it is asked.

  The answer a peer gives is this node's own `local_recent/0` — the same
  function, over `:rpc` — so these cases state both halves.
  """

  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Cluster.Peers
  alias Monty.Studio.RunHistory

  @attributes %{experiment: "tutorial/first_experiment", source: "monty", steps: 3}

  test "a cluster of one has nothing to report" do
    # There is no other node whose work this page could show, and an empty panel
    # is the honest answer rather than a panel naming this node.
    assert Peers.recent() == []
  end

  test "a peer's runs come back under the node that has them" do
    entries = [this_node(), peer("gpu_127.0.0.1")]

    groups =
      Peers.recent(entries, fn _name ->
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
    assert Peers.recent([this_node()], fn _name -> flunk("asked this node") end) == []
  end

  # A peer the poller could not reach is a peer whose list the reader is not
  # shown: an empty panel beside its name says nothing a reader can act on.
  test "a peer that did not answer is not a panel" do
    assert Peers.recent([peer("gone_1")], fn _name -> nil end) == []

    dead = %{peer("gone_1") | alive: false}

    assert Peers.recent([dead], fn _name -> flunk("asked a node that is not alive") end) == []
  end

  # What a peer gets when it asks this node: its latest runs with their states and
  # no transcript — a row of somebody else's list does not need 53 MB of pictures.
  # A settled run is in the answer too: "what has that machine been doing" is the
  # question a cluster's other nodes are asked.
  test "this node answers with its latest runs, settled or not" do
    {:ok, queued} = RunHistory.start(@attributes)
    {:ok, finished} = RunHistory.start(Map.put(@attributes, :experiment, "tutorial/other"))
    {:ok, _closed} = RunHistory.finish(finished, %{"steps" => 1})

    assert [%{id: closed_id, experiment: "tutorial/other", state: "finished"}, %{id: id}] =
             Peers.local_recent()

    assert id == queued.id
    assert closed_id == finished.id
  end

  # One runs table for the whole cluster is a deployment away, and there this
  # matters: a peer that answered with every run in the table would hand this page
  # its own runs back as somebody else's.
  test "a run another node owns is not this node's answer" do
    name = Monty.Paths.data_dir_name() || "node1_127.0.0.1"

    {:ok, theirs} = in_a_node("node2_127.0.0.1", fn -> RunHistory.start(@attributes) end)
    {:ok, ours} = in_a_node(name, fn -> RunHistory.start(@attributes) end)

    assert [%{id: id}] = Peers.local_recent()
    assert id == ours.id
    refute id == theirs.id
  end

  # The node a run was recorded on is the setting `config/runtime.exs` puts there
  # at boot; a test puts it there itself, because a test is not a node.
  defp in_a_node(name, fun) do
    previous = Application.get_env(:ex_tbp_monty, :data_dir_name)
    Application.put_env(:ex_tbp_monty, :data_dir_name, name)
    on_exit(fn -> Application.put_env(:ex_tbp_monty, :data_dir_name, previous) end)

    fun.()
  end

  defp this_node,
    do: %{node: node(), name: "this_1", self: true, alive: true, capabilities: ["monty"]}

  defp peer(name) do
    %{node: :"#{name}@127.0.0.1", name: name, self: false, alive: true, capabilities: ["monty"]}
  end
end
