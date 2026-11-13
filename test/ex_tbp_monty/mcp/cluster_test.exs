defmodule ExTbpMonty.Mcp.ClusterTest do
  @moduledoc """
  `monty_cluster_nodes`: what a caller that is about to put work on the cluster
  is told about it.

  The list itself is `ExTbpMonty.Cluster.Nodes`, which has its own tests. These
  are about the *answer*: the machine-readable one a program routes by, and the
  text one a model reads, stated for two nodes without starting a second VM.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Mcp.Tools.Cluster

  @this %{
    node: :"this@127.0.0.1",
    name: "this_127.0.0.1",
    version: "0.1.3",
    self: true,
    alive: true,
    capabilities: ["monty"]
  }

  @gpu %{
    node: :"gpu@127.0.0.1",
    name: "gpu_127.0.0.1",
    version: "0.1.3",
    self: false,
    alive: true,
    capabilities: ["gpu", "monty", "world:mujoco"]
  }

  test "a node that runs alone answers with one entry, and says clustering is off" do
    assert {:ok, %{text: text, structured: structured}} = call()

    assert %{"enabled" => false, "nodes" => [node]} = structured
    assert node["self"] == true
    assert node["alive"] == true
    assert "monty" in node["capabilities"]
    assert text =~ "Clustering is off here"
  end

  test "each node is one entry, with its build and its tags" do
    assert [
             %{"name" => "this_127.0.0.1", "self" => true, "capabilities" => ["monty"]},
             %{
               "name" => "gpu_127.0.0.1",
               "version" => "0.1.3",
               "capabilities" => ["gpu", "monty", "world:mujoco"]
             }
           ] = Cluster.structured([@this, @gpu])["nodes"]
  end

  # The direction a caller routes by: it has a tag, it needs a node. One map, so
  # a program does not have to walk every row.
  test "a tag answers with the nodes that have it" do
    assert Cluster.structured([@this, @gpu])["by_capability"] == %{
             "gpu" => ["gpu_127.0.0.1"],
             "monty" => ["gpu_127.0.0.1", "this_127.0.0.1"],
             "world:mujoco" => ["gpu_127.0.0.1"]
           }
  end

  test "the text names the nodes, marks this one, and lists the tags" do
    text = Cluster.text([@this, @gpu])

    assert text =~ "this_127.0.0.1 · 0.1.3 · this node · monty"
    assert text =~ "gpu_127.0.0.1 · 0.1.3 · gpu monty world:mujoco"
    assert text =~ "What this cluster can do:"
    assert text =~ "gpu: gpu_127.0.0.1"
  end

  # A peer that did not answer is still a node somebody expected: it stays in the
  # answer, and `alive: false` is what a caller checks before sending it work.
  test "a peer that did not answer stays in the answer, and is not alive" do
    silent = %{@gpu | version: nil, alive: false, capabilities: []}

    assert [_, %{"alive" => false, "version" => nil}] =
             Cluster.structured([@this, silent])["nodes"]

    assert Cluster.text([@this, silent]) =~ "gpu_127.0.0.1 · no answer"
  end

  defp call do
    ExTbpMonty.Mcp.Tools.call("monty_cluster_nodes", %{}, %{base_url: "http://localhost:4000"})
  end
end
