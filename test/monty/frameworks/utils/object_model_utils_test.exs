defmodule Monty.Frameworks.Utils.ObjectModelUtilsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.Utils.ObjectModelUtils
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation
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

    # test_orthonormal_pose_vectors_orthgonalizes_curvature_direction
    test "a curvature direction off the surface is squared up to it, and the frame is a rotation" do
      pose = orthonormal_pose_vectors(normal(), [1.0, 0.0, 0.7])

      assert_is_rotation(pose, "pose vectors are not a rotation")
      assert_vectors_match(Enum.take(pose, 3), normal())
    end
  end

  # Monty's name for this case is 116 characters, so it is recorded one level out:
  # the map wants it verbatim, and inside a `describe` the indentation pushes it
  # past the line limit.
  # test_orthonormal_pose_vectors_falls_back_to_arbitrary_direction_if_curvature_direction_is_parallel_to_surface_normal
  test "a curvature direction parallel to the normal still leaves a rotation" do
    pose = orthonormal_pose_vectors(normal(), Enum.map(normal(), &(&1 * 2.0)))

    assert_is_rotation(pose, "a parallel curvature direction did not fall back")
  end

  describe "pose_vector_merge/4" do
    test "merging a pose with itself changes nothing" do
      pose = orthonormal_pose_vectors([0.0, 0.0, 1.0], [1.0, 0.0, 0.0])

      assert_vectors_match(pose_vector_merge(pose, pose, 3, 5), pose)
    end

    test "the result is still a rotation, not a component-wise average" do
      {:ok, first} = Rotation.from_axis_angle([0.0, 0.0, 1.0], 0.0)
      {:ok, second} = Rotation.from_axis_angle([0.0, 0.0, 1.0], 1.0)

      merged =
        pose_vector_merge(flat(Rotation.to_matrix(first)), flat(Rotation.to_matrix(second)), 1, 1)

      [normal, curvature_1, curvature_2] = Enum.chunk_every(merged, 3)
      assert_in_delta SpatialArithmetics.magnitude(normal), 1.0, @tolerance
      assert_in_delta SpatialArithmetics.dot(normal, curvature_1), 0.0, @tolerance
      assert_in_delta SpatialArithmetics.dot(curvature_1, curvature_2), 0.0, @tolerance
      # Halfway round a half-radian turn.
      assert_in_delta SpatialArithmetics.get_angle_between(normal, [1.0, 0.0, 0.0]), 0.5, 1.0e-6
    end

    # test_pose_vector_merge_of_opposite_curvature_directions_is_a_rotation
    test "merging a frame with its mirror twin is still a rotation" do
      merged = pose_vector_merge(opposite_frame(), frame(), 4, 4)

      assert_is_rotation(merged, "merged pose vectors are not a rotation")
    end

    # test_pose_vector_merge_keeps_the_surface_side_with_more_observations
    test "the side of the surface with more observations wins" do
      # Eight observations from the other side against four from this one.
      assert_vectors_match(Enum.take(pose_vector_merge(opposite_frame(), frame(), 8, 4), 3), [
        0.0,
        0.0,
        -1.0
      ])

      assert_vectors_match(
        Enum.take(pose_vector_merge(opposite_frame(), frame(), 4, 8), 3),
        normal()
      )
    end

    # test_pose_vector_merge_averages_normals_on_the_same_surface_side
    test "two normals on the same side of the surface are averaged, and the frame stays a rotation" do
      tilted = orthonormal_pose_vectors([0.0, 0.5, 1.0], [1.0, 0.0, 0.0])
      merged = pose_vector_merge(tilted, frame(), 4, 4)

      assert_is_rotation(merged, "merged pose vectors are not a rotation")
      assert SpatialArithmetics.dot(Enum.take(merged, 3), normal()) > 0.0
    end

    # test_pose_vector_merge_repeated_merges_from_the_opposite_side_stay_a_rotation
    test "merging from the opposite side again and again stays a rotation" do
      final =
        Enum.reduce(1..8, frame(), fn update, stored ->
          pose_vector_merge(opposite_frame(), stored, 4, 4 * update)
        end)

      assert_is_rotation(final, "a repeated merge from the opposite side is not a rotation")
    end
  end

  describe "pose_vector_mean/2" do
    test "the same pose seen twice averages to itself" do
      pose = orthonormal_pose_vectors([0.0, 0.0, 1.0], [1.0, 0.0, 0.0])

      assert {mean_pose, true} = pose_vector_mean([pose, pose], [true, true])
      assert_vectors_match(mean_pose, pose)
    end

    test "an observation with nothing in it is skipped" do
      pose = orthonormal_pose_vectors([0.0, 0.0, 1.0], [1.0, 0.0, 0.0])
      empty = List.duplicate(0.0, 9)

      assert {mean_pose, true} = pose_vector_mean([empty, pose], [true, true])
      assert_vectors_match(mean_pose, pose)
    end

    test "nothing observed means no pose at all" do
      assert pose_vector_mean([List.duplicate(0.0, 9)], [false]) == {nil, false}
    end

    test "a surface seen from both sides is averaged on the side most observations share" do
      up = orthonormal_pose_vectors([0.0, 0.0, 1.0], [1.0, 0.0, 0.0])
      down = orthonormal_pose_vectors([0.0, 0.0, -1.0], [-1.0, 0.0, 0.0])

      # The first observation is the odd one out; the three below it win.
      assert {mean_pose, true} =
               pose_vector_mean([up, down, down, down], [true, true, true, true])

      assert_in_delta SpatialArithmetics.dot(Enum.take(mean_pose, 3), [0.0, 0.0, -1.0]),
                      1.0,
                      @tolerance
    end

    test "with one observation against two, Monty keeps the one, and so do we" do
      up = orthonormal_pose_vectors([0.0, 0.0, 1.0], [1.0, 0.0, 0.0])
      down = orthonormal_pose_vectors([0.0, 0.0, -1.0], [-1.0, 0.0, 0.0])

      assert {mean_pose, true} = pose_vector_mean([down, up, up], [true, true, true])

      assert_in_delta SpatialArithmetics.dot(Enum.take(mean_pose, 3), [0.0, 0.0, -1.0]),
                      1.0,
                      @tolerance
    end

    test "curvature directions are only averaged when the poses are fully defined" do
      pose = orthonormal_pose_vectors([0.0, 0.0, 1.0], [1.0, 0.0, 0.0])

      assert {_mean_pose, false} = pose_vector_mean([pose, pose], [false, false])
    end

    # test_pose_vector_mean_of_spread_observations_is_a_rotation
    property "the mean of observations spread around a normal is a rotation" do
      # Monty draws fifty sets of six observations from a seeded numpy stream;
      # the property is what the seed is for, so any stream proves it or refutes
      # it, and the port's stream is the episode's own.
      check all(
              seed <- integer(),
              max_runs: 50
            ) do
        :rand.seed(:exsss, {seed, seed, seed})

        observations =
          for _ <- 1..6 do
            orthonormal_pose_vectors(
              normal() |> Enum.map(&(&1 + :rand.normal() * 0.3)),
              [:rand.normal(), :rand.normal(), :rand.normal()]
            )
          end

        {mean_pose, true} = pose_vector_mean(observations, List.duplicate(true, 6))

        assert_is_rotation(mean_pose, "the mean of spread observations is not a rotation")
      end
    end

    # test_repeated_merges_of_noisy_observations_stay_a_rotation
    property "merging four noisy observations at a time, fifty times, stays a rotation" do
      check all(
              seed <- integer(),
              max_runs: 50
            ) do
        :rand.seed(:exsss, {seed, seed, seed})

        {stored, _count} =
          Enum.reduce(1..50, {frame(), 4}, fn _round, {stored, count} ->
            observations =
              for _ <- 1..4 do
                sign = if :rand.uniform() < 0.5, do: 1.0, else: -1.0

                orthonormal_pose_vectors(
                  normal() |> Enum.map(&(&1 + :rand.normal() * 0.3)),
                  Enum.map([1.0, 0.0, 0.0], &(&1 * sign))
                )
              end

            {mean_pose, true} = pose_vector_mean(observations, List.duplicate(true, 4))
            {pose_vector_merge(mean_pose, stored, 4, count), count + 4}
          end)

        assert_is_rotation(stored, "a merged frame is not a rotation")
      end
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

  defp flat(rows), do: List.flatten(rows)

  defp assert_vectors_match(left, right) do
    Enum.zip(left, right)
    |> Enum.each(fn {l, r} -> assert_in_delta l, r, @tolerance end)
  end

  defp normal, do: [0.0, 0.0, 1.0]

  # Monty's `setUp` frame: the normal, the first curvature direction, and the
  # second one the cross product makes — a right-handed frame.
  defp frame, do: [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

  # The same frame seen from the other side of the surface.
  defp opposite_frame, do: [0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 0.0, -1.0, 0.0]

  # Monty's `assert_is_rotation`: the nine numbers are a rotation matrix — a
  # right-handed orthonormal basis — and not merely nine numbers that look like
  # one.
  defp assert_is_rotation(pose_vecs, message) do
    matrix = Enum.chunk_every(pose_vecs, 3)
    product = Monty.Geometry.mul(matrix, Monty.Geometry.transpose(matrix))

    for {row, expected} <- Enum.zip(product, Monty.Geometry.identity()) do
      assert_vectors_match(row, expected)
    end

    assert_in_delta determinant(matrix), 1.0, @tolerance, message
    assert {:ok, _rotation} = Rotation.from_matrix(matrix)
  end

  defp determinant([[a1, a2, a3], [b1, b2, b3], [c1, c2, c3]]) do
    a1 * (b2 * c3 - b3 * c2) - a2 * (b1 * c3 - b3 * c1) + a3 * (b1 * c2 - b2 * c1)
  end
end
