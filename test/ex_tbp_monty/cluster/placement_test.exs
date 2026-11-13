defmodule ExTbpMonty.Cluster.PlacementTest do
  @moduledoc """
  Who may perform a run: what a run asks for, which nodes answer, and what the
  node holding the job does about it.

  The entries are the ones `ExTbpMonty.Cluster.Nodes` publishes — `self`,
  `alive`, `capabilities` — because the decision is made over that list and
  nothing else.
  """

  use ExUnit.Case, async: true

  alias ExTbpMonty.Cluster.Placement

  test "a run needs monty, the world it steps, and whatever its inputs asked for" do
    assert Placement.needs(%{}) == ["monty"]
    assert Placement.needs(nil) == ["monty"]

    # The world is the one thing a build may lack, so a run of one says which.
    assert Placement.needs(%{"world" => "mujoco"}) == ["monty", "world:mujoco"]

    # ...except the port's own scene, which every build of it has.
    assert Placement.needs(%{"world" => "synthetic"}) == ["monty"]

    # Tags are written however a person thinks of them and compared in the
    # cluster's one spelling; asking for `monty` says nothing new.
    assert Placement.needs(%{"capabilities" => ["GPU", " big memory ", "monty"]}) == [
             "monty",
             "gpu",
             "big-memory"
           ]
  end

  test "a node performs a run whose needs it offers" do
    assert Placement.turn([us(["gpu"])], Placement.needs(%{"capabilities" => ["gpu"]})) ==
             :here
  end

  test "a node leaves the run to a peer that offers what it does not" do
    entries = [us([]), them(["gpu", "monty"])]

    assert Placement.turn(entries, ["monty", "gpu"]) ==
             {:wait, Placement.snooze_seconds()}

    # ...and asks again, rather than deciding once about a cluster that changes.
    assert Placement.snooze_seconds() > 0
  end

  test "a peer that did not answer is not a place a run can go" do
    # Its tags are the last thing this cluster heard of it, not a promise that
    # it is there to take the work.
    entries = [us([]), %{them(["gpu"]) | alive: false}]

    assert Placement.turn(entries, ["monty", "gpu"]) == :here
  end

  test "a run nobody offers is performed where it was asked" do
    # A tag that no node declared must not hold a run hostage: a cluster of
    # untagged nodes is one untagged machine, which is what a lone node is.
    assert Placement.turn([us([]), them([])], ["monty", "gpu"]) == :here
  end

  test "the node that has the job keeps it when it can do it, however many peers also can" do
    assert Placement.turn([us(["gpu"]), them(["gpu"])], ["monty", "gpu"]) == :here
  end

  test "the nodes that could take a run are the live ones that offer all of it" do
    entries = [
      us(["monty"]),
      them(["gpu"]),
      %{them(["gpu", "monty"]) | name: "dead_127.0.0.1", alive: false},
      %{us(["gpu", "monty"]) | name: "big_127.0.0.1", self: false}
    ]

    assert entries |> Placement.candidates(["monty", "gpu"]) |> Enum.map(& &1.name) ==
             ["big_127.0.0.1"]
  end

  defp us(tags),
    do: %{node: node(), name: "here_127.0.0.1", self: true, alive: true, capabilities: tags}

  defp them(tags),
    do: %{
      node: :"peer@127.0.0.1",
      name: "peer_127.0.0.1",
      self: false,
      alive: true,
      capabilities: tags
    }
end
