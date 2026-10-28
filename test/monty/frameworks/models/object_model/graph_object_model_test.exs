defmodule Monty.Frameworks.Models.ObjectModel.GraphObjectModelTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation
  alias Monty.Math

  @tolerance Math.default_tolerance()

  defp model(locations, features, k_n \\ nil, thresholds \\ nil) do
    {:ok, built} =
      GraphObjectModel.new("cone", k_n: k_n, graph_delta_thresholds: thresholds)
      |> GraphObjectModel.build_model(locations, features)

    built
  end

  describe "building a graph from observations" do
    test "one node per observation, and a node id column before the features" do
      built =
        model([[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.5, 0.0, 0.0]], %{
          "rgba" => [[0.1], [0.2], [0.3]]
        })

      assert GraphObjectModel.num_nodes(built) == 3

      assert GraphObjectModel.graph(built).pos == [
               [0.0, 0.0, 0.0],
               [0.01, 0.0, 0.0],
               [0.5, 0.0, 0.0]
             ]

      assert GraphObjectModel.graph(built).x == [[0.0, 0.1], [1.0, 0.2], [2.0, 0.3]]
    end

    test "each feature is a named range of columns" do
      built = model([[0.0, 0.0, 0.0]], %{"rgba" => [[0.1, 0.2, 0.3]]})

      assert GraphObjectModel.get_values_for_feature(built, "rgba") == [[0.1, 0.2, 0.3]]
      assert GraphObjectModel.feature_ids_in_graph(built) == ["node_ids", "rgba"]
    end

    test "the surface normal is kept apart, because a search is oriented by it" do
      pose = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

      built = model([[0.0, 0.0, 0.0]], %{"pose_vectors" => [pose]})

      assert GraphObjectModel.graph(built).norm == [[0.0, 0.0, 1.0]]
    end

    test "observations that repeat a spot do not become nodes" do
      built = model([[0.0, 0.0, 0.0], [0.0001, 0.0, 0.0]], %{"rgba" => [[0.1], [0.1]]})

      assert GraphObjectModel.num_nodes(built) == 1
    end

    test "a graph without k_n has no edges" do
      built = model([[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]], %{"rgba" => [[0.1], [0.2]]})

      assert GraphObjectModel.graph(built).edge_index == nil
      assert GraphObjectModel.graph(built).edge_attr == nil
    end
  end

  describe "linking nodes to their neighbours" do
    setup do
      locations = [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0], [5.0, 0.0, 0.0], [5.1, 0.0, 0.0]]
      features = %{"rgba" => Enum.map(locations, fn [x | _] -> [x] end)}

      # k_n counts edges, so 0 asks for one neighbour per node.
      %{built: model(locations, features, 0)}
    end

    test "each node links to its nearest neighbour, and the displacement is the edge", %{
      built: built
    } do
      %{edge_index: {sources, targets}, edge_attr: displacements} = GraphObjectModel.graph(built)

      assert sources == [0, 1, 2, 3]
      assert targets == [1, 0, 3, 2]

      assert Enum.map(displacements, fn [dx | _] -> Float.round(dx, 6) end) ==
               [0.1, -0.1, 0.1, -0.1]
    end

    test "an edge can be looked up from its ends", %{built: built} do
      assert GraphObjectModel.edge_index_between(built, 0, 1) == 0
      assert GraphObjectModel.edge_index_between(built, 0, 2) == nil
    end
  end

  describe "finding the nearest nodes" do
    setup do
      locations = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [5.0, 0.0, 0.0], [5.5, 0.0, 0.0]]
      features = %{"rgba" => Enum.map(locations, fn [x | _] -> [x] end)}

      %{built: model(locations, features)}
    end

    test "one list per search location, nearest first", %{built: built} do
      assert GraphObjectModel.find_nearest_neighbors(built, [[4.0, 0.0, 0.0]], 2) == [[2, 3]]
    end

    test "as many searches as asked, in the order they were asked", %{built: built} do
      assert GraphObjectModel.find_nearest_neighbors(built, [[0.1, 0.0, 0.0], [5.1, 0.0, 0.0]], 1) ==
               [[0], [2]]
    end

    test "a graph with fewer nodes than asked answers with the nodes it has", %{built: built} do
      assert GraphObjectModel.find_nearest_neighbors(built, [[0.0, 0.0, 0.0]], 10) == [
               [0, 1, 2, 3]
             ]
    end

    test "equally distant nodes are ordered by id, so a run is repeatable", %{built: built} do
      # Nodes 0 and 2 are both 2.5 m away; the lower id is taken first.
      assert GraphObjectModel.find_nearest_neighbors(built, [[2.5, 0.0, 0.0]], 2) == [[1, 0]]
    end
  end

  describe "extending a graph" do
    test "new observations join the point cloud and keep the old nodes first" do
      pose = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

      built =
        model(
          [[0.0, 0.0, 0.0], [0.2, 0.0, 0.0]],
          %{"rgba" => [[0.1], [0.15]], "pose_vectors" => [pose, pose]},
          0
        )

      {:ok, extended} =
        GraphObjectModel.update_model(
          built,
          [[1.0, 0.0, 0.0]],
          %{"rgba" => [[0.9]], "pose_vectors" => [pose]},
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          Rotation.identity()
        )

      assert GraphObjectModel.num_nodes(extended) == 3

      assert GraphObjectModel.graph(extended).pos == [
               [0.0, 0.0, 0.0],
               [0.2, 0.0, 0.0],
               [1.0, 0.0, 0.0]
             ]

      assert GraphObjectModel.get_values_for_feature(extended, "rgba") == [[0.1], [0.15], [0.9]]
    end

    test "a feature the graph has never stored takes new columns, zero for the old nodes" do
      built = model([[0.0, 0.0, 0.0]], %{"rgba" => [[0.1]]})

      {all_locations, all_features} =
        GraphObjectModel.combine_graph_information(built, [[1.0, 0.0, 0.0]], %{
          "rgba" => [[0.5]],
          "hsv" => [[0.2, 0.3, 0.4]]
        })

      assert length(all_locations) == 2
      assert all_features["rgba"] == [[0.1], [0.5]]
      assert all_features["hsv"] == [[0.0, 0.0, 0.0], [0.2, 0.3, 0.4]]
    end

    test "a feature the graph stores but this step did not observe is refused" do
      built = model([[0.0, 0.0, 0.0]], %{"rgba" => [[0.1]], "hsv" => [[0.2, 0.3, 0.4]]})

      assert_raise ArgumentError, ~r/hsv/, fn ->
        GraphObjectModel.combine_graph_information(built, [[1.0, 0.0, 0.0]], %{"rgba" => [[0.5]]})
      end
    end
  end

  describe "a model that was loaded rather than built" do
    test "has no nodes until a graph is set" do
      assert GraphObjectModel.num_nodes(GraphObjectModel.new("cup")) == 0
    end

    test "takes a graph as it is" do
      {:ok, loaded} =
        GraphObjectModel.set_graph(GraphObjectModel.new("cup"), %{
          pos: [[0.0, 0.0, 0.0]],
          x: [],
          feature_mapping: %{}
        })

      assert GraphObjectModel.num_nodes(loaded) == 1
      assert_in_delta length(GraphObjectModel.positions(loaded)), 1, @tolerance
    end
  end
end
