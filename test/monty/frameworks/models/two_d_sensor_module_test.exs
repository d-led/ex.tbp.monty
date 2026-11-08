defmodule Monty.Frameworks.Models.TwoDSensorModuleTest do
  @moduledoc """
  The 2-D sensor module, case for case from Monty's
  `tests/unit/frameworks/models/two_d_sensor_module_test.py`.

  Monty mocks `_observation_processor.process` to hand the module a percept it
  built by hand. This port has no method-object to patch, so a case builds a
  small patch of points instead and lets the real processor make the percept —
  the percept is then what a sensor would really have made of a flat surface,
  which is closer to the truth than a hand-built one and says the same thing.

  The edge detector *is* injected, as `{module, detector}` — the shape the
  module's noise and percept filter already take — so a case can say what the
  detector found without a real edge in a real patch.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Frameworks.Models.MotorSystemState.SensorState
  alias Monty.Frameworks.Models.TwoDSensorModule
  alias Monty.Frameworks.Utils.EdgeDetection.EdgeDetector
  alias Monty.Frameworks.Utils.EdgeDetection.EdgeFeatures
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Math
  alias Monty.Test.CannedEdgeDetector

  @tolerance Math.default_tolerance()
  @patch_size 9
  @flat_normal [0.0, 0.0, 1.0]
  @features ["on_object", "pose_vectors", "principal_curvatures", "edge_strength", "coherence"]

  # One patch of a flat surface, centred on `location`, whose plane is spanned by
  # the two basis vectors given.
  defp patch(location, options \\ []) do
    half = div(@patch_size, 2)
    spread = Keyword.get(options, :spread, 0.004)
    on_object = Keyword.get(options, :on_object, true)
    [basis_u, basis_v] = Keyword.get(options, :basis, [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
    semantic = if on_object, do: 1.0, else: 0.0

    points =
      for row <- 0..(@patch_size - 1)//1, column <- 0..(@patch_size - 1)//1 do
        u = (column - half) * spread
        v = (row - half) * spread

        location
        |> Enum.zip(combine(basis_u, u, basis_v, v))
        |> Enum.map(fn {a, b} -> a + b end)
        |> then(fn [x, y, z] -> [x, y, z, semantic] end)
      end

    %{
      "rgba" => List.duplicate(List.duplicate([128, 128, 128, 255], @patch_size), @patch_size),
      "depth" => List.duplicate(List.duplicate(0.1, @patch_size), @patch_size),
      "semantic_3d" => points,
      "cam_to_world" => identity()
    }
  end

  defp combine(first, first_scale, second, second_scale) do
    first
    |> Enum.zip(second)
    |> Enum.map(fn {a, b} -> a * first_scale + b * second_scale end)
  end

  defp identity do
    [
      [1.0, 0.0, 0.0, 0.0],
      [0.0, 1.0, 0.0, 0.0],
      [0.0, 0.0, 1.0, 0.0],
      [0.0, 0.0, 0.0, 1.0]
    ]
  end

  defp no_edge, do: EdgeFeatures.no_edge()

  defp canned(features), do: {CannedEdgeDetector, features}

  defp sm(options \\ []) do
    TwoDSensorModule.new(
      "test",
      Keyword.merge(
        [features: @features, edge_detector: canned(no_edge())],
        options
      )
    )
  end

  defp step(sm, observation, options \\ []) do
    TwoDSensorModule.step(
      observation,
      Keyword.get(options, :motor_only, false),
      Context.new(0),
      sm
    )
  end

  describe "the first observation of an episode" do
    # test_first_observation_initializes_2d_location_from_world_xy
    test "makes the sensor's world x and y its 2-D origin" do
      {percept, sm} = step(sm(), patch([1.0, 2.0, 3.0]))

      assert percept.location == [1.0, 2.0, 0.0]
      assert sm.previous_2d_location == [1.0, 2.0]
      assert sm.previous_3d_location == [1.0, 2.0, 3.0]
    end

    # test_step_handles_off_object_percept_without_pose_vectors
    test "leaves a percept off the object alone, with no displacement and no frame" do
      {percept, sm} = step(sm(), patch([1.0, 2.0, 3.0], on_object: false))

      assert percept.pass_message
      refute percept.process_features_in_lm
      refute Map.has_key?(percept.morphological_features, "pose_vectors")
      assert percept.displacement == [0.0, 0.0, 0.0]
      assert sm.tangent_frame == nil
    end

    # test_like_how_monty_uses_two_d_sm
    test "answers a percept the way the model expects it, after update_state" do
      two_d = sm()

      agent = %AgentState{
        position: [0.0, 0.0, 0.0],
        rotation: Rotation.identity(),
        sensors: %{
          "test" => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
        }
      }

      two_d = TwoDSensorModule.update_state(agent, two_d)

      {percept, two_d} = step(two_d, patch([1.0, 2.0, 3.0]))

      assert two_d.pose != nil
      assert percept.sender_id == "test"
      assert percept.sender_type == :sm
      assert percept.confidence == 1.0
      assert is_boolean(percept.pass_message)
      assert length(percept.location) == 3
      assert %SurfacePoseVectors{} = percept.morphological_features["pose_vectors"]
      assert is_boolean(percept.morphological_features["pose_fully_defined"])
    end
  end

  describe "the edge detector" do
    # test_default_edge_detector_is_used_when_edge_features_requested
    test "is built when the features ask for an edge and none was given" do
      two_d = TwoDSensorModule.new("test", features: @features)

      assert {EdgeDetector, %EdgeDetector{}} = two_d.edge_detector

      {percept, _two_d} = step(two_d, patch([1.0, 2.0, 3.0]))

      assert percept.sender_id == "test"
      assert percept.sender_type == :sm
    end

    # test_edge_detector_not_required_when_edge_features_not_requested
    test "is not built when nothing asks for an edge" do
      two_d =
        TwoDSensorModule.new("test",
          features: Enum.reject(@features, &(&1 in ["edge_strength", "coherence"]))
        )

      assert two_d.edge_detector == nil

      {percept, _two_d} = step(two_d, patch([1.0, 2.0, 3.0]))

      assert percept.morphological_features["pose_fully_defined"] == false
    end
  end

  describe "an edge through the middle of the patch" do
    # test_extract_2d_edge_sets_edge_pose_and_features
    test "defines the pose, and reports the edge's strength and coherence" do
      edge = %EdgeFeatures{
        angle: :math.pi() / 2,
        strength: 2.5,
        coherence: 0.75,
        is_geometric_edge: false,
        has_edge: true
      }

      {percept, _two_d} = step(sm(edge_detector: canned(edge)), patch([0.0, 0.0, 0.0]))

      assert percept.morphological_features["pose_fully_defined"] == true

      assert_close(
        percept.morphological_features["pose_vectors"].value,
        [[0.0, 0.0, 1.0], [0.0, -1.0, 0.0], [1.0, 0.0, 0.0]]
      )

      assert percept.non_morphological_features["edge_strength"] == 2.5
      assert percept.non_morphological_features["coherence"] == 0.75
    end

    # test_extract_2d_edge_ignores_no_edge
    test "is not a pose when there is no edge, and the edge features read zero" do
      two_d = sm()
      {before, _two_d} = step(two_d, patch([0.0, 0.0, 0.0]))

      {percept, two_d} = step(two_d, patch([0.0, 0.0, 0.0]))

      assert percept.morphological_features["pose_fully_defined"] == false

      assert_close(
        percept.morphological_features["pose_vectors"].value,
        before.morphological_features["pose_vectors"].value
      )

      assert percept.non_morphological_features["edge_strength"] == 0.0
      assert percept.non_morphological_features["coherence"] == 0.0
      refute is_nil(two_d.tangent_frame)
    end

    # test_extract_2d_edge_ignores_geometric_edge
    test "is not a pose when the edge is a crease in the world" do
      edge = %EdgeFeatures{
        angle: :math.pi() / 2,
        strength: 2.5,
        coherence: 0.75,
        is_geometric_edge: true,
        has_edge: true
      }

      two_d = sm(edge_detector: canned(edge))
      {before, two_d} = step(two_d, patch([0.0, 0.0, 0.0]))
      {percept, _two_d} = step(two_d, patch([0.0, 0.0, 0.0]))

      assert percept.morphological_features["pose_fully_defined"] == false

      assert_close(
        percept.morphological_features["pose_vectors"].value,
        before.morphological_features["pose_vectors"].value
      )

      assert percept.non_morphological_features["edge_strength"] == 0.0
      assert percept.non_morphological_features["coherence"] == 0.0
    end
  end

  describe "the tangent frame" do
    # test_tangent_frame_transported_not_recreated
    test "is carried onto the new surface rather than rebuilt from its normal" do
      # A flat patch, then one on a surface turned 45 degrees about x: the frame
      # has to follow the surface, keeping the axis it already had.
      second_normal = [0.0, :math.sqrt(0.5), :math.sqrt(0.5)]
      second_basis = [[1.0, 0.0, 0.0], [0.0, :math.sqrt(0.5), -:math.sqrt(0.5)]]

      two_d = sm()

      {_first, two_d} = step(two_d, patch([0.0, 0.0, 0.0]))
      first_basis_u = two_d.tangent_frame.basis_u

      {_second, two_d} = step(two_d, patch([0.0, 0.0, 0.0], basis: second_basis))

      assert_close(two_d.tangent_frame.normal, second_normal, 1.0e-6)

      # Transporting turns the old basis onto the new normal; rebuilding it from
      # the normal alone would pick a different axis, which is what the model's
      # coordinates must not do.
      assert_close(two_d.tangent_frame.basis_u, first_basis_u, 1.0e-6)
    end

    # test_multi_step_2d_position_accumulated_on_flat_surface
    test "accumulates the 2-D position step by step on a flat surface" do
      two_d = sm()

      {first, two_d} = step(two_d, patch([1.0, 2.0, 0.0]))
      {second, two_d} = step(two_d, patch([2.0, 2.0, 0.0]))
      {third, two_d} = step(two_d, patch([2.0, 4.0, 0.0]))

      assert two_d.previous_2d_location == [2.0, 4.0]
      assert two_d.previous_3d_location == [2.0, 4.0, 0.0]

      assert_close(first.location, [1.0, 2.0, 0.0])
      assert_close(second.location, [2.0, 2.0, 0.0])
      assert_close(third.location, [2.0, 4.0, 0.0])

      assert_close(second.displacement, [1.0, 0.0, 0.0])
      assert_close(third.displacement, [0.0, 2.0, 0.0])
    end
  end

  defp assert_close(actual, expected, tolerance \\ @tolerance) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn
      {actual_row, expected_row} when is_list(actual_row) ->
        assert_close(actual_row, expected_row, tolerance)

      {actual_value, expected_value} ->
        assert_in_delta actual_value, expected_value, tolerance
    end)
  end
end
