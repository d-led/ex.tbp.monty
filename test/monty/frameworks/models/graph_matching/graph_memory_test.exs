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

  # A quarter turn about z, so a point the body saw at +x lies at -y in the model.
  defp quarter_turn do
    {:ok, rotation} = Rotation.from_euler_degrees([0.0, 0.0, 90.0])
    rotation
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

    test "the pose vectors of named nodes come back in the order they were named" do
      # Two nodes with different frames, so that keeping the order of the ids
      # and reaching the right nodes are both visible in the answer.
      turned = [0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0]
      locations = for index <- 0..2//1, do: [index / 10, 0.0, 0.0]

      mug =
        GraphObjectModel.new("mug")
        |> GraphObjectModel.build_model(
          locations,
          %{
            "rgba" => Enum.map(locations, fn [x | _] -> [x] end),
            "pose_vectors" => [@pose, @pose, turned]
          },
          nil,
          nil
        )

      memory = loaded(%{"mug" => mug})

      assert GraphMemory.get_rotation_features_at_nodes(memory, "mug", "patch", [2, 0]) == [
               [[0.0, 0.0, 1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]],
               [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
             ]
    end

    test "a graph that learns a node hands out that node's frame too" do
      # The frames a graph stores are kept once and read many times, so a graph
      # that grows is the case that says whether what is kept follows it.
      turned = [0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0]
      memory = loaded(%{"mug" => model("mug", 1)})

      grown =
        GraphMemory.update_memory(
          memory,
          [[1.0, 0.0, 0.0]],
          %{
            "patch" => %{
              "rgba" => [[0.9]],
              "pose_fully_defined" => [true],
              "pose_vectors" => [turned]
            }
          },
          "mug",
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          Rotation.identity()
        )

      assert GraphMemory.get_rotation_features_at_all_nodes(grown, "mug", "patch") == [
               [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
               [[0.0, 0.0, 1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]]
             ]
    end

    test "the rows are also kept as the flat binary a native kernel reads" do
      memory = loaded(%{"mug" => model("mug", 3)})

      assert {binary, 1} = GraphMemory.get_feature_rows(memory, "mug", "patch")
      assert for(<<value::float-64-little <- binary>>, do: value) == [0.0, 0.1, 0.2]
    end

    test "a row with no values is not a row to read flat" do
      # A node whose features could not be read is a node with no evidence, which
      # the comparison says node by node: there is no rectangle here to hand to
      # something that reads one row after another.
      memory = loaded(%{"mug" => model("mug", 1)})

      graph = GraphMemory.get_graph(memory, "mug", "patch")
      {:ok, stripped} = GraphObjectModel.set_graph(graph, %{graph.graph | x: [[0.0]]})

      memory =
        memory
        |> GraphMemory.add_graph_to_memory(%{"patch" => stripped}, "mug")
        |> GraphMemory.initialize_feature_arrays()

      assert GraphMemory.get_feature_array(memory, "mug", "patch") == [[]]
      assert GraphMemory.get_feature_rows(memory, "mug", "patch") == nil
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

    # Monty's `GraphMemoryUpdateMemoryTest`. It drives `_build_graph` and
    # `_extend_graph` with mocks; here the same three cases are read off the
    # memory afterwards, because where a node ends up is what a caller can see and
    # what the bug was about.

    # Monty: "test_if_unknown_object_builds_graph_from_features". An unknown
    # object has no reference frame, so there is nothing to transform into and its
    # points are stored as they came.
    test "an unknown object is built from the points as they came, untransformed" do
      learned =
        GraphMemory.update_memory(
          memory(),
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
          quarter_turn()
        )

      assert GraphMemory.get_locations_in_graph(learned, "mug", "patch") == [[1.0, 0.0, 0.0]]
    end

    # Monty: "test_if_known_object_and_known_channel_extends_graph". A channel the
    # object already has is added to, in one graph, not rebuilt.
    test "a known object's known channel is extended rather than built again" do
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
          quarter_turn()
        )

      assert GraphMemory.get_num_nodes_in_graph(extended, "mug", "patch") == 3
      assert GraphMemory.get_input_channels_in_graph(extended, "mug") == ["patch"]
    end

    # Monty: "test_if_known_object_and_unknown_channel_builds_graph_from_rotated_
    # features" — a channel first seen in a *later* episode. Without the transform,
    # this channel's nodes are in the body's frame while the object's other
    # channels are in the model's, and the two never line up: that misalignment is
    # PR #1280.
    test "a known object's new channel is transformed into the object's frame" do
      # A map of what this experiment reads, with both channels named: the second
      # one is only in the map because a later episode is about to bring it.
      memory =
        GraphMemory.new(features_to_use: %{"patch" => ["rgba"], "view_finder" => ["rgba"]})
        |> GraphMemory.add_graph_to_memory(%{"patch" => model("mug", 2)}, "mug")
        |> GraphMemory.initialize_feature_arrays()

      learned =
        GraphMemory.update_memory(
          memory,
          [[1.0, 0.0, 0.0]],
          %{
            "view_finder" => %{
              "rgba" => [[0.9]],
              "pose_fully_defined" => [true],
              # Looking along +x: a quarter turn to the left of it is +y.
              "pose_vectors" => [[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]]
            }
          },
          "mug",
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          quarter_turn()
        )

      # The object was seen a quarter turn away from the model, so the point the
      # body saw at +x is at -y in the model.
      assert [[x, y, z]] = GraphMemory.get_locations_in_graph(learned, "mug", "view_finder")
      assert_in_delta x, 0.0, 1.0e-12
      assert_in_delta y, -1.0, 1.0e-12
      assert_in_delta z, 0.0, 1.0e-12

      # And the pose travels with the point, or the channel would be in the right
      # place facing the wrong way. Read off the graph the new channel built,
      # because the pose features are not among the ones a module compares.
      assert [[nx, ny, _nz, _, _, _, _, _, _]] =
               learned
               |> GraphMemory.get_graph("mug", "view_finder")
               |> GraphObjectModel.get_values_for_feature("pose_vectors")

      assert_in_delta nx, 0.0, 1.0e-12
      assert_in_delta ny, -1.0, 1.0e-12
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
