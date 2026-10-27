defmodule Monty.Frameworks.Models.GraphMatching.GraphMemoryTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

  defp memory(options \\ []) do
    GraphMemory.new(Keyword.put_new(options, :features_to_use, %{"patch" => ["rgba"]}))
  end

  # A model with `count` nodes a decimetre apart and a colour per node.
  defp model(object_id, count) do
    locations = for index <- 0..(count - 1)//1, do: [index / 10, 0.0, 0.0]

    features = %{
      "rgba" => Enum.map(locations, fn [x | _] -> [x] end),
      "pose_vectors" => List.duplicate(@pose, count)
    }

    GraphObjectModel.new(object_id)
    |> GraphObjectModel.build_model(locations, features, nil, nil)
  end

  defp loaded(models) do
    models
    |> Enum.reduce(memory(), fn {graph_id, model}, memory ->
      GraphMemory.add_graph_to_memory(memory, %{"patch" => model}, graph_id)
    end)
    |> GraphMemory.initialize_feature_arrays()
  end

  describe "what memory knows" do
    test "objects and their channels can be listed" do
      memory = loaded(%{"mug" => model("mug", 2), "cup" => model("cup", 3)})

      assert Enum.sort(GraphMemory.get_memory_ids(memory)) == ["cup", "mug"]
      assert GraphMemory.get_input_channels_in_graph(memory, "mug") == ["patch"]
      assert GraphMemory.size(memory) == 2
    end

    test "a graph is stored per channel, and :first picks one" do
      memory = loaded(%{"mug" => model("mug", 2)})

      assert %{"patch" => %GraphObjectModel{}} = GraphMemory.get_graph(memory, "mug", nil)
      assert %GraphObjectModel{} = GraphMemory.get_graph(memory, "mug", "patch")

      assert GraphMemory.get_graph(memory, "mug", :first) ==
               GraphMemory.get_graph(memory, "mug", "patch")
    end

    test "asking for a channel the object does not have says so" do
      memory = loaded(%{"mug" => model("mug", 2)})

      assert_raise ArgumentError, ~r/no data stored/, fn ->
        GraphMemory.get_graph(memory, "mug", "view_finder")
      end
    end

    test "node ids are the node indices, and node counts add up over channels" do
      memory = loaded(%{"mug" => model("mug", 3)})

      assert GraphMemory.get_graph_node_ids(memory, "mug", "patch") == [0, 1, 2]
      assert GraphMemory.get_num_nodes_in_graph(memory, "mug", "patch") == 3
      assert GraphMemory.get_num_nodes_in_graph(memory, "mug", nil) == 3
    end

    test "locations come from the graph, so a caller never reaches into it" do
      memory = loaded(%{"mug" => model("mug", 2)})

      assert GraphMemory.get_locations_in_graph(memory, "mug", "patch") == [
               [0.0, 0.0, 0.0],
               [0.1, 0.0, 0.0]
             ]
    end

    test "recognition starts with everything in memory as a candidate" do
      memory = loaded(%{"mug" => model("mug", 2), "cup" => model("cup", 2)})

      assert {candidates, paths} = GraphMemory.get_initial_hypotheses(memory)
      assert Enum.sort(Map.keys(candidates)) == ["cup", "mug"]
      assert paths == %{}
    end
  end

  describe "the feature rows matching compares against" do
    test "one row per node, pose features left out, with the column order alongside" do
      memory = loaded(%{"mug" => model("mug", 3)})

      assert GraphMemory.get_feature_order(memory, "mug", "patch") == ["rgba"]
      assert GraphMemory.get_feature_array(memory, "mug", "patch") == [[0.0], [0.1], [0.2]]
    end

    test "a node's features can be read by id, and by name" do
      memory = loaded(%{"mug" => model("mug", 3)})

      assert GraphMemory.get_features_at_node(memory, "mug", "patch", 1) == %{"rgba" => [0.1]}

      assert GraphMemory.get_features_at_node(memory, "mug", "patch", 1, ["rgba"]) == %{
               "rgba" => [0.1]
             }

      assert GraphMemory.get_features_at_node(memory, "mug", "patch", [0, 2]) == %{
               "rgba" => [[0.0], [0.2]]
             }
    end

    test "the pose vectors of every node come back as three directions each" do
      memory = loaded(%{"mug" => model("mug", 2)})

      pose = [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

      assert GraphMemory.get_rotation_features_at_all_nodes(memory, "mug", "patch") == [
               pose,
               pose
             ]
    end
  end

  describe "learning from observations" do
    test "an object seen for the first time becomes a model, with no edges yet" do
      memory = memory()

      learned =
        GraphMemory.update_memory(
          memory,
          [[0.0, 0.0, 0.0], [0.5, 0.0, 0.0]],
          %{
            "patch" => %{
              "rgba" => [[0.1], [0.2]],
              "pose_fully_defined" => [true, true],
              "pose_vectors" => [@pose, @pose]
            }
          },
          "mug",
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          Rotation.identity()
        )

      assert GraphMemory.get_memory_ids(learned) == ["mug"]
      assert GraphMemory.get_num_nodes_in_graph(learned, "mug", "patch") == 2

      assert GraphObjectModel.graph(GraphMemory.get_graph(learned, "mug", "patch")).edge_index ==
               nil
    end

    test "an object seen again is extended rather than replaced" do
      memory = loaded(%{"mug" => model("mug", 2)})

      extended =
        GraphMemory.update_memory(
          memory,
          [[1.0, 0.0, 0.0]],
          %{
            "patch" => %{
              "rgba" => [[0.9]],
              "pose_fully_defined" => [true],
              "pose_vectors" => [@pose]
            }
          },
          "mug",
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          Rotation.identity()
        )

      assert GraphMemory.get_num_nodes_in_graph(extended, "mug", "patch") == 3
    end

    test "an observation the sensor saw nothing in is not learned from" do
      memory = memory()

      learned =
        GraphMemory.update_memory(
          memory,
          [[0.0, 0.0, 0.0], [0.5, 0.0, 0.0]],
          %{
            "patch" => %{
              "rgba" => [[0.1], [0.2]],
              "pose_fully_defined" => [false, true],
              "pose_vectors" => [@pose, @pose]
            }
          },
          "mug",
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          Rotation.identity()
        )

      assert GraphMemory.get_num_nodes_in_graph(learned, "mug", "patch") == 1
    end

    test "nothing is learned when recognition never settled on an object" do
      memory = memory()

      assert GraphMemory.update_memory(
               memory,
               [[0.0, 0.0, 0.0]],
               %{
                 "patch" => %{
                   "rgba" => [[0.1]],
                   "pose_fully_defined" => [true],
                   "pose_vectors" => [@pose]
                 }
               },
               nil,
               [0.0, 0.0, 0.0],
               [0.0, 0.0, 0.0],
               Rotation.identity()
             ) == memory
    end
  end

  describe "saving and loading" do
    test "a memory reloads with every object it had" do
      saved = loaded(%{"mug" => model("mug", 2)})

      reloaded =
        saved |> GraphMemory.state_dict() |> then(&GraphMemory.load_state_dict(memory(), &1))

      assert GraphMemory.get_memory_ids(reloaded) == ["mug"]
      assert GraphMemory.get_num_nodes_in_graph(reloaded, "mug", "patch") == 2
    end

    test "an object can be forgotten" do
      memory = loaded(%{"mug" => model("mug", 2)})

      assert GraphMemory.remove_graph_from_memory(memory, "mug") |> GraphMemory.get_memory_ids() ==
               []
    end
  end
end
