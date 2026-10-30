defmodule Monty.PretrainedMemoryTest do
  @moduledoc """
  Monty's pretrained object library, as memory the port can match against.

  `priv/monty/libraries/surf_agent_1lm_10distinctobj.jsonl.gz` is the memory Monty
  trained for `surf_agent_1lm_10distinctobj`, exported from the torch pickle by
  `scripts/export_monty_pretrained.py`: ten YCB objects, sixteen thousand nodes,
  each with the features the evidence-based learning module compares. A model is
  positions and rows of features, so a model trained in Python is one this port
  can hold — which is what makes "the same numbers" a question that can be
  asked at all.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Test.MontyRecording

  @pretrained "priv/monty/libraries/pretrained_ycb_v10/surf_agent_1lm_10distinctobj.jsonl.gz"

  # Ten models and sixteen thousand nodes: slow enough on a cold runner that
  # ExUnit's minute is not enough, and there is no reason to build it once per
  # test.
  @moduletag timeout: 300_000

  setup_all do
    {:ok, memory: MontyRecording.load_pretrained!(@pretrained)}
  end

  # What the export reported, object by object, and therefore what a loaded
  # memory must still hold.
  @node_counts %{
    "banana" => 745,
    "bowl" => 2944,
    "c_lego_duplo" => 1907,
    "dice" => 671,
    "golf_ball" => 320,
    "mug" => 2220,
    "mustard_bottle" => 2083,
    "potted_meat_can" => 2439,
    "spoon" => 1925,
    "strawberry" => 829
  }

  # The export is plain JSON, so a test can hold a loaded model to it.
  defp first_exported_node(object_id) do
    @pretrained
    |> File.read!()
    |> :zlib.gunzip()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["object_id"] == object_id))
    |> Map.fetch!("positions")
  end

  describe "a memory exported from Monty" do
    test "holds every object Monty trained, with every node it stored", %{memory: memory} do
      assert Enum.sort(GraphMemory.get_memory_ids(memory)) ==
               @node_counts |> Map.keys() |> Enum.sort()

      for {object_id, count} <- @node_counts do
        assert GraphMemory.get_num_nodes_in_graph(memory, object_id, "patch") == count,
               "#{object_id} lost nodes on the way in"
      end
    end

    test "keeps the features the learning module matches on, and no others", %{memory: memory} do
      assert GraphMemory.get_feature_order(memory, "mug", "patch") ==
               ["hsv", "principal_curvatures_log"]

      model = GraphMemory.get_graph(memory, "mug", "patch")
      assert %GraphObjectModel{} = model

      assert [row | _] = GraphObjectModel.get_values_for_feature(model, "hsv")
      assert [_, _, _] = row

      assert [pose | _] = GraphObjectModel.get_values_for_feature(model, "pose_vectors")
      assert [_, _, _, _, _, _, _, _, _] = pose
    end

    test "a node is where Monty put it, to the last exported digit", %{memory: memory} do
      assert [first_exported | _] = first_exported_node("mug")

      assert [^first_exported | _] =
               GraphMemory.get_locations_in_graph(memory, "mug", "patch")
    end
  end

  describe "a recording of a pretrained episode" do
    test "carries the evidence Monty held after every step" do
      evidence =
        MontyRecording.evidence_over_steps!("test/fixtures/monty_pretrained_episode.jsonl")

      held = Enum.filter(evidence, &(map_size(&1) > 0))

      assert held != []

      assert held |> hd() |> Map.keys() |> Enum.sort() ==
               @node_counts |> Map.keys() |> Enum.sort()

      assert Map.has_key?(hd(held), "mug")
      assert is_float(hd(held)["mug"])
    end
  end
end
