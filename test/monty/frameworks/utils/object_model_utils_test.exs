defmodule Monty.Frameworks.Utils.ObjectModelUtilsTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Utils.ObjectModelUtils
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Math

  @tolerance Math.default_tolerance()

  import ObjectModelUtils

  @thresholds %{"distance" => 0.01, "pose_vectors" => [Math.degrees(30), 6.0, 6.0]}

  defp features(rows), do: Map.new(rows, fn {name, values} -> {name, values} end)

  describe "already_in_list?/6" do
    test "a point in the same place, sensing the same thing, is redundant" do
      existing = [[0.0, 0.0, 0.0]]

      assert already_in_list?(
               existing,
               [0.001, 0.0, 0.0],
               %{"rgba" => [[0.5]]},
               [0],
               1,
               @thresholds
             )
    end

    test "a point far enough away is new" do
      existing = [[0.0, 0.0, 0.0]]

      refute already_in_list?(
               existing,
               [0.5, 0.0, 0.0],
               %{"rgba" => [[0.5]]},
               [0],
               1,
               @thresholds
             )
    end

    test "a nearby point on the other side of a thin object is new, because the surface normal differs" do
      stored = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
      observed = [0.0, 0.0, -1.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

      refute already_in_list?(
               [[0.0, 0.0, 0.0]],
               [0.001, 0.0, 0.0],
               %{"pose_vectors" => [stored, observed]},
               [0],
               1,
               @thresholds
             )
    end

    test "a different colour is new even in the same place" do
      # Hue 0.9 against 0.1 is 0.2 apart the short way round.
      refute already_in_list?(
               [[0.0, 0.0, 0.0]],
               [0.0, 0.0, 0.0],
               %{"hsv" => [[0.9, 0.5, 0.5], [0.1, 0.5, 0.5]]},
               [0],
               1,
               Map.put(@thresholds, "hsv", [0.1, 1, 1])
             )
    end

    test "a feature with any one value outside its threshold is new" do
      refute already_in_list?(
               [[0.0, 0.0, 0.0]],
               [0.0, 0.0, 0.0],
               %{"principal_curvatures" => [[0.1, 0.2], [0.1, 0.5]]},
               [0],
               1,
               Map.put(@thresholds, "principal_curvatures", [0.05, 0.05])
             )
    end

    test "the feature index comes from the accepted points, not the position of the close one" do
      # Point 0 was rejected earlier, so the only accepted point is feature index 3.
      feature_values = features([{"rgba", [[9.9], [9.9], [9.9], [0.5], [0.6]]}])

      assert already_in_list?(
               [[0.0, 0.0, 0.0]],
               [0.0, 0.0, 0.0],
               feature_values,
               [3],
               4,
               @thresholds
             )
    end
  end

  describe "remove_close_points/4" do
    test "keeps one point per spot and reports the indices it kept" do
      point_cloud = [[0.0, 0.0, 0.0], [0.0001, 0.0, 0.0], [0.5, 0.0, 0.0]]

      assert {kept, clean_ids} = remove_close_points(point_cloud, %{}, nil, 0)

      assert kept == [[0.0, 0.0, 0.0], [0.5, 0.0, 0.0]]
      assert clean_ids == [0, 2]
    end

    test "an existing graph is not re-checked against itself" do
      point_cloud = [[0.0, 0.0, 0.0], [0.0001, 0.0, 0.0], [0.5, 0.0, 0.0]]

      assert {kept, clean_ids} = remove_close_points(point_cloud, %{}, nil, 2)

      assert kept == point_cloud
      assert clean_ids == [0, 1, 2]
    end

    test "a new observation that differs in colour is kept even at the same spot" do
      point_cloud = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
      features = %{"hsv" => [[0.1, 0.5, 0.5], [0.9, 0.5, 0.5]]}

      assert {kept, [0, 1]} =
               remove_close_points(point_cloud, features, %{"hsv" => [0.1, 1, 1]}, 0)

      assert length(kept) == 2
    end
  end

  describe "orthonormal_pose_vectors/2" do
    test "gives a right-handed orthonormal pose" do
      [n1, n2, n3, c1, c2, c3, d1, d2, d3] =
        orthonormal_pose_vectors([0.0, 0.0, 2.0], [3.0, 0.0, 0.0])

      normal = [n1, n2, n3]
      curvature_1 = [c1, c2, c3]
      curvature_2 = [d1, d2, d3]

      assert_vectors_match(normal, [0.0, 0.0, 1.0])
      assert_vectors_match(curvature_1, [1.0, 0.0, 0.0])
      assert_vectors_match(curvature_2, [0.0, 1.0, 0.0])
    end

    test "a curvature direction parallel to the normal has no direction, so an arbitrary one is used" do
      pose = orthonormal_pose_vectors([0.0, 0.0, 1.0], [0.0, 0.0, 5.0])

      assert length(pose) == 9
      assert_in_delta SpatialArithmetics.magnitude(Enum.take(pose, 3)), 1.0, @tolerance
      assert_in_delta SpatialArithmetics.magnitude(Enum.slice(pose, 3, 3)), 1.0, @tolerance
      assert_in_delta SpatialArithmetics.magnitude(Enum.slice(pose, 6, 3)), 1.0, @tolerance
    end
  end

  describe "get_most_common_bool/1" do
    test "the majority wins" do
      assert get_most_common_bool([true, false, true])
      refute get_most_common_bool([true, false, false])
    end

    test "a tie goes to true" do
      assert get_most_common_bool([true, false])
    end

    test "a list of observations flattens, since one boolean each is still one boolean each" do
      assert get_most_common_bool([[true], [true], [false]])
    end

    test "a feature nested deeper than one boolean per observation is not guessed at" do
      assert_raise ArgumentError, ~r/more than one boolean/, fn ->
        get_most_common_bool([[[true, false]], [[false, true]]])
      end
    end
  end

  describe "get_most_common_value/1" do
    test "the mode wins" do
      assert get_most_common_value([3, 1, 3, 2, 3]) == 3
    end

    test "a tie goes to the smaller value" do
      assert get_most_common_value([2, 1]) == 1
    end
  end

  describe "circular_mean/1" do
    test "hue either side of zero averages to zero, not to the opposite colour" do
      assert_in_delta circular_mean([0.99, 0.01]), 0.0, 1.0e-9
    end

    test "hues that do not wrap average as ordinary numbers" do
      assert_in_delta circular_mean([0.2, 0.4]), 0.3, 1.0e-9
    end
  end

  describe "build_point_cloud_graph/3" do
    test "holds the observations, their locations and the feature layout" do
      assert build_point_cloud_graph([[0.0, 0.0, 0.0]], %{"x" => [[1.0]]}, %{"rgba" => [0, 1]}) ==
               %{
                 x: %{"x" => [[1.0]]},
                 pos: [[0.0, 0.0, 0.0]],
                 feature_mapping: %{"rgba" => [0, 1]}
               }
    end
  end

  defp assert_vectors_match(left, right) do
    Enum.zip(left, right)
    |> Enum.each(fn {l, r} -> assert_in_delta l, r, @tolerance end)
  end
end
