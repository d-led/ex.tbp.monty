defmodule Monty.Frameworks.Utils.EdgeDetection.EdgeDetector do
  @moduledoc """
  One patch in, one edge out.

  Mirrors `tbp/monty/frameworks/utils/edge_detection.py::EdgeDetector`.

  The detector does not ask "is there a gradient here" — a texture has gradients
  everywhere. It asks whether the gradients in the patch agree on *one*
  direction, which is what a structure tensor aggregated over the patch
  answers. Three things can then say no:

    * **Nothing was seen.** If every pixel in the weighted neighbourhood has no
      gradient at all (a flat patch), the aggregate is zero and there is no edge
      to report.
    * **The edge is not in the middle.** The weighted centroid of the gradient,
      measured along the edge's normal, is how far from the patch centre the
      edge actually runs. A patch that is half background has an edge at its
      rim, not through its centre, and a module that moved *to* the edge does
      not want to hear about a different edge at the rim.
    * **It is too weak, or too muddled.** `strength_threshold` and
      `coherence_threshold` are separate because a strong but incoherent patch
      (two textures crossing) is not an edge either.

  ## Geometric or texture

  An edge in brightness may be ink on a surface or the surface ending against
  the background. The depth image says which: across a *geometric* edge, depth
  jumps. Monty computes the depth gradient perpendicular to the brightness edge,
  inside a band around it, and calls the edge geometric when the 95th percentile
  of that gradient clears `depth_edge_threshold`. The percentile rather than the
  mean is what makes a one-pixel jump count without a wide crease being needed
  to prove it.
  """

  alias Monty.Frameworks.Utils.EdgeDetection.EdgeFeatures
  alias Monty.Frameworks.Utils.EdgeDetection.ImageOps
  alias Monty.Frameworks.Utils.EdgeDetection.StructureTensor
  alias Monty.Math
  alias Monty.Observations.SensorObservation

  defstruct gaussian_sigma: 1.0,
            kernel_size: 7,
            strength_threshold: 0.1,
            coherence_threshold: 0.5,
            radius: 14.0,
            sigma_r: 7.0,
            depth_edge_threshold: 0.01,
            max_center_offset: nil

  @type t :: %__MODULE__{
          gaussian_sigma: float(),
          kernel_size: pos_integer(),
          strength_threshold: float(),
          coherence_threshold: float(),
          radius: float(),
          sigma_r: float(),
          depth_edge_threshold: float(),
          max_center_offset: number() | nil
        }

  @doc """
  A detector, as Monty's `__init__` reads its arguments.

  `:radius` and `:sigma_r` shape the neighbourhood the tensor is aggregated
  over: a Gaussian that falls to nothing at `radius` pixels from the centre, and
  a falloff of `sigma_r`. `:max_center_offset` is the one setting that changes
  what "an edge" means — `nil` accepts an edge anywhere in the patch, and a
  number accepts it only that close to the centre.

  An even `:kernel_size` is refused: a Gaussian of even size has no centre
  pixel, so the blur would be half a pixel off and the edge with it.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    detector = struct!(__MODULE__, options)

    if rem(detector.kernel_size, 2) != 1 do
      raise ArgumentError, "Kernel size must be odd, got #{detector.kernel_size}"
    end

    detector
  end

  @doc """
  Monty's `__call__`: the edge in this patch, or the reason there is none.

  The outline, in order: grey the patch, Sobel it, build a structure tensor per
  pixel and blur each component, weight the tensors towards the centre and
  towards strong gradients, aggregate, and then ask the three questions above.
  """
  @spec detect(t(), SensorObservation.t()) :: EdgeFeatures.t()
  def detect(%__MODULE__{} = detector, observation) do
    patch =
      observation
      |> SensorObservation.rgba()
      |> Enum.map(&Enum.map(&1, fn pixel -> Enum.take(pixel, 3) end))

    grayscale = ImageOps.to_gray(patch)

    grad_x = ImageOps.sobel(grayscale, :x)
    grad_y = ImageOps.sobel(grayscale, :y)

    {weights, total_weight} = center_weights(detector, grayscale, grad_x, grad_y)

    if total_weight < Math.default_tolerance() do
      EdgeFeatures.no_edge()
    else
      tensor =
        grad_x
        |> per_pixel_tensors(detector, grad_y)
        |> aggregate(weights, total_weight)

      edge_normal_angle = StructureTensor.edge_angle(tensor) + :math.pi() / 2
      center_offset = center_offset(weights, total_weight, edge_normal_angle)

      if passes_center_check?(detector, center_offset) do
        %EdgeFeatures{
          angle: StructureTensor.edge_angle(tensor),
          strength: StructureTensor.edge_strength(tensor),
          coherence: StructureTensor.coherence(tensor),
          is_geometric_edge:
            geometric_edge?(
              detector,
              SensorObservation.depth(observation),
              StructureTensor.edge_angle(tensor),
              center_offset
            ),
          has_edge:
            StructureTensor.edge_strength(tensor) > detector.strength_threshold and
              StructureTensor.coherence(tensor) > detector.coherence_threshold
        }
      else
        EdgeFeatures.no_edge()
      end
    end
  end

  # The squared gradients, blurred — one structure tensor per pixel. Blurring
  # the products rather than the gradients is what makes the tensor describe the
  # neighbourhood and not just the pixel.
  defp per_pixel_tensors(grad_x, detector, grad_y) do
    xx = superpose(grad_x, &(&1 * &1)) |> blur(detector)
    yy = superpose(grad_y, &(&1 * &1)) |> blur(detector)
    xy = combine(grad_x, grad_y) |> blur(detector)

    xx
    |> Enum.zip(yy)
    |> Enum.zip(xy)
    |> Enum.map(fn {{xx_row, yy_row}, xy_row} ->
      xx_row
      |> Enum.zip(yy_row)
      |> Enum.zip(xy_row)
      |> Enum.map(fn {{xx_value, yy_value}, xy_value} ->
        {xx_value, yy_value, xy_value}
      end)
    end)
  end

  defp superpose(image, fun), do: Enum.map(image, fn row -> Enum.map(row, fun) end)
  defp combine(first, second), do: zip_map(first, second, fn a, b -> a * b end)

  defp zip_map(first, second, fun) do
    first
    |> Enum.zip(second)
    |> Enum.map(fn {first_row, second_row} ->
      first_row |> Enum.zip(second_row) |> Enum.map(fn {a, b} -> fun.(a, b) end)
    end)
  end

  defp blur(image, detector),
    do: ImageOps.gaussian_blur(image, detector.kernel_size, detector.gaussian_sigma)

  @doc """
  The weight of every pixel: how close it is to the centre, and how strong its
  gradient is.

  `exp(-d² / 2σ_r²)` with zero past `radius`, multiplied by `Ix² + Iy²`. The
  first factor is what makes the patch answer for its middle; the second is what
  keeps a strong edge near the rim from being discarded just for being far away.
  """
  @spec center_weights(t(), [[number()]], [[number()]], [[number()]]) ::
          {[[float()]], float()}
  def center_weights(%__MODULE__{} = detector, grayscale, grad_x, grad_y) do
    height = length(grayscale)
    width = grayscale |> hd() |> length()
    center_row = div(height, 2)
    center_column = div(width, 2)

    weights =
      for row <- 0..(height - 1)//1 do
        for column <- 0..(width - 1)//1 do
          radial = radial_weight(detector, row - center_row, column - center_column)

          radial *
            (Enum.at(Enum.at(grad_x, row), column) ** 2 +
               Enum.at(Enum.at(grad_y, row), column) ** 2)
        end
      end

    {weights, weights |> List.flatten() |> Enum.sum()}
  end

  defp radial_weight(detector, delta_row, delta_column) do
    squared = delta_row * delta_row + delta_column * delta_column

    if :math.sqrt(squared) > detector.radius do
      0.0
    else
      :math.exp(-squared / (2 * detector.sigma_r * detector.sigma_r))
    end
  end

  defp aggregate(tensors, weights, total_weight) do
    sums =
      tensors
      |> Enum.zip(weights)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {tensor_row, weight_row}, {xx, yy, xy} ->
        tensor_row
        |> Enum.zip(weight_row)
        |> Enum.reduce({xx, yy, xy}, fn {{tensor_xx, tensor_yy, tensor_xy}, weight},
                                        {xx, yy, xy} ->
          {xx + weight * tensor_xx, yy + weight * tensor_yy, xy + weight * tensor_xy}
        end)
      end)

    {xx, yy, xy} = sums
    StructureTensor.new(xx / total_weight, yy / total_weight, xy / total_weight)
  end

  @doc """
  How far, in pixels, the edge runs from the patch centre — signed, along the
  edge's normal.
  """
  @spec center_offset([[number()]], float(), float()) :: float()
  def center_offset(weights, total_weight, normal_angle) do
    height = length(weights)
    width = weights |> hd() |> length()
    center_row = div(height, 2)
    center_column = div(width, 2)

    normal_x = :math.cos(normal_angle)
    normal_y = :math.sin(normal_angle)

    sum =
      weights
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {weight_row, row}, sum ->
        weight_row
        |> Enum.with_index()
        |> Enum.reduce(sum, fn {weight, column}, sum ->
          distance =
            normal_x * (column - center_column) + normal_y * (row - center_row)

          sum + weight * distance
        end)
      end)

    sum / total_weight
  end

  defp passes_center_check?(%__MODULE__{max_center_offset: nil}, _offset), do: true

  defp passes_center_check?(%__MODULE__{max_center_offset: limit}, offset),
    do: abs(offset) <= limit

  @doc """
  Whether the edge is a crease in the world rather than a change in ink.

  The depth gradient across the edge, inside a band 1.5 pixels wide around where
  the brightness edge was found, and its 95th percentile against
  `depth_edge_threshold`.
  """
  @spec geometric_edge?(t(), [[float()]], float(), float()) :: boolean()
  def geometric_edge?(%__MODULE__{} = detector, depth, edge_angle, center_offset) do
    depth_x = ImageOps.sobel(depth, :x)
    depth_y = ImageOps.sobel(depth, :y)

    normal_angle = edge_angle + :math.pi() / 2
    normal_x = :math.cos(normal_angle)
    normal_y = :math.sin(normal_angle)

    height = length(depth)
    width = depth |> hd() |> length()
    center_row = div(height, 2)
    center_column = div(width, 2)

    evidence =
      for row <- 0..(height - 1)//1,
          column <- 0..(width - 1)//1,
          in_band?(
            normal_x * (column - center_column) + normal_y * (row - center_row),
            center_offset
          ),
          do:
            abs(
              normal_x * Enum.at(Enum.at(depth_x, row), column) +
                normal_y * Enum.at(Enum.at(depth_y, row), column)
            )

    case evidence do
      [] -> false
      values -> ImageOps.percentile(values, 95.0) > detector.depth_edge_threshold
    end
  end

  defp in_band?(distance_normal, center_offset), do: abs(distance_normal - center_offset) <= 1.5
end
