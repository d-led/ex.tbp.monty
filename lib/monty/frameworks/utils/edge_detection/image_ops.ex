defmodule Monty.Frameworks.Utils.EdgeDetection.ImageOps do
  @moduledoc """
  The three OpenCV calls Monty's edge detector is built on, written out.

  Monty reads pixels with `cv2.cvtColor`, `cv2.Sobel` and `cv2.GaussianBlur`.
  This application has no OpenCV and no Python in the matching path, so the
  three are here, with the properties that matter for an edge:

    * **Colour to grey** is OpenCV's fixed-point luma,
      `(4899 R + 9617 G + 1868 B + 8192) >> 14`, scaled to `[0, 1]`. The
      coefficients are the usual 0.299/0.587/0.114 in 14-bit fixed point, and the
      rounding term is what makes a half step round up rather than down.
    * **Sobel 3×3** is the separable `[-1, 0, 1] × [1, 2, 1]` derivative, with
      pixels outside the patch reflected **without** repeating the edge
      (`gfedcb | abcdefgh | gfedcba`) — OpenCV's `BORDER_REFLECT_101`, which is
      what `Sobel` and `GaussianBlur` default to. Reflecting rather than zeroing
      is why a patch's border does not read as a bright edge of its own.
    * **Gaussian blur** is a separable kernel of the requested size and sigma,
      centred on the pixel, normalised to sum to one, with the same reflection.

  Pixels outside the patch matter more than they look: an image is a window onto
  a surface that continues past it, and a filter that pretends otherwise invents
  an edge at the window's rim.
  """

  import Bitwise

  @doc """
  The patch's brightness, in `[0, 1]`, from its red, green and blue channels.

  Alpha is ignored: OpenCV's `COLOR_RGB2GRAY` reads three channels and this
  reads the same three.

  The fixed point is OpenCV's, which takes an 8-bit image. A world that renders
  fractions of one instead — the stand-in scene does — is scaled here rather
  than in every consumer: the two conventions meet once, at the fixed point that
  only speaks the first.
  """
  @spec to_gray([[number()]]) :: [[float()]]
  def to_gray(rgba) do
    scale = if fractional?(rgba), do: 255, else: 1

    Enum.map(rgba, fn row ->
      Enum.map(row, fn [red, green, blue | _alpha] ->
        luma = red * scale * 4899 + green * scale * 9617 + blue * scale * 1868 + 8192
        bsr(round(luma), 14) / 255
      end)
    end)
  end

  # An image is either a camera's bytes or fractions of one; there is no third
  # convention, and a brightest channel of at most 1 can only be the second.
  defp fractional?(rgba) do
    rgba
    |> Enum.flat_map(fn row ->
      Enum.flat_map(row, fn [red, green, blue | _] -> [red, green, blue] end)
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.<=(1)
  end

  @doc """
  The derivative of an image along `:x` or `:y`, border reflected.

  `:x` finds vertical edges (brightness changing left to right) and `:y`
  horizontal ones — OpenCV's order, and the order every caller assumes.
  """
  @spec sobel([[number()]], :x | :y) :: [[float()]]
  def sobel(image, axis) do
    kernel =
      case axis do
        :x -> [[-1.0, 0.0, 1.0], [-2.0, 0.0, 2.0], [-1.0, 0.0, 1.0]]
        :y -> [[-1.0, -2.0, -1.0], [0.0, 0.0, 0.0], [1.0, 2.0, 1.0]]
      end

    convolve(image, kernel)
  end

  @doc """
  A symmetric Gaussian blur of the given kernel size and sigma.

  Two one-dimensional passes, which is what OpenCV does: a `size × size` kernel
  is the outer product of one vector of weights with itself, so the passes give
  the same answer for `2 size` multiplications a pixel instead of `size²`.
  """
  @spec gaussian_blur([[number()]], pos_integer(), float()) :: [[float()]]
  def gaussian_blur(image, size, sigma) do
    weights = gaussian_kernel(size, sigma)

    image
    |> blur_rows(weights)
    |> transpose()
    |> blur_rows(weights)
    |> transpose()
  end

  @doc "A normalised Gaussian kernel of `size` weights, centred on the middle one."
  @spec gaussian_kernel(pos_integer(), float()) :: [float()]
  def gaussian_kernel(size, sigma) do
    centre = (size - 1) / 2
    denominator = 2 * sigma * sigma

    weights =
      for index <- 0..(size - 1)//1 do
        distance = index - centre
        :math.exp(-(distance * distance) / denominator)
      end

    weights |> Enum.sum() |> then(&Enum.map(weights, fn weight -> weight / &1 end))
  end

  @doc """
  The `percentile`-th value of `values`, interpolating between neighbours.

  numpy's default, which is what Monty asks for: position `(n - 1) * p / 100` in
  the sorted list, then a straight line between the two values it falls between.
  """
  @spec percentile([number()], float()) :: float()
  def percentile([], _percentile), do: 0.0

  def percentile(values, percentile) do
    sorted = Enum.sort(values)
    position = (length(sorted) - 1) * percentile / 100
    lower = trunc(:math.floor(position))
    upper = min(lower + 1, length(sorted) - 1)
    fraction = position - lower

    Enum.at(sorted, lower) + fraction * (Enum.at(sorted, upper) - Enum.at(sorted, lower))
  end

  @doc """
  An index folded back into `0..(length - 1)` without repeating the edge.

  `-1` reads `1` and `length` reads `length - 2` — OpenCV's `BORDER_REFLECT_101`.
  """
  @spec reflected(integer(), pos_integer()) :: non_neg_integer()
  def reflected(_index, 1), do: 0

  def reflected(index, length) do
    cond do
      index < 0 -> reflected(-index, length)
      index > length - 1 -> reflected(2 * (length - 1) - index, length)
      true -> index
    end
  end

  defp blur_rows(image, weights) do
    half = div(length(weights) - 1, 2)
    width = image |> hd() |> length()

    Enum.map(image, fn row ->
      for column <- 0..(width - 1)//1 do
        weights
        |> Enum.with_index()
        |> Enum.map(fn {weight, index} ->
          weight * Enum.at(row, reflected(column + index - half, width))
        end)
        |> Enum.sum()
      end
    end)
  end

  defp convolve(image, kernel) do
    height = length(image)
    width = image |> hd() |> length()

    for row <- 0..(height - 1)//1 do
      for column <- 0..(width - 1)//1 do
        convolved_at(image, kernel, {row, column}, {height, width})
      end
    end
  end

  # One pixel's answer: every kernel weight against the pixel it sits over, with
  # the patch's edges reflected so the window is always full.
  defp convolved_at(image, kernel, {row, column}, {height, width}) do
    kernel
    |> Enum.with_index()
    |> Enum.map(fn {kernel_row, row_offset} ->
      kernel_row
      |> Enum.with_index()
      |> Enum.map(fn {weight, column_offset} ->
        weight * pixel(image, row + row_offset - 1, column + column_offset - 1, {height, width})
      end)
      |> Enum.sum()
    end)
    |> Enum.sum()
  end

  defp pixel(image, row, column, {height, width}) do
    image
    |> Enum.at(reflected(row, height))
    |> Enum.at(reflected(column, width))
  end

  defp transpose(image) do
    image
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
  end
end
