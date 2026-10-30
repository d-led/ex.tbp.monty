defmodule Monty.Frameworks.Utils.SpatialArithmeticsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Math

  import SpatialArithmetics, except: [scale: 2]

  @tolerance Math.default_tolerance()
  @half_turn :math.pi()
  @quarter_turn :math.pi() / 2

  defp vector_generator do
    gen all(
          x <- StreamData.float(min: -100.0, max: 100.0),
          y <- StreamData.float(min: -100.0, max: 100.0),
          z <- StreamData.float(min: -100.0, max: 100.0),
          magnitude(x, y, z) > 0.01
        ) do
      [x, y, z]
    end
  end

  defp magnitude(x, y, z), do: :math.sqrt(x * x + y * y + z * z)

  defp pose_vectors([normal, u, v] \\ [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]),
    do: SurfacePoseVectors.new(normal, u, v)

  describe "normalize/2" do
    property "keeps the direction and makes the length one" do
      check all(vector <- vector_generator()) do
        result = normalize(vector)
        length = magnitude_of(vector)

        assert_in_delta magnitude_of(result), 1.0, @tolerance

        Enum.zip(result, vector)
        |> Enum.each(fn {unit_component, raw_component} ->
          assert_in_delta unit_component * length, raw_component, @tolerance * length
        end)
      end
    end

    property "changes nothing when applied twice" do
      check all(vector <- vector_generator()) do
        once = normalize(vector)

        assert_vectors_match(normalize(once), once)
      end
    end

    test "the zero vector has no direction" do
      assert_raise ArgumentError, ~r/cannot normalize/, fn -> normalize([0.0, 0.0, 0.0]) end
    end

    test "a vector shorter than epsilon has no direction either" do
      assert_raise ArgumentError, ~r/cannot normalize/, fn ->
        normalize([1.0e-8, 0.0, 0.0], 1.0e-3)
      end
    end
  end

  describe "project_onto_tangent_plane/2" do
    property "collapses a vector that is parallel to the normal" do
      check all(vector <- vector_generator(), factor <- StreamData.float(min: -10.0, max: 10.0)) do
        parallel = SpatialArithmetics.scale(vector, factor)
        result = project_onto_tangent_plane(parallel, vector)
        length = magnitude_of(parallel)

        assert_vectors_match(result, [0.0, 0.0, 0.0], @tolerance * length)
      end
    end

    property "leaves a vector that is already in the plane" do
      check all(vector <- vector_generator(), normal <- vector_generator()) do
        in_plane = cross(normal, vector)

        assert_vectors_match(
          project_onto_tangent_plane(in_plane, normal),
          in_plane,
          @tolerance * magnitude_of(in_plane)
        )
      end
    end

    property "the result is perpendicular to the normal" do
      check all(vector <- vector_generator(), normal <- vector_generator()) do
        result = project_onto_tangent_plane(vector, normal)

        assert_in_delta dot(result, normalize(normal)), 0.0, @tolerance * magnitude_of(vector)
      end
    end

    property "projecting again changes nothing" do
      check all(vector <- vector_generator(), normal <- vector_generator()) do
        once = project_onto_tangent_plane(vector, normal)
        twice = project_onto_tangent_plane(once, normal)

        assert_vectors_match(twice, once, @tolerance * magnitude_of(vector))
      end
    end
  end

  describe "parallel?/3" do
    test "same direction and opposite direction are both parallel" do
      assert parallel?([1.0, 0.0, 0.0], [1.0, 0.0, 0.0])
      assert parallel?([1.0, 0.0, 0.0], [-1.0, 0.0, 0.0])
    end

    test "perpendicular is not parallel" do
      refute parallel?([1.0, 0.0, 0.0], [0.0, 1.0, 0.0])
    end
  end

  describe "get_angle/2" do
    test "measures the turn between unit vectors" do
      assert_in_delta get_angle([1.0, 0.0, 0.0], [0.0, 1.0, 0.0]), @quarter_turn, @tolerance
      assert_in_delta get_angle([1.0, 0.0, 0.0], [-1.0, 0.0, 0.0]), @half_turn, @tolerance
      assert_in_delta get_angle([1.0, 0.0, 0.0], [1.0, 0.0, 0.0]), 0.0, @tolerance
    end
  end

  describe "get_angle_between/2" do
    test "needs no normalisation" do
      assert_in_delta get_angle_between([2.0, 0.0, 0.0], [1.0, 1.0, 0.0]),
                      :math.pi() / 4,
                      @tolerance

      assert_in_delta get_angle_between([2.0, 0.0, 0.0], [3.0, 0.0, 0.0]), 0.0, @tolerance
      assert_in_delta get_angle_between([2.0, 0.0, 0.0], [-3.0, 0.0, 0.0]), @half_turn, @tolerance

      assert_in_delta get_angle_between([2.0, 0.0, 0.0], [0.0, -3.0, 0.0]),
                      @quarter_turn,
                      @tolerance
    end

    property "is always between 0 and pi" do
      check all(v1 <- vector_generator(), v2 <- vector_generator()) do
        angle = get_angle_between(v1, v2)

        assert angle >= 0.0
        assert angle <= @half_turn
      end
    end

    test "a zero vector contains no direction, and says so with zero" do
      assert get_angle_between([0.0, 0.0, 0.0], [1.0, 2.0, 3.0]) == 0.0
      assert get_angle_between([1.0, 2.0, 3.0], [0.0, 0.0, 0.0]) == 0.0
    end
  end

  describe "get_angle_beefed_up/2" do
    test "an undefined direction is similar to nothing" do
      assert get_angle_beefed_up(nil, [1.0, 0.0, 0.0]) == :infinity
      assert get_angle_beefed_up([1.0, 0.0, 0.0], nil) == :infinity
      assert get_angle_beefed_up([0.0, 0.0, 0.0], [1.0, 0.0, 0.0]) == :infinity
    end

    test "and :infinity compares as further away than any angle" do
      refute get_angle_beefed_up([0.0, 0.0, 0.0], [1.0, 0.0, 0.0]) < 0.1
    end

    test "defined directions are measured, and need no normalisation" do
      assert_in_delta get_angle_beefed_up([2.0, 0.0, 0.0], [0.0, 5.0, 0.0]),
                      @quarter_turn,
                      @tolerance
    end
  end

  describe "get_angles_for_all_hypotheses/2" do
    test "measures every neighbour of every hypothesis against its query" do
      hypothesis_features = [
        [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
        [[0.0, 0.0, 1.0]]
      ]

      query_features = [[1.0, 0.0, 0.0], [0.0, 0.0, -1.0]]

      assert [[first_matches, first_neighbour], [second_matches]] =
               get_angles_for_all_hypotheses(hypothesis_features, query_features)

      assert_in_delta first_matches, 0.0, @tolerance
      assert_in_delta first_neighbour, @quarter_turn, @tolerance
      assert_in_delta second_matches, @half_turn, @tolerance
    end
  end

  describe "check_orthonormal/1" do
    test "accepts the identity" do
      assert check_orthonormal([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]])
    end

    test "accepts a rotation matrix" do
      {:ok, rotation} = Rotation.from_axis_angle([1.0, 1.0, 0.0], 0.7)
      assert check_orthonormal(Rotation.to_matrix(rotation))
    end

    test "rejects rows that are not unit length" do
      refute check_orthonormal([[2.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]])
    end

    test "rejects rows that are not perpendicular" do
      refute check_orthonormal([[1.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])
    end
  end

  describe "align_orthonormal_vectors/2" do
    test "finds the rotation between a frame and the same frame turned" do
      frame = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
      {:ok, turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], 0.4)
      turned = Rotation.apply(turn, frame)

      {rotation, error} = align_orthonormal_vectors(frame, turned)

      assert_in_delta error, 0.0, 1.0e-5
      assert_in_delta Rotation.magnitude(rotation), 0.4, 1.0e-5
    end

    test "a mirrored frame leaves a large error behind" do
      frame = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
      mirrored = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, -1.0]]

      {_rotation, error} = align_orthonormal_vectors(frame, mirrored)

      assert error > 0.1
    end

    test "the matrix form needs no rotation object" do
      frame = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

      assert align_orthonormal_vectors_as_matrix(frame, frame) == frame
    end
  end

  describe "align_multiple_orthonormal_vectors_as_matrices/2" do
    test "gives one matrix per frame, each turning its frame onto the target" do
      frame = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
      {:ok, turn} = Rotation.from_axis_angle([1.0, 0.0, 0.0], 0.3)
      turned = Rotation.apply(turn, frame)

      assert [first, second] =
               align_multiple_orthonormal_vectors_as_matrices([frame, turned], frame)

      # The pose turns the target onto each frame: the identity for a frame
      # already in place, and the turn for the turned one.
      assert first == frame
      assert Enum.map(frame, &Geometry.apply(second, &1)) == turned
    end

    # A stored node frame is a surface normal and two curvature directions as
    # measured: unit to a few parts in a thousand, perpendicular to a few
    # hundredths. Monty keeps the product it aligns with, so the pose turns each
    # sensed direction onto the stored one exactly. Rounding the pose into a
    # rotation loses that, and the stored directions it then matches are off by
    # hundredths of a radian — the difference that shows up as evidence.
    test "a stored frame that is only nearly orthonormal still comes back exactly" do
      sensed = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

      stored = [
        [0.195_484, 0.098_572, 0.975_740],
        [-0.334_766, -0.928_469, 0.160_865],
        [0.921_854, -0.357_946, -0.148_527]
      ]

      [pose] = align_multiple_orthonormal_vectors_as_matrices([stored], sensed)

      assert Enum.map(sensed, &Geometry.apply(pose, &1)) == stored
    end
  end

  describe "get_right_hand_angle/3" do
    test "a turn from x towards y is positive seen from +z" do
      assert_in_delta get_right_hand_angle([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]),
                      @quarter_turn,
                      @tolerance
    end

    test "and negative seen from the other side" do
      assert_in_delta get_right_hand_angle([1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, -1.0]),
                      -@quarter_turn,
                      @tolerance
    end
  end

  describe "non_singular_mat/1" do
    test "the identity can be inverted" do
      assert non_singular_mat([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]])
    end

    test "a rotation can be inverted" do
      assert non_singular_mat([[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]])
    end

    test "a matrix with a repeated row cannot" do
      refute non_singular_mat([[1.0, 2.0, 3.0], [1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
    end
  end

  describe "inverse/1" do
    test "undoes a multiplication" do
      matrix = [[2.0, 0.0, 0.0], [0.0, 4.0, 0.0], [0.0, 0.0, 0.5]]

      assert inverse(matrix) == [[0.5, 0.0, 0.0], [0.0, 0.25, 0.0], [0.0, 0.0, 2.0]]
    end

    test "a singular matrix has no inverse" do
      assert inverse([[1.0, 1.0, 1.0], [1.0, 1.0, 1.0], [1.0, 1.0, 1.0]]) == :singular
    end
  end

  describe "get_more_directions_in_plane/2" do
    test "spreads unit directions around the normal, starting in the first curvature direction" do
      frame = pose_vectors().value

      directions = get_more_directions_in_plane(frame, 4)

      assert length(directions) == 4

      Enum.each(directions, fn [normal, first, second] ->
        assert normal == [0.0, 0.0, 1.0]
        assert_in_delta magnitude_of(first), 1.0, @tolerance
        assert_vectors_match(second, cross(normal, first))
      end)

      assert [_, first_direction, _] = hd(directions)
      assert_vectors_match(first_direction, [1.0, 0.0, 0.0])
    end
  end

  describe "get_unique_rotations/3" do
    test "keeps one rotation per distinct pose and labels it in Euler degrees" do
      {:ok, quarter_turn} = Rotation.from_euler_degrees([0.0, 0.0, 90.0])
      {:ok, third_turn} = Rotation.from_euler_degrees([0.0, 0.0, 120.0])

      {euler_poses, rotations} =
        get_unique_rotations([[quarter_turn, quarter_turn], [third_turn]], 0.1)

      assert length(rotations) == 2
      assert [euler_pose | _] = euler_poses
      assert_in_delta Enum.at(euler_pose, 2), 270.0, 0.001
    end

    test "the poses themselves rather than their reverses can be asked for" do
      {:ok, quarter_turn} = Rotation.from_euler_degrees([0.0, 0.0, 90.0])

      {[euler_pose], [rotation]} = get_unique_rotations([[quarter_turn]], 0.1, reverse?: false)

      assert_in_delta Enum.at(euler_pose, 2), 90.0, 0.001
      assert_in_delta Rotation.magnitude(rotation), @quarter_turn, @tolerance
    end
  end

  describe "pose_is_new/3" do
    test "a rotation similar to one already seen is not new" do
      {:ok, first} = Rotation.from_euler_degrees([0.0, 0.0, 90.0])
      {:ok, nearly_the_same} = Rotation.from_euler_degrees([0.0, 0.0, 91.0])
      {:ok, different} = Rotation.from_euler_degrees([0.0, 0.0, 180.0])

      refute pose_is_new([first], nearly_the_same, 0.1)
      assert pose_is_new([first], different, 0.1)
    end
  end

  describe "batch_rotate_pose_vectors/2" do
    test "gives one rotated pose vector set per rotation" do
      {:ok, quarter_turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], @quarter_turn)
      identity = Rotation.identity()

      [turned, unchanged] =
        batch_rotate_pose_vectors(pose_vectors(), [
          Rotation.to_matrix(quarter_turn),
          Rotation.to_matrix(identity)
        ])

      assert [normal, _u, _v] = turned
      assert_vectors_match(normal, [0.0, 0.0, 1.0])
      assert_vectors_match(hd(unchanged), [0.0, 0.0, 1.0])
      assert_vectors_match(Enum.at(turned, 1), [0.0, 1.0, 0.0])
    end
  end

  describe "rotate_pose_vectors/2" do
    test "turns the whole pose vector set" do
      {:ok, quarter_turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], @quarter_turn)

      rotated = rotate_pose_vectors(pose_vectors(), quarter_turn)

      [normal, u, v] = rotated.value
      assert_vectors_match(normal, [0.0, 0.0, 1.0])
      assert_vectors_match(u, [0.0, 1.0, 0.0])
      assert_vectors_match(v, [-1.0, 0.0, 0.0])
    end

    test "a gaze direction is not a surface frame and cannot be rotated" do
      gaze = %Monty.Geometry.GazeDirection{value: [1.0, 0.0, 0.0]}

      assert_raise ArgumentError, ~r/GazeDirection/, fn ->
        rotate_pose_vectors(gaze, Rotation.identity())
      end
    end
  end

  describe "rotate_multiple_pose_vectors/2" do
    test "rotates each row of nine numbers, keeping the rows and their length" do
      {:ok, quarter_turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], @quarter_turn)

      rows = [[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]]

      assert [[x1, y1, z1, x2, y2, z2, x3, y3, z3]] =
               rotate_multiple_pose_vectors(rows, quarter_turn)

      assert_vectors_match([x1, y1, z1], [0.0, 1.0, 0.0])
      assert_vectors_match([x2, y2, z2], [-1.0, 0.0, 0.0])
      assert_vectors_match([x3, y3, z3], [0.0, 0.0, 1.0])
    end
  end

  describe "apply_rf_transform_to_points/6" do
    test "matching reference points and no rotation leave the points alone" do
      locations = [[1.0, 2.0, 3.0]]
      features = %{"pose_vectors" => [[0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]]}

      {transformed, transformed_features} =
        apply_rf_transform_to_points(
          locations,
          features,
          [0.5, 0.5, 0.5],
          [0.5, 0.5, 0.5],
          Rotation.identity()
        )

      assert_vectors_match(hd(transformed), [1.0, 2.0, 3.0])
      assert transformed_features["pose_vectors"] == features["pose_vectors"]
    end

    test "a quarter turn about z takes body directions into the model's frame" do
      {:ok, quarter_turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], @quarter_turn)

      {transformed, _features} =
        apply_rf_transform_to_points(
          [[1.0, 0.0, 0.0]],
          %{"pose_vectors" => []},
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          quarter_turn
        )

      assert_vectors_match(hd(transformed), [0.0, -1.0, 0.0])
    end
  end

  defp magnitude_of([x, y, z]), do: magnitude(x, y, z)

  defp assert_vectors_match(left, right, tolerance \\ @tolerance) do
    Enum.zip(left, right)
    |> Enum.each(fn {l, r} -> assert_in_delta l, r, tolerance end)
  end
end
