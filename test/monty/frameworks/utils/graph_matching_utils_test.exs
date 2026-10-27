defmodule Monty.Frameworks.Utils.GraphMatchingUtilsTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Math

  import GraphMatchingUtils

  @quarter_turn :math.pi() / 2
  @tolerance Math.default_tolerance()

  describe "correct_k_n/2" do
    test "asks the graph for one more neighbour than the edges wanted, the node itself counting" do
      assert correct_k_n(3, 100) == {:ok, 4}
    end

    test "falls back to everything except the node when the graph is small" do
      assert correct_k_n(10, 5) == {:ok, 4}
    end

    test "says so when there is nothing to build a graph from" do
      assert correct_k_n(10, 2) == {:error, :not_enough_observations}
    end
  end

  describe "unique_paths/2" do
    test "keeps the first of two paths that visit the same points" do
      path = [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]]
      same_visit = [[0.0001, 0.0, 0.0], [1.0001, 0.0, 0.0]]
      elsewhere = [[0.0, 0.0, 0.0], [0.0, 5.0, 0.0]]

      assert unique_paths([path, same_visit, elsewhere]) == [path, elsewhere]
    end
  end

  describe "in_ranges?/2" do
    test "accepts values inside their own ranges" do
      assert in_ranges?([1.0, 5.0], [{0.0, 2.0}, {4.0, 6.0}])
    end

    test "rejects a value outside its range" do
      refute in_ranges?([3.0, 5.0], [{0.0, 2.0}, {4.0, 6.0}])
    end

    test "a range that wraps around zero is circular, not empty" do
      assert in_ranges?([355.0], [{350.0, 10.0}])
      assert in_ranges?([5.0], [{350.0, 10.0}])
      refute in_ranges?([180.0], [{350.0, 10.0}])
    end
  end

  describe "uniform_initial_possible_poses/1" do
    test "nine samples give 256 poses, because a pose and its dual are the same" do
      poses = uniform_initial_possible_poses(9)

      assert length(poses) == 256
      assert Rotation.to_euler_degrees(hd(poses)) == [0.0, 0.0, 0.0]
    end

    test "no pose in the list is the dual of another" do
      euler_poses =
        uniform_initial_possible_poses(9) |> Enum.map(&Rotation.to_euler_degrees/1)

      duals =
        Enum.map(euler_poses, fn [first, second, third] ->
          [wrap(first + 180), wrap(-second + 180), wrap(third + 180)]
        end)

      assert MapSet.disjoint?(MapSet.new(euler_poses), MapSet.new(duals))
    end
  end

  describe "initial_possible_poses/1" do
    test "uniform samples the rotation space" do
      assert {:ok, poses} = initial_possible_poses(:uniform)
      assert length(poses) == 256
    end

    test "informed starts from the first observation instead" do
      assert initial_possible_poses(:informed) == {:ok, :first_observation}
    end

    test "a list of Euler poses is tried inverted, since it describes how the object sits" do
      assert {:ok, [rotation]} = initial_possible_poses({:euler_degrees, [[0.0, 0.0, 90.0]]})

      assert_in_delta Rotation.magnitude(rotation), @quarter_turn, @tolerance
      assert [x, y, _z] = Rotation.apply(rotation, [1.0, 0.0, 0.0])
      assert_in_delta x, 0.0, @tolerance
      assert_in_delta y, -1.0, @tolerance
    end
  end

  describe "add_pose_features_to_tolerances/2" do
    test "every channel can tolerate pose vectors, in radians" do
      tolerances = %{"rgba" => %{"hsv" => [0.1]}}

      assert %{"rgba" => %{"hsv" => [0.1], "pose_vectors" => pose_tolerances}} =
               add_pose_features_to_tolerances(tolerances)

      assert_in_delta Enum.at(pose_tolerances, 0), Math.degrees(20), @tolerance
      assert length(pose_tolerances) == 3
    end

    test "a channel's own pose tolerance is kept, and converted" do
      tolerances = %{"pose_vectors" => %{"pose_vectors" => [10.0, 20.0, 30.0]}}

      assert %{"pose_vectors" => %{"pose_vectors" => [first, second, third]}} =
               add_pose_features_to_tolerances(tolerances)

      assert_in_delta first, Math.degrees(10), @tolerance
      assert_in_delta second, Math.degrees(20), @tolerance
      assert_in_delta third, Math.degrees(30), @tolerance
    end
  end

  describe "relevant_curvature/1" do
    test "the two principal curvatures collapse to the larger magnitude" do
      assert relevant_curvature(%{"principal_curvatures_log" => [-0.4, 1.5]}) == 1.5
      assert relevant_curvature(%{"principal_curvatures" => [2.0, -3.0]}) == 3.0
    end

    test "a single curvature value is the curvature" do
      assert relevant_curvature(%{"mean_curvature" => 0.7}) == 0.7
      assert relevant_curvature(%{"gaussian_curvature_sc" => 0.2}) == 0.2
    end

    test "an unmeasured curvature falls back to a wide search sphere" do
      assert relevant_curvature(%{"rgba" => [1.0]}) == 10
    end
  end

  describe "scaled_evidences/2" do
    test "the widest and narrowest evidence over all objects set the scale" do
      scaled = scaled_evidences(%{"a" => [1.0, 3.0], "b" => [5.0]})

      assert scaled["a"] |> Enum.map(&Float.round(&1, 6)) == [-1.0, 0.0]
      assert scaled["b"] |> Enum.map(&Float.round(&1, 6)) == [1.0]
    end

    test "evidence that never got strong is only clipped, never stretched" do
      assert scaled_evidences(%{"a" => [-2.0, 0.8]})["a"] == [-1.0, 0.8]
    end

    test "each object can be scaled against itself instead" do
      scaled = scaled_evidences(%{"a" => [1.0, 2.0], "b" => [-4.0, -3.0]}, per_object: true)

      assert scaled["a"] == [-1.0, 1.0]
      assert scaled["b"] == [-1.0, 1.0]
    end

    test "equal evidence has no scale, and votes neither way" do
      assert scaled_evidences(%{"a" => [2.0, 2.0]}, per_object: true)["a"] == [0.0, 0.0]
    end

    test "an object with no evidence keeps having none" do
      assert scaled_evidences(%{"a" => []})["a"] == []
    end
  end

  describe "custom_distances/4" do
    test "a candidate in the tangent plane is as far as it is" do
      distances = custom_distances([[[1.0, 0.0, 0.0]]], [[0.0, 0.0, 0.0]], [[0.0, 0.0, 1.0]], 0.5)

      assert [[distance]] = distances
      assert_in_delta distance, 1.0, @tolerance
    end

    test "a candidate off the plane pays for the height it sits at" do
      distances = custom_distances([[[0.0, 0.0, 1.0]]], [[0.0, 0.0, 0.0]], [[0.0, 0.0, 1.0]], 0.5)

      assert [[distance]] = distances
      assert_in_delta distance, 1.0 + 1.0 / 1.0, @tolerance
    end

    test "a curved surface tolerates height more than a flat one" do
      [[flat]] = custom_distances([[[0.0, 0.0, 1.0]]], [[0.0, 0.0, 0.0]], [[0.0, 0.0, 1.0]], 0.0)

      [[curved]] =
        custom_distances([[[0.0, 0.0, 1.0]]], [[0.0, 0.0, 0.0]], [[0.0, 0.0, 1.0]], 9.5)

      assert curved < flat
    end
  end

  describe "exponential_kernel/2" do
    test "weighs the most recent step fully and older steps less" do
      kernel = exponential_kernel(3, 3)

      assert_in_delta Enum.at(kernel, 2), 1.0, @tolerance
      assert_in_delta Enum.at(kernel, 1), :math.exp(-3), @tolerance
      assert_in_delta Enum.at(kernel, 0), :math.exp(-6), @tolerance
    end
  end

  describe "detect_new_object_exponential/2" do
    test "a sharp recent drop off the object is detected" do
      assert detect_new_object_exponential([0.0, -0.5, -2.0])
    end

    test "a small drop is not" do
      refute detect_new_object_exponential([0.0, -0.1])
    end
  end

  describe "detect_new_object_k_steps/2" do
    test "sums the evidence changes of the last k steps" do
      evidence = [0.0, -0.2, -0.4, -0.6]

      refute detect_new_object_k_steps(evidence, k: 2)
      assert detect_new_object_k_steps(evidence, k: 2, detection_threshold: -0.3)
    end

    test "a rise in evidence restarts the count when asked" do
      evidence = [0.0, -1.0, -2.0, 1.0, 0.5]

      assert detect_new_object_k_steps(evidence, k: 3, detection_threshold: -1.2)

      refute detect_new_object_k_steps(evidence,
               k: 3,
               detection_threshold: -1.2,
               reset_at_positive_jump: true
             )
    end
  end

  describe "delta_evidence_values/1" do
    test "only the drops are kept, and the last rise is reported" do
      changes = [0.0, -1.0, 2.0, 1.5]
      {drops, last_rise} = delta_evidence_values(changes)

      assert Enum.map(drops, &Float.round(&1, 6)) == [-1.0, 0.0, -0.5]
      assert last_rise == 1
    end

    test "with no rise there is nothing to restart from" do
      {drops, last_rise} = delta_evidence_values([1.0, 0.9])

      assert Enum.map(drops, &Float.round(&1, 6)) == [-0.1]
      assert last_rise == nil
    end
  end

  describe "find_step_on_new_object/3" do
    test "the first step of a run of off-target steps" do
      targets = ["primary", "primary", "other", "other", "other", "primary"]

      assert find_step_on_new_object(targets, "primary", 3) == 4
    end

    test "a single step elsewhere is not a run" do
      targets = ["primary", "other", "primary", "primary"]

      assert find_step_on_new_object(targets, "primary", 2) == nil
    end

    test "never off the primary target means no step to report" do
      assert find_step_on_new_object(["primary", "primary"], "primary", 1) == nil
    end
  end

  describe "possible_sensed_directions/2" do
    test "a well-defined pose still cannot tell an object from its upside-down twin" do
      pose_vectors = SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])

      assert [as_sensed, flipped] = possible_sensed_directions(pose_vectors, 2)
      assert as_sensed == pose_vectors.value

      assert [normal, principal_1, principal_2] = flipped
      assert normal == [0.0, 0.0, 1.0]
      assert principal_1 == [-1.0, 0.0, 0.0]
      assert principal_2 == [0.0, -1.0, 0.0]
    end

    test "an undefined pose is sampled around the normal instead" do
      pose_vectors = SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])

      assert [first, second, third, fourth] = possible_sensed_directions(pose_vectors, 4)

      directions =
        [first, second, third, fourth]
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.map(fn direction -> Enum.map(direction, &Float.round(&1, 6)) end)

      assert directions == [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, -1.0, 0.0]]
    end
  end

  defp wrap(degrees) do
    wrapped = :math.fmod(degrees + 360.0, 360.0)
    if wrapped >= 360.0, do: wrapped - 360.0, else: wrapped
  end
end
