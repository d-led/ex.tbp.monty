defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids do
  @moduledoc """
  Multi-scale images, and the comparisons VOCUS2 makes across them.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/pyramids.py`.

  An attention model has to find what stands out at *some* size and not at
  others: a small bright patch, a long edge, a dark corner. It does that by
  building the image at several resolutions (octaves), each blurred several times
  (scales), and then comparing neighbouring scales — a centre against a
  surround — which is what `center_surround/2` and `laplacian/1` are for.

  The pyramid follows Lowe (2004) as VOCUS2 implements it: each octave starts
  from the extra scale the previous one computed, resampled by `:area`, and each
  following scale is blurred by whatever it takes to reach the next sigma from
  the one before — `sqrt(next² - previous²)`, because blurs compose in
  quadrature. That is the step that makes a pyramid a pyramid rather than a
  handful of blurs.
  """

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @type plane :: [[float()]]

  @doc """
  The resolutions an image of `image_shape` is built at, finest first.

  Each octave is half the previous, and there are as many as fit until a
  dimension would fall below one pixel — or fewer, if `:max_octaves` says so.
  """
  @spec octave_shapes({pos_integer(), pos_integer()}, pos_integer() | nil) :: [
          {pos_integer(), pos_integer()}
        ]
  def octave_shapes({rows, columns} = image_shape, max_octaves \\ nil) do
    possible = trunc(:math.log2(min(rows, columns))) + 1
    wanted = if max_octaves == nil, do: possible, else: min(max_octaves, possible)

    image_shape
    |> Stream.iterate(fn {row, column} -> {div(row, 2), div(column, 2)} end)
    |> Enum.take_while(fn {row, column} -> min(row, column) >= 1 end)
    |> Enum.take(wanted)
  end

  @doc """
  A Gaussian pyramid: `:n_scales` blurred versions of the image at each octave.

  `:sigma` is the blur of the first scale of the first octave, and every octave
  starts from the same sigma, so the scales of one octave and the next mean the
  same thing.
  """
  @spec gaussian_pyramid(plane(), keyword()) :: Pyramid.t()
  def gaussian_pyramid(image, options) do
    sigma = Keyword.fetch!(options, :sigma)
    scales = Keyword.fetch!(options, :n_scales)
    validate_image!(image)

    shapes = octave_shapes(shape(image), Keyword.get(options, :max_octaves))

    {octaves, _extra} =
      Enum.reduce(shapes, {[], nil}, fn octave_shape, {octaves, extra} ->
        planes = octave(image, octave_shape, extra, sigma, scales)

        {[Enum.take(planes, scales) | octaves], List.last(planes)}
      end)

    octaves |> Enum.reverse() |> Pyramid.new()
  end

  # The first octave blurs the image itself; later ones start from the extra
  # scale the octave above computed, resampled to this octave's resolution.
  defp octave(image, _octave_shape, nil, sigma, scales) do
    first = Images.gaussian_blur(image, sigma)
    [first | further_scales(first, sigma, scales)]
  end

  defp octave(_image, octave_shape, extra, sigma, scales) do
    first = Images.resize(extra, octave_shape, :area)
    [first | further_scales(first, sigma, scales)]
  end

  # `scales` more planes, each blurred from the one before by the sigma
  # difference that reaches its target sigma.
  defp further_scales(first, sigma, scales) do
    Enum.scan(1..scales, first, fn scale, previous ->
      Images.gaussian_blur(previous, sigma_difference(sigma, scale, scales))
    end)
  end

  defp sigma_difference(sigma, scale, scales) do
    target = sigma * :math.pow(2.0, scale / scales)
    previous = sigma * :math.pow(2.0, (scale - 1) / scales)

    :math.sqrt(target * target - previous * previous)
  end

  @doc """
  A centre pyramid and its surround, at the same scales.

  The surround is the centre blurred further, by the sigma that takes a centre
  of `:center_sigma` to a surround of `:surround_sigma` — in quadrature again,
  and scaled up with each scale so a coarse level is not compared against a fine
  one's surroundings.
  """
  @spec center_surround(plane(), keyword()) :: {Pyramid.t(), Pyramid.t()}
  def center_surround(image, options) do
    center_sigma = Keyword.fetch!(options, :center_sigma)
    surround_sigma = Keyword.fetch!(options, :surround_sigma)
    scales = Keyword.fetch!(options, :n_scales)

    if center_sigma >= surround_sigma do
      raise ArgumentError, "the centre sigma must be strictly less than the surround sigma"
    end

    center =
      gaussian_pyramid(image,
        sigma: center_sigma,
        n_scales: scales,
        max_octaves: Keyword.get(options, :max_octaves)
      )

    adapted = :math.sqrt(surround_sigma * surround_sigma - center_sigma * center_sigma)

    surround =
      center.planes
      |> Enum.map(fn planes ->
        planes
        |> Enum.with_index()
        |> Enum.map(fn {plane, scale} ->
          Images.gaussian_blur(plane, adapted * :math.pow(2.0, scale / scales))
        end)
      end)
      |> Pyramid.new()

    {center, surround}
  end

  @doc """
  The Laplacian pyramid: each octave minus the octave below it, enlarged back.

  What survives the subtraction is what the coarser octave could not represent —
  the detail this resolution adds — which is what makes an edge visible at the
  scale it belongs to. Has one fewer octave than its input.
  """
  @spec laplacian(Pyramid.t()) :: Pyramid.t()
  def laplacian(pyramid) do
    octaves = Pyramid.n_octaves(pyramid)

    if octaves <= 1 do
      raise ArgumentError, "a Laplacian pyramid needs at least two octaves"
    end

    for octave <- 0..(octaves - 2) do
      for scale <- 0..(Pyramid.n_scales(pyramid) - 1) do
        center = plane(pyramid, octave, scale)
        surround = Images.resize(plane(pyramid, octave + 1, scale), shape(center), :cubic)

        difference(center, surround)
      end
    end
    |> Pyramid.new()
  end

  @doc """
  Combines pyramids of the same shape into one, plane by plane with `reduce`.

  A single pyramid is already the answer, which is how a config that names one
  map and not several still works.
  """
  @spec combine([Pyramid.t()], ([plane()] -> plane())) :: Pyramid.t()
  def combine([], _reduce), do: raise(ArgumentError, "no pyramids to combine")
  def combine([pyramid], _reduce), do: pyramid

  def combine([first | rest] = pyramids, reduce) do
    expected = Pyramid.shape(first)

    Enum.each(rest, fn other ->
      if Pyramid.shape(other) != expected do
        raise ArgumentError, "every pyramid must have the same shape"
      end
    end)

    pyramids
    |> Enum.map(&Pyramid.flat/1)
    |> Enum.zip()
    |> Enum.map(fn planes -> reduce.(Tuple.to_list(planes)) end)
    |> regroup(expected)
    |> Pyramid.new()
  end

  @doc "Combines pyramids by taking the strongest plane at each scale."
  @spec combine_max([Pyramid.t()]) :: Pyramid.t()
  def combine_max(pyramids), do: combine(pyramids, &Enum.max/1)

  @doc "Combines pyramids by averaging their planes."
  @spec combine_mean([Pyramid.t()]) :: Pyramid.t()
  def combine_mean(pyramids), do: combine(pyramids, &(Enum.sum(&1) / length(&1)))

  @doc """
  Collapses a pyramid into one image, the shape of its finest scale.

  Every plane is enlarged to that shape by `:cubic` and then reduced with
  `reduce` — so a map that exists at several scales becomes one map again.
  """
  @spec collapse(Pyramid.t(), ([plane()] -> plane())) :: plane()
  def collapse(pyramid, reduce) do
    [first | _rest] = planes = Pyramid.flat(pyramid)
    target = shape(first)

    planes
    |> Enum.map(fn plane ->
      if shape(plane) == target, do: plane, else: Images.resize(plane, target, :cubic)
    end)
    |> reduce.()
  end

  defp plane(%Pyramid{planes: planes}, octave, scale) do
    planes |> Enum.at(octave) |> Enum.at(scale)
  end

  defp difference(left, right) do
    Enum.zip_with([left, right], fn [left_row, right_row] ->
      Enum.zip_with([left_row, right_row], fn [left_value, right_value] ->
        left_value - right_value
      end)
    end)
  end

  defp regroup(planes, {octaves, scales}) do
    planes
    |> Enum.chunk_every(scales)
    |> Enum.take(octaves)
  end

  defp validate_image!([]), do: raise(ArgumentError, "the image must have a non-zero size")

  defp validate_image!([[] | _rest]) do
    raise ArgumentError, "the image must have a non-zero size"
  end

  defp validate_image!([first | _rest]) when is_list(first), do: :ok

  defp shape([first | _rest] = image) when is_list(first), do: {length(image), length(first)}
end
