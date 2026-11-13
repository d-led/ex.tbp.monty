defmodule ExTbpMonty.Cluster.OwnerTest do
  @moduledoc """
  Which node a run is on, when it is not this one.

  Every other node fact in the studio is read from a row — this is the one that
  turns a row back into a node, because a run's process can only be reached by
  asking the node that has it.
  """

  use ExTbpMonty.DataCase, async: false

  alias ExTbpMonty.Cluster.Owner
  alias Monty.Studio.RunHistory

  @attributes %{experiment: "tutorial/first_experiment", source: "monty", steps: 3}

  test "a peer's run is on that peer" do
    run = record(node: "gpu_127.0.0.1")

    assert Owner.elsewhere(run.id, [this_node(), peer("gpu_127.0.0.1")]) ==
             {:ok, :"gpu_127.0.0.1@127.0.0.1"}
  end

  test "a row from an older build carries the folder's name and still finds its node" do
    run = record(node: "gpu_127.0.0.1")

    assert Owner.elsewhere(run.id, [peer("gpu_127.0.0.1"), this_node()]) ==
             {:ok, :"gpu_127.0.0.1@127.0.0.1"}
  end

  test "this node's own run is not somewhere else to be asked about" do
    run = record(node: "this_a")

    assert Owner.elsewhere(run.id, [this_node(), peer("gpu_127.0.0.1")]) == :here
  end

  test "a run that names no node is here, as it is on a node that runs alone" do
    run = record(node: nil)

    assert Owner.elsewhere(run.id, [this_node()]) == :here
  end

  test "a run whose node the cluster no longer has is here: there is nobody to ask" do
    run = record(node: "gpu_127.0.0.1")

    assert Owner.elsewhere(run.id, [this_node()]) == :here
  end

  test "a run this node has never heard of is here" do
    assert Owner.elsewhere(Ecto.UUID.generate(), [this_node(), peer("gpu_127.0.0.1")]) == :here
  end

  defp record(attributes) do
    {:ok, run} = RunHistory.start(Map.merge(@attributes, Map.new(attributes)))
    run
  end

  defp this_node, do: %{node: node(), name: "this_a", self: true, alive: true}
  defp peer(name), do: %{node: :"#{name}@127.0.0.1", name: name, self: false, alive: true}
end
