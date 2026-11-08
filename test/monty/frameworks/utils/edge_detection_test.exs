defmodule Monty.Frameworks.Utils.EdgeDetectionTest do
  @moduledoc """
  The edge detector, case for case from Monty's
  `tests/unit/frameworks/utils/edge_detection_test.py`.

  Where Monty drives a property with `hypothesis`, this drives the same property
  with `StreamData`; where it parametrises the five closed-form camera cases,
  this lists the same five. Each case names the Monty case it translates.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.Utils.EdgeDetection
  alias Monty.Frameworks.Utils.EdgeDetection.EdgeDetector
  alias Monty.Frameworks.Utils.EdgeDetection.ImageOps
  alias Monty.Frameworks.Utils.EdgeDetection.StructureTensor
  alias Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame
  alias Monty.Geometry.Rotation
  alias Monty.Math
  alias Monty.Test.EdgeDetectorFixture

  @tolerance Math.default_tolerance()
  @patch_size 64

  # Monty's `structure_tensors()`: a positive-semidefinite tensor, with
  # `|xy| <= sqrt(xx * yy)` so the determinant is never negative.
  defp structure_tensor_generator(max_value \\ 100.0) do
    gen all(
          xx <-
            StreamData.float(min: 0.0, max: max_value)
            |> StreamData.filter(&(abs(&1) > @tolerance)),
          yy <-
            StreamData.float(min: 0.0, max: max_value)
            |> StreamData.filter(&(abs(&1) > @tolerance)),
          bound = :math.sqrt(xx * yy),
          xy <-
            StreamData.float(min: -bound, max: bound)
            |> StreamData.filter(&(abs(&1) > @tolerance))
        ) do
      StructureTensor.new(xx, yy, xy)
    end
  end

  defp positive_generator, do: StreamData.float(min: @tolerance, max: 100.0)

  # Monty's `rotation_matrices`: any rotation, as the 3×3 block of a camera
  # transform.
  defp rotation_generator do
    gen all(
          x <- StreamData.float(min: -1.0, max: 1.0),
          y <- StreamData.float(min: -1.0, max: 1.0),
          z <- StreamData.float(min: -1.0, max: 1.0),
          angle <- StreamData.float(min: -:math.pi(), max: :math.pi()),
          axis <- StreamData.constant(normalise([x, y, z]))
        ) do
      {:ok, rotation} = Rotation.from_axis_angle(axis, angle)
      Rotation.to_matrix(rotation)
    end
  end

  defp normalise([x, y, z]) do
    length = :math.sqrt(x * x + y * y + z * z)

    if length < 0.1 do
      [1.0, 0.0, 0.0]
    else
      [x / length, y / length, z / length]
    end
  end

  defp angle_distance(actual, expected) do
    abs(:math.fmod(actual - expected + :math.pi() / 2, :math.pi()) - :math.pi() / 2)
  end

  describe "a structure tensor" do
    # test_eigenvalues_match_analytical
    test "has eigenvalues (trace ± root) / 2" do
      tensor = StructureTensor.new(3.0, 1.0, 1.0)
      {lambda_min, lambda_max} = StructureTensor.eigenvalues(tensor)

      assert_in_delta lambda_min, 2.0 - :math.sqrt(2.0), @tolerance
      assert_in_delta lambda_max, 2.0 + :math.sqrt(2.0), @tolerance
    end

    # test_eigenvalues_ordered
    property "keeps its eigenvalues in order, even for a zero tensor" do
      check all(
              tensor <- structure_tensor_generator(),
              max_runs: 30
            ) do
        {lambda_min, lambda_max} = StructureTensor.eigenvalues(tensor)
        assert lambda_min <= lambda_max
      end

      assert StructureTensor.eigenvalues(StructureTensor.new(0.0, 0.0, 0.0)) == {0.0, 0.0}
    end

    # test_edge_strength_nonnegative
    property "reports a strength that is never negative, even when only y varies" do
      check all(tensor <- structure_tensor_generator()) do
        assert StructureTensor.edge_strength(tensor) >= 0.0
      end

      assert StructureTensor.edge_strength(StructureTensor.new(0.0, 9.0, 0.0)) >= 0.0
    end

    # test_coherence_in_unit_interval
    property "reports a coherence in [0, 1]" do
      check all(tensor <- structure_tensor_generator()) do
        coherence = StructureTensor.coherence(tensor)
        assert coherence >= 0.0 and coherence <= 1.0
      end
    end

    # test_edge_angle_range
    property "reports an edge angle in [0, pi]" do
      check all(tensor <- structure_tensor_generator()) do
        angle = StructureTensor.edge_angle(tensor)
        assert angle >= 0.0 and angle <= :math.pi()
      end
    end

    # test_eigenvalue_trace_equals_jxx_plus_jyy
    property "sums its eigenvalues to the trace" do
      check all(tensor <- structure_tensor_generator()) do
        {lambda_min, lambda_max} = StructureTensor.eigenvalues(tensor)
        assert_in_delta lambda_min + lambda_max, tensor.xx + tensor.yy, @tolerance
      end
    end

    # test_eigenvalue_product_equals_determinant
    property "multiplies its eigenvalues to the determinant" do
      check all(tensor <- structure_tensor_generator()) do
        {lambda_min, lambda_max} = StructureTensor.eigenvalues(tensor)

        assert_in_delta lambda_min * lambda_max,
                        tensor.xx * tensor.yy - tensor.xy ** 2,
                        @tolerance
      end
    end

    # test_isotropic_coherence_is_zero
    property "has no coherence when the two directions are equally strong" do
      check all(k <- positive_generator()) do
        assert_in_delta StructureTensor.coherence(StructureTensor.new(k, k, 0.0)), 0.0, @tolerance
      end
    end

    # test_scaling_multiplies_edge_strength
    property "scaling a tensor scales its strength by the square root" do
      check all(
              tensor <- structure_tensor_generator(),
              k <- positive_generator()
            ) do
        scaled = StructureTensor.new(k * tensor.xx, k * tensor.yy, k * tensor.xy)

        assert_in_delta StructureTensor.edge_strength(scaled),
                        :math.sqrt(k) * StructureTensor.edge_strength(tensor),
                        @tolerance
      end
    end

    # test_scaling_preserves_gradient_theta
    property "scaling a tensor leaves the gradient direction alone" do
      check all(
              tensor <- structure_tensor_generator(),
              k <- positive_generator()
            ) do
        scaled = StructureTensor.new(k * tensor.xx, k * tensor.yy, k * tensor.xy)

        assert_in_delta StructureTensor.gradient_theta(scaled),
                        StructureTensor.gradient_theta(tensor),
                        @tolerance
      end
    end

    # test_edge_strength_equals_sqrt_lambda_max
    property "reports the root of the larger eigenvalue as its strength" do
      check all(tensor <- structure_tensor_generator()) do
        {_lambda_min, lambda_max} = StructureTensor.eigenvalues(tensor)

        assert_in_delta StructureTensor.edge_strength(tensor),
                        :math.sqrt(max(lambda_max, 0.0)),
                        1.0e-10
      end
    end
  end

  describe "an edge detector" do
    # test_kernel_size_is_not_odd
    test "refuses an even kernel size, which has no centre pixel" do
      assert_raise ArgumentError, ~r/must be odd/, fn -> EdgeDetector.new(kernel_size: 2) end
    end

    # test_uniform_patch_returns_no_edge
    property "finds no edge in a patch with no structure, whichever way the camera faces" do
      check all(matrix <- rotation_generator(), max_runs: 10) do
        edge = inspect_patch(EdgeDetector.new(), EdgeDetectorFixture.uniform(@patch_size), matrix)

        assert edge.strength == 0.0
        assert edge.coherence == 0.0
        assert edge.angle == nil
        refute edge.is_geometric_edge
        refute edge.has_edge
      end
    end

    # test_center_offset_rejects_off_center_edge
    test "rejects an edge that runs along the patch border rather than through it" do
      detector = EdgeDetector.new(radius: div(@patch_size, 2), max_center_offset: 1)

      edge =
        inspect_patch(
          detector,
          EdgeDetectorFixture.edge_at_right_border(@patch_size),
          EdgeDetectorFixture.camera(:identity)
        )

      assert edge.strength == 0.0
      assert edge.coherence == 0.0
      assert edge.angle == nil
      refute edge.is_geometric_edge
      refute edge.has_edge
    end

    # test_edge_detection_for_closed_form_solutions, one case per camera
    for entry <- [
          {:identity_camera_vertical_edge, :math.pi() / 2, :identity},
          {:identity_camera_diagonal_edge, :math.pi() / 4, :identity},
          {:identity_camera_horizontal_edge, :math.pi(), :identity},
          {:rotated_camera_surface_x_horizontal_edge, :math.pi(), :x_to_y_camera},
          {:camera_y_to_world_z_surface_y_diagonal_edge, :math.pi() / 4, :y_to_z_camera}
        ] do
      {name, angle, camera} = entry

      test "finds the edge of the #{name} patch" do
        edge =
          inspect_patch(
            EdgeDetector.new(),
            EdgeDetectorFixture.angled_edge(unquote(angle), @patch_size),
            EdgeDetectorFixture.camera(unquote(camera))
          )

        assert angle_distance(edge.angle, unquote(angle)) < 0.1
      end
    end

    # test_angled_edge_patch_reports_expected_angle
    property "finds the edge of a patch cut at any angle, whichever way the camera faces" do
      check all(
              angle <- StreamData.float(min: @tolerance, max: :math.pi()),
              matrix <- rotation_generator(),
              max_runs: 20
            ) do
        edge =
          inspect_patch(
            EdgeDetector.new(),
            EdgeDetectorFixture.angled_edge(angle, @patch_size),
            matrix
          )

        assert angle_distance(edge.angle, angle) < 0.1
      end
    end
  end

  describe "an edge angle, as a 2-D pose" do
    # test_angle_converts_to_expected_pose_2d, one case per camera
    for entry <- [
          {:identity_camera_vertical_edge, :math.pi() / 2, :identity, [0.0, 0.0, 1.0],
           [[0.0, 0.0, 1.0], [0.0, -1.0, 0.0], [1.0, 0.0, 0.0]]},
          {:identity_camera_diagonal_edge, :math.pi() / 4, :identity, [0.0, 0.0, 1.0],
           [
             [0.0, 0.0, 1.0],
             [:math.sqrt(0.5), -:math.sqrt(0.5), 0.0],
             [:math.sqrt(0.5), :math.sqrt(0.5), 0.0]
           ]},
          {:identity_camera_horizontal_edge, :math.pi(), :identity, [0.0, 0.0, 1.0],
           [[0.0, 0.0, 1.0], [-1.0, 0.0, 0.0], [0.0, -1.0, 0.0]]},
          {:rotated_camera_surface_x_horizontal_edge, :math.pi(), :x_to_y_camera, [1.0, 0.0, 0.0],
           [[0.0, 0.0, 1.0], [0.0, -1.0, 0.0], [1.0, 0.0, 0.0]]},
          {:camera_y_to_world_z_surface_y_diagonal_edge, :math.pi() / 4, :y_to_z_camera,
           [0.0, 1.0, 0.0],
           [
             [0.0, 0.0, 1.0],
             [-:math.sqrt(0.5), -:math.sqrt(0.5), 0.0],
             [:math.sqrt(0.5), -:math.sqrt(0.5), 0.0]
           ]}
        ] do
      {name, angle, camera, normal, expected} = entry

      test "is the frame the #{name} case expects" do
        pose =
          EdgeDetection.angle_to_pose_2d(
            unquote(angle),
            EdgeDetectorFixture.camera(unquote(camera)),
            unquote(normal),
            TangentFrame.new(unquote(normal))
          )

        assert_close(pose.value, unquote(Macro.escape(expected)))
      end
    end

    # test_angle_to_pose_2d_uses_transported_tangent_frame
    test "is expressed in the frame the basis was transported into" do
      surface_normal = [1.0, 1.0, 1.0]
      frame = TangentFrame.new(surface_normal)

      frame =
        Enum.reduce(
          [[0.0, 0.2, 1.0], [0.0, 0.5, 1.0], [0.0, 1.0, 1.0], [0.0, 1.0, 0.0]],
          frame,
          fn normal, frame ->
            TangentFrame.transport(
              frame,
              Monty.Frameworks.Utils.SpatialArithmetics.normalize(normal)
            )
          end
        )

      angle = :math.pi() / 2
      camera = EdgeDetectorFixture.camera(:identity)

      pose = EdgeDetection.angle_to_pose_2d(angle, camera, surface_normal, frame)

      assert_close(
        pose.value,
        EdgeDetectorFixture.expected_pose_2d(angle, camera, surface_normal, frame).value
      )
    end
  end

  describe "the image operations Monty borrows from OpenCV" do
    test "a grey patch is OpenCV's fixed-point luma, in [0, 1]" do
      assert ImageOps.to_gray([[[255, 255, 255, 255], [0, 0, 0, 255]]]) == [[1.0, 0.0]]

      # 0.299, 0.587 and 0.114 in fourteen-bit fixed point, rounded to eight bits.
      assert [[red]] = ImageOps.to_gray([[[255, 0, 0, 255]]])
      assert_in_delta red, 0.299, 1.0e-3
    end

    test "a Sobel derivative of a constant image is zero, borders and all" do
      constant = List.duplicate(List.duplicate(1.0, 8), 8)

      assert ImageOps.sobel(constant, :x) |> List.flatten() |> Enum.all?(&(&1 == 0.0))
      assert ImageOps.sobel(constant, :y) |> List.flatten() |> Enum.all?(&(&1 == 0.0))
    end

    test "an index outside the patch reflects without repeating the edge" do
      assert ImageOps.reflected(-1, 5) == 1
      assert ImageOps.reflected(-4, 5) == 4
      assert ImageOps.reflected(5, 5) == 3
      assert ImageOps.reflected(2, 5) == 2
    end

    test "a Gaussian kernel is symmetric and sums to one" do
      weights = ImageOps.gaussian_kernel(7, 1.0)

      assert_in_delta Enum.sum(weights), 1.0, 1.0e-12
      assert weights == Enum.reverse(weights)
    end

    test "a percentile interpolates between neighbours" do
      assert ImageOps.percentile([0.0, 1.0, 2.0, 3.0, 4.0], 50.0) == 2.0
      assert ImageOps.percentile([0.0, 1.0], 95.0) == 0.95
      assert ImageOps.percentile([], 95.0) == 0.0
    end
  end

  defp inspect_patch(detector, rgba, cam_to_world) do
    EdgeDetector.detect(detector, %{
      "rgba" => rgba,
      "depth" => EdgeDetectorFixture.flat_depth(@patch_size),
      "cam_to_world" => cam_to_world
    })
  end

  defp assert_close(actual, expected) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.each(fn {actual_row, expected_row} ->
      Enum.zip(actual_row, expected_row)
      |> Enum.each(fn {actual_value, expected_value} ->
        assert_in_delta actual_value, expected_value, @tolerance
      end)
    end)
  end
end
