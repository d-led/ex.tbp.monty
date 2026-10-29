defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images do
  @moduledoc """
  The colour and blur operations VOCUS2's attention model is built from.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/images.py`,
  which is four lines of arithmetic per function and a call into OpenCV for the
  rest. The arithmetic ports exactly; the OpenCV calls had to be measured.

  ## Colour spaces

  The attention model does not work on RGB. It works on a colour space where
  brightness and the two colour-opponent axes are separate, because "this patch
  is brighter than its surroundings" and "this patch is redder than its
  surroundings" are different questions and the second is invisible in RGB.
  Two of Monty's three spellings are pure arithmetic:

    * `rgb_to_opponent/1` — the classic opponent space, shifted to `[0, 1]`;
    * `rgb_to_opponent_codi/1` — Klein and Frintrop's variant, where the axes
      are not shifted, so a neutral grey is zero rather than a half.

  The third, `rgb_to_lab/1`, is CIE Lab and goes through OpenCV in Monty. See
  its documentation for what "measured" means there.

  ## Which images

  A single-channel image is rows of numbers; a colour image is rows of
  `[r, g, b]`, with the values as they were read: `0..255`. Blurring is for the
  single-channel images the pyramids are built from.
  """

  @type pixel :: [float()]
  @type colour_image :: [[pixel()]]
  @type plane :: [[float()]]

  @doc """
  The image in CIE Lab, shifted and scaled to `[0, 1]`.

  Monty calls `cv2.cvtColor(image, COLOR_RGB2Lab)` and divides by 255. OpenCV
  answers `CV_8U` for an 8-bit input, so `L` arrives as `0..255` for `0..100`
  and `a`, `b` arrive shifted by 128 — which is what makes the division by 255
  the right way back.

  ## Measured, not recalled

  OpenCV 4.10 converts 8-bit RGB to Lab through integer lookup tables; this port
  computes the standard sRGB → XYZ → Lab chain in floating point. The two are
  close but not identical: measured over all 16,777,216 colours, the worst
  disagreement is 2.67 units of 255 — about one percent of the range, in the
  dark, saturated corner — which is OpenCV's 8-bit quantisation showing, not a
  different colour space. `docs/monty-bugs.md` §1.12 records it.
  """
  @spec rgb_to_lab(colour_image()) :: colour_image()
  def rgb_to_lab(image) do
    Enum.map(image, fn row -> Enum.map(row, &lab_pixel/1) end)
  end

  defp lab_pixel(pixel) do
    [l, a, b] =
      pixel
      |> to_xyz()
      |> xyz_to_lab()
      |> scale_lab()

    [l / 255.0, a / 255.0, b / 255.0]
  end

  # sRGB, gamma-decoded, against OpenCV's D65 matrix.
  defp to_xyz([r, g, b]) do
    [r, g, b] = Enum.map([r, g, b], &gamma_decode(&1 / 255.0))

    [
      0.412453 * r + 0.357580 * g + 0.180423 * b,
      0.212671 * r + 0.715160 * g + 0.072169 * b,
      0.019334 * r + 0.119193 * g + 0.950227 * b
    ]
  end

  defp gamma_decode(value) when value <= 0.04045, do: value / 12.92
  defp gamma_decode(value), do: :math.pow((value + 0.055) / 1.055, 2.4)

  # OpenCV's white point.
  @white [0.950456, 1.0, 1.088754]

  defp xyz_to_lab(xyz) do
    [f_x, f_y, f_z] =
      Enum.zip_with([xyz, @white], fn [value, white] -> lab_f(value / white) end)

    [116.0 * f_y - 16.0, 500.0 * (f_x - f_y), 200.0 * (f_y - f_z)]
  end

  defp lab_f(value) when value > 0.008856, do: :math.pow(value, 1.0 / 3.0)
  defp lab_f(value), do: 7.787 * value + 16.0 / 116.0

  # The scaling OpenCV applies on the way out: L in 0..255, a and b shifted by
  # 128 and clipped, because an 8-bit image has no negative numbers.
  defp scale_lab([l, a, b]) do
    [
      clamp(255.0 * l / 100.0, 0.0, 255.0),
      clamp(a + 128.0, 0.0, 255.0),
      clamp(b + 128.0, 0.0, 255.0)
    ]
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  @doc """
  The image in the opponent colour space, shifted and scaled to `[0, 1]`.

  One channel of brightness and two of colour opponency: red against green, and
  blue against the mean of red and green. The shifts by 255 and divisions by 2
  are what put an opponent axis, which is signed, inside `[0, 1]`.
  """
  @spec rgb_to_opponent(colour_image()) :: colour_image()
  def rgb_to_opponent(image) do
    Enum.map(image, fn row -> Enum.map(row, &opponent_pixel/1) end)
  end

  defp opponent_pixel([r, g, b]) do
    [
      (r + g + b) / (3 * 255.0),
      (r - g + 255.0) / (2 * 255.0),
      (b - (g + r) / 2.0 + 255.0) / (2 * 255.0)
    ]
  end

  @doc """
  The image in Klein and Frintrop's opponent space, as VOCUS2 implements it.

  The same two colour axes as `rgb_to_opponent/1` without the shift, so a
  neutral grey sits at zero and the sign of an axis means something. Brightness
  is still `[0, 1]`.
  """
  @spec rgb_to_opponent_codi(colour_image()) :: colour_image()
  def rgb_to_opponent_codi(image) do
    Enum.map(image, fn row -> Enum.map(row, &codi_pixel/1) end)
  end

  defp codi_pixel([r, g, b]) do
    [
      (r + g + b) / (3 * 255.0),
      (r - g) / 255.0,
      (b - (g + r) / 2.0) / 255.0
    ]
  end

  @doc """
  Blurs a single-channel image with a Gaussian of `sigma`.

  Monty computes the kernel size itself — `round(2 * truncate * sigma + 1)`,
  forced odd — and passes both it and `sigma` to OpenCV, so there is no
  auto-computed sigma to reproduce. The border is `BORDER_REPLICATE`: the edge
  pixel is repeated outward, which keeps a pyramid's coarse levels from darkening
  at their edges.

  The kernel is a normalised Gaussian sampled at integer offsets and applied in
  two passes, as OpenCV applies it.
  """
  @spec gaussian_blur(plane(), float(), float()) :: plane()
  def gaussian_blur(image, sigma, truncate \\ 2.5)

  def gaussian_blur(image, sigma, truncate) do
    kernel = kernel(sigma, truncate)

    image
    |> pad_replicate(div(length(kernel), 2))
    |> Enum.map(&convolve(&1, kernel))
    |> then(fn rows -> rows |> transpose() |> Enum.map(&convolve(&1, kernel)) |> transpose() end)
  end

  defp kernel(sigma, truncate) do
    size = round(2 * truncate * sigma + 1) |> then(&if(rem(&1, 2) == 0, do: &1 + 1, else: &1))
    pad = div(size, 2)

    weights =
      Enum.map(-pad..pad, fn offset -> :math.exp(-(offset * offset) / (2 * sigma * sigma)) end)

    total = Enum.sum(weights)
    Enum.map(weights, &(&1 / total))
  end

  # The edge pixel repeated outward, which is `BORDER_REPLICATE`.
  defp pad_replicate(rows, 0), do: rows

  defp pad_replicate(rows, pad) do
    rows
    |> pad_axis(pad)
    |> Enum.map(&pad_axis(&1, pad))
  end

  defp pad_axis(values, pad) do
    [first | _rest] = values
    [last | _rest] = Enum.reverse(values)
    List.duplicate(first, pad) ++ values ++ List.duplicate(last, pad)
  end

  defp convolve(row, kernel) do
    window = length(kernel)
    width = length(row) - window + 1

    Enum.map(0..(width - 1), fn start ->
      row
      |> Enum.slice(start, window)
      |> Enum.zip(kernel)
      |> Enum.reduce(0.0, fn {value, weight}, sum -> sum + value * weight end)
    end)
  end

  defp transpose([]), do: []

  defp transpose([first | _rest] = rows) do
    first
    |> Enum.with_index()
    |> Enum.map(fn {_value, column} -> Enum.map(rows, &Enum.at(&1, column)) end)
  end

  @doc """
  Resizes a single-channel image to `{rows, columns}`.

  Monty passes OpenCV's interpolation constants; here they are `:area` and
  `:cubic`, the two the attention model uses. `:area` averages what each
  destination pixel covers, which is the right way to shrink an image: no
  detail is dropped, it is averaged in. `:cubic` interpolates a cubic through
  the four nearest source pixels, which is the right way to enlarge one.

  ## Measured, not recalled

  Both were checked against OpenCV 4.10 over random shapes and agree to float32
  precision. Cubic uses OpenCV's coefficient `A = -0.75` and its coordinate
  convention — the destination pixel's centre maps to `(i + 0.5) * scale - 0.5`
  in the source — and both clamp outside the image rather than reading a border.

  `:area` dips below a pixel step when the destination is *larger* than the
  source: OpenCV was measured to answer something that is neither area nor
  linear there, and Monty never asks — the pyramids only ever shrink by area and
  enlarge by cubic. This port answers the ordinary area average in that case;
  `docs/monty-bugs.md` §1.13 records the difference.
  """
  @spec resize(plane(), {pos_integer(), pos_integer()}, :area | :cubic) :: plane()
  def resize(image, {rows, columns}, interpolation \\ :area) do
    source = {length(image), image |> hd() |> length()}
    destination = {rows, columns}

    cond do
      source == destination -> image
      interpolation == :area -> by_area(image, source, destination)
      true -> by_cubic(image, source, destination)
    end
  end

  defp by_area(image, source, {rows, columns} = destination) do
    for row <- 0..(rows - 1) do
      for column <- 0..(columns - 1) do
        area_average(image, source, destination, {row, column})
      end
    end
  end

  # Each destination pixel averages the source it covers, weighted by how much
  # of each source pixel that is.
  defp area_average(image, {source_rows, source_columns}, {rows, columns}, {row, column}) do
    y = span(row, rows, source_rows)
    x = span(column, columns, source_columns)

    {weighted, weights} =
      for source_row <- y.first..y.last,
          source_column <- x.first..x.last,
          reduce: {0.0, 0.0} do
        {weighted, weights} ->
          coverage = coverage(source_row, y) * coverage(source_column, x)
          value = image |> Enum.at(source_row) |> Enum.at(source_column)

          {weighted + value * coverage, weights + coverage}
      end

    weighted / weights
  end

  # The source pixels one destination pixel covers, as `first..last` with the
  # fraction of each end pixel it covers.
  defp span(index, destination, source) do
    low = index * source / destination
    high = (index + 1) * source / destination

    %{
      first: floor(low),
      last: ceil(high) - 1,
      low: low,
      high: high
    }
  end

  defp coverage(index, %{first: first, last: last, low: low, high: high}) do
    cond do
      first == last -> high - low
      index == first -> first + 1 - low
      index == last -> high - last
      true -> 1.0
    end
  end

  defp by_cubic(image, source, {rows, columns}) do
    {source_rows, source_columns} = source

    for row <- 0..(rows - 1) do
      {offsets_y, weights_y} = cubic_taps(row, rows, source_rows)

      for column <- 0..(columns - 1) do
        {offsets_x, weights_x} = cubic_taps(column, columns, source_columns)

        for {source_row, weight_y} <- Enum.zip(offsets_y, weights_y), reduce: 0.0 do
          sum -> sum + weight_y * weighted_row(image, source_row, offsets_x, weights_x)
        end
      end
    end
  end

  defp weighted_row(image, source_row, offsets_x, weights_x) do
    row = Enum.at(image, source_row)

    Enum.zip_with([offsets_x, weights_x], fn [column, weight] ->
      Enum.at(row, column) * weight
    end)
    |> Enum.sum()
  end

  # The four taps a destination coordinate reads, as offsets from the clamped
  # nearest source index, and their weights.
  defp cubic_taps(index, destination, source) do
    coordinate = (index + 0.5) * source / destination - 0.5
    nearest = floor(coordinate)
    fraction = coordinate - nearest

    offsets = for offset <- -1..2, do: clamp(nearest + offset, 0, source - 1)

    {offsets, cubic_weights(fraction)}
  end

  # OpenCV's cubic, with A = -0.75. The last weight is the remainder, which is
  # what makes the four weights sum to one.
  @cubic_a -0.75

  defp cubic_weights(fraction) do
    x = fraction

    first =
      ((@cubic_a * (x + 1) - 5 * @cubic_a) * (x + 1) + 8 * @cubic_a) * (x + 1) - 4 * @cubic_a

    second = ((@cubic_a + 2) * x - (@cubic_a + 3)) * x * x + 1
    third = ((@cubic_a + 2) * (1 - x) - (@cubic_a + 3)) * (1 - x) * (1 - x) + 1

    [first, second, third, 1.0 - first - second - third]
  end
end
