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

  # A module matching on `"PPF"` compares four numbers per edge — the length and
  # three angles — so `torch_geometric`'s `PointPairFeatures(cat=False)` replaces
  # the displacement an ordinary edge carries. There is no Monty test for it: the
  # numbers below are the transform's own definition read off two nodes a metre
  # apart with perpendicular normals.
  describe "point-pair features" do
    @pi :math.pi()

    # Node 0 at the origin facing +z, node 1 a metre along +x facing +x.
    defp ppf_model do
      locations = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]]

      features = %{
        "rgba" => [[0.1], [0.2]],
        "pose_vectors" => [
          [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
          [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
        ]
      }

      {:ok, built} =
        GraphObjectModel.new("mug", k_n: 0, has_ppf: true)
        |> GraphObjectModel.build_model(locations, features)

      built
    end

    test "each edge carries the length and the three angles of the nodes it links" do
      %{edge_index: {sources, targets}, edge_attr: features} =
        GraphObjectModel.graph(ppf_model())

      # Both ways round: 0 → 1 and 1 → 0.
      assert {sources, targets} == {[0, 1], [1, 0]}

      # `d` runs source → target: [1,0,0] one way and [-1,0,0] the other.
      # From node 0 (normal +z): 90° to the line, 0° for node 1 whose normal is
      # the line itself, 90° between the normals.
      assert_close(hd(features), [1.0, @pi / 2, 0.0, @pi / 2])

      # The way back: node 1's normal is against the line (180°), node 0's is
      # still at 90° to it.
      assert_close(Enum.at(features, 1), [1.0, @pi, @pi / 2, @pi / 2])
    end

    test "a model that does not ask for them keeps its displacements" do
      {:ok, built} =
        GraphObjectModel.new("mug", k_n: 0)
        |> GraphObjectModel.build_model(
          [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]],
          %{"rgba" => [[0.1], [0.2]], "pose_vectors" => List.duplicate([0.0, 0.0, 1.0], 2)}
        )

      assert GraphObjectModel.graph(built).edge_attr == [[1.0, 0.0, 0.0], [-1.0, 0.0, 0.0]]
      refute built.has_ppf
    end

    test "a loaded graph without them gets them, the way a pickle arrives" do
      # What a memory read from a pickle holds: a graph built by a module that
      # matched on displacements, so its edges are displacements.
      {:ok, loaded} =
        GraphObjectModel.new("mug", k_n: 0)
        |> GraphObjectModel.build_model(
          [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]],
          %{"rgba" => [[0.1], [0.2]], "pose_vectors" => List.duplicate([0.0, 0.0, 1.0], 2)}
        )

      assert length(hd(GraphObjectModel.graph(loaded).edge_attr)) == 3

      {:ok, ppf} =
        GraphObjectModel.new("mug", k_n: 0, has_ppf: true)
        |> GraphObjectModel.set_graph(GraphObjectModel.graph(loaded))

      assert length(hd(GraphObjectModel.graph(ppf).edge_attr)) == 4
    end

    test "a graph with no pose vectors is refused, because a normal is half of every feature" do
      {:ok, without_normals} =
        GraphObjectModel.new("mug", k_n: 0)
        |> GraphObjectModel.build_model(
          [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]],
          %{"rgba" => [[0.1], [0.2]]}
        )

      assert_raise ArgumentError, ~r/surface normal/, fn ->
        GraphObjectModel.add_ppf_to_graph(without_normals)
      end
    end

    defp assert_close(actual, expected) do
      Enum.zip(actual, expected)
      |> Enum.each(fn {got, want} -> assert_in_delta(got, want, 1.0e-12) end)
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
