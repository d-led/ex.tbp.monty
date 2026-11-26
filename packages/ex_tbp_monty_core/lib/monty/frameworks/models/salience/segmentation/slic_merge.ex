defmodule Monty.Frameworks.Models.Salience.Segmentation.SlicMerge do
  @moduledoc """
  SLIC superpixels, merged outward from the point of fixation.

  Mirrors `tbp/monty/frameworks/models/salience/segmentation/slic_merge.py`, the
  segmentation the cows family's view finder names. A step is five judgements:

    * **segment** the view into SLIC superpixels — `skimage.segmentation.slic`
      with a regular seed grid, k-means in Lab-plus-position space and a
      connectivity pass, ported here step for step (`segment_image/2`);
    * **weigh** each superpixel by its mean colour (`extract_region_colors/2`);
    * **join** the superpixels that share an edge into a graph
      (`build_adjacency_graph/2`);
    * **walk** that graph from the superpixel under the centre of the view,
      taking each neighbour whose colour is close enough to the one it was
      reached from (`merge_regions/4`);
    * **answer** a mask that is one where the walk reached and zero where it did
      not (`create_mask/2`).

  The region is what a salience module attends to, so the walk is the point: a
  superpixel boundary inside one object should not cut the attention region in
  two, and the boundary between an object and the table behind it should.

  ## Two colour scales, because Monty has two

  Monty's `extract_region_colors/2` converts with `cv2.cvtColor(...,
  COLOR_RGB2LAB)` and divides by 255, so its merge threshold of 0.04 is a
  threshold in Lab scaled to `[0, 1]`; that is `Images.rgb_to_lab/1` here. Its
  SLIC call passes the RGB image to `skimage`, which converts on its own to Lab
  with `L` in `0..100`, and its `compactness` of 10 is calibrated against that
  scale. Both are done where Monty does them, in the scale each function means.

  ## Two places where a number cannot be written the same way

  Both are recorded in `docs/monty-differences.md` §2.36:

    * the Lab conversion is this port's floating-point sRGB → XYZ → Lab chain on
      both paths, where Monty's two paths are OpenCV's 8-bit tables (§1.12) and
      `skimage`'s own floats — the same colour space, and the largest
      disagreement is worth one percent of the range, in the darkest, most
      saturated corner;
    * a segment that wins no pixels is divided by zero by `skimage`, and its
      centroid then becomes NaN, which can never claim a pixel again. NaN is
      `nil` here (`docs/validation.md`), so such a centroid is marked `:dead` and
      skipped — the same label field, without a NaN to poison every comparison
      that follows.
  """

  @behaviour Monty.Frameworks.Models.Salience.Segmentation.Strategy.SegmentationStrategy

  alias ExTbpMonty.Core.SalienceNif
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images

  # `DBL_MAX`: the distance every pixel starts at, so the first seed to reach a
  # pixel takes it.
  @unclaimed 1.7976931348623157e308

  # `skimage.filters.gaussian`'s default: the kernel is cut at four sigmas.
  @truncate 4.0

  @enforce_keys []
  defstruct n_seeds: 70,
            compactness: 10.0,
            max_iter: 10,
            sigma: 1.0,
            min_size_factor: 0.5,
            max_size_factor: 3.0,
            merge_threshold: 0.04

  @type t :: %__MODULE__{
          n_seeds: pos_integer(),
          compactness: float(),
          max_iter: pos_integer(),
          sigma: float(),
          min_size_factor: float(),
          max_size_factor: float(),
          merge_threshold: float()
        }

  @typedoc "A colour, as the port carries one: three numbers."
  @type colour :: [float()]

  @typedoc """
  A centroid: where it is in the view, the colour it has drifted to, and whether
  it still owns any pixel.
  """
  @type centroid :: %{
          y: float(),
          x: float(),
          colour: colour(),
          dead?: boolean()
        }

  @doc "The segmentation Monty's cows configs name, with its own defaults."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      n_seeds: Keyword.get(options, :n_seeds, 70),
      compactness: Keyword.get(options, :compactness, 10.0),
      max_iter: Keyword.get(options, :max_iter, 10),
      sigma: Keyword.get(options, :sigma, 1.0),
      min_size_factor: Keyword.get(options, :min_size_factor, 0.5),
      max_size_factor: Keyword.get(options, :max_size_factor, 3.0),
      merge_threshold: Keyword.get(options, :merge_threshold, 0.04)
    }
  end

  @doc "The region a view's centre is in, as a mask of ones and zeros."
  @impl true
  @spec call(t(), Monty.Context.t(), [[colour()]]) :: {[[0 | 1]], t()}
  def call(%__MODULE__{} = strategy, _ctx, rgb) do
    region_image = segment_image(strategy, rgb)
    region_colors = extract_region_colors(rgb, region_image)
    adjacency = build_adjacency_graph(region_image, length(region_colors))
    accepted = merge_regions(strategy, region_image, region_colors, adjacency)

    {create_mask(region_image, accepted), strategy}
  end

  @doc """
  The mean colour of each superpixel, in Lab scaled to `[0, 1]`.

  Monty converts the RGB image with `cv2.cvtColor(..., COLOR_RGB2LAB)` and
  divides by 255 — `Images.rgb_to_lab/1` — and then takes the mean per region.
  """
  @spec extract_region_colors([[colour()]], [[non_neg_integer()]]) :: [colour()]
  def extract_region_colors(rgb, region_image) do
    compute_superpixel_mean_colors(region_image, merge_image(rgb))
  end

  # `Images.rgb_to_lab/1` over the whole view is sixteen `f64` operations a
  # pixel for a mean per region, so the kernel answers it where it is loaded.
  # The rescale is `low: 0.0, span: 255.0`: this call converts the camera's own
  # values, not a rescaled view.
  defp merge_image(rgb) do
    if SalienceNif.loaded?() do
      height = length(rgb)
      width = rgb |> hd() |> length()

      packed =
        for row <- rgb, [red, green, blue | _alpha] <- row, into: <<>> do
          <<red::float-little-64, green::float-little-64, blue::float-little-64>>
        end

      raw = SalienceNif.lab_opencv(packed, width * height, 0.0, 255.0)
      plane_bytes = width * height * 8

      [lightness, a, b] =
        for plane <- 0..2 do
          plane_binary = binary_part(raw, plane * plane_bytes, plane_bytes)

          for <<row::binary-size(^width * 8) <- plane_binary>> do
            for <<value::float-little-64 <- row>>, do: value
          end
        end

      weave(lightness, a, b)
    else
      Images.rgb_to_lab(rgb)
    end
  end

  @doc """
  The mean colour of every region of `region_image`, given a coloured image.

  A region that holds no pixel keeps the zeros it started as, which is what
  Monty's `np.zeros` leaves behind.
  """
  @spec compute_superpixel_mean_colors([[non_neg_integer()]], [[colour()]]) :: [colour()]
  def compute_superpixel_mean_colors(region_image, merge_image) do
    sums = accumulate(region_image, merge_image, %{})

    for label <- 0..max(region_max(region_image), 0) do
      case Map.get(sums, label, {0, [0.0, 0.0, 0.0]}) do
        {0, zeros} -> zeros
        {count, sum} -> Enum.map(sum, &(&1 / count))
      end
    end
  end

  # The labels and the colours walked together, by pattern: `Enum.zip/2` over a
  # whole plane goes through the Stream machinery, and this runs for every pixel
  # of the view.
  defp accumulate([], _merge_image, sums), do: sums

  defp accumulate([labels | labels_rows], [colours | colour_rows], sums) do
    accumulate(labels_rows, colour_rows, accumulate_row(labels, colours, sums))
  end

  defp accumulate_row([], _colours, sums), do: sums

  defp accumulate_row([label | labels], [colour | colours], sums) do
    accumulate_row(labels, colours, add_to(sums, label, colour))
  end

  defp add_to(sums, label, colour) do
    case Map.fetch(sums, label) do
      :error -> Map.put(sums, label, {1, first_three(colour)})
      {:ok, {count, sum}} -> Map.put(sums, label, add({count, sum}, colour))
    end
  end

  defp first_three([red, green, blue | _alpha]), do: [red, green, blue]

  # The channel-wise sum, read by pattern.
  defp add({count, [sum_l, sum_a, sum_b]}, [red, green, blue | _alpha]) do
    {count + 1, [sum_l + red, sum_a + green, sum_b + blue]}
  end

  @doc """
  Which regions touch which, as a neighbour set per region.

  Two regions are neighbours when they share an edge — a pixel beside a pixel of
  another label, left or right and above or below. Diagonal contact is not
  contact: a segment that only touches a corner is not the same surface for the
  purpose of the walk.
  """
  @spec build_adjacency_graph([[non_neg_integer()]], non_neg_integer()) ::
          [MapSet.t(non_neg_integer())]
  def build_adjacency_graph(region_image, n_regions) do
    region_image
    |> contacts()
    |> Kernel.++(region_image |> transpose() |> contacts())
    |> Enum.reduce(List.duplicate(MapSet.new(), n_regions), fn {left, right}, adjacency ->
      adjacency
      |> add_neighbour(left, right)
      |> add_neighbour(right, left)
    end)
  end

  # Every pair of labels that meet along a row of the image as given.
  defp contacts(region_image) do
    for row <- region_image,
        {left, right} <- adjacent_pairs(row),
        left != right,
        do: {left, right}
  end

  defp adjacent_pairs([_only]), do: []
  defp adjacent_pairs([left, right | rest]), do: [{left, right} | adjacent_pairs([right | rest])]

  defp add_neighbour(adjacency, label, neighbour) do
    List.update_at(adjacency, label, &MapSet.put(&1, neighbour))
  end

  @doc """
  The regions the walk from the centre of the view took, and their ids.

  A breadth-first walk: a neighbour is taken when its mean colour is within
  `merge_threshold` of the colour of the region the walk reached it from.
  Comparing against the neighbour it came from — rather than against the central
  region — is what lets a surface with a gradient stay one region while a hard
  edge stops the walk.
  """
  @spec merge_regions(t(), [[non_neg_integer()]], [colour()], [MapSet.t()]) ::
          MapSet.t(non_neg_integer())
  def merge_regions(%__MODULE__{} = strategy, region_image, region_colors, adjacency) do
    central = region_image |> at_centre() |> round()

    walk(
      [central],
      MapSet.new([central]),
      MapSet.new([central]),
      strategy.merge_threshold,
      region_colors,
      adjacency
    )
  end

  defp walk([], _seen, accepted, _threshold, _region_colors, _adjacency), do: accepted

  defp walk([current | queue], seen, accepted, threshold, region_colors, adjacency) do
    {queue, seen, accepted} =
      adjacency
      |> Enum.at(current)
      |> Enum.reduce({queue, seen, accepted}, fn neighbour, {queue, seen, accepted} = walk ->
        cond do
          MapSet.member?(seen, neighbour) ->
            walk

          close?(region_colors, current, neighbour, threshold) ->
            {queue ++ [neighbour], MapSet.put(seen, neighbour), MapSet.put(accepted, neighbour)}

          true ->
            {queue, MapSet.put(seen, neighbour), accepted}
        end
      end)

    walk(queue, seen, accepted, threshold, region_colors, adjacency)
  end

  # `np.linalg.norm(region_colors[current] - region_colors[neighbour])`, which is
  # the straight-line distance in Lab, compared with `<`.
  defp close?(region_colors, current, neighbour, threshold) do
    region_colors
    |> Enum.at(current)
    |> Enum.zip(Enum.at(region_colors, neighbour))
    |> Enum.reduce(0.0, fn {a, b}, sum -> sum + (a - b) * (a - b) end)
    |> :math.sqrt()
    |> Kernel.<(threshold)
  end

  @doc "The mask of the regions the walk accepted: one where it reached."
  @spec create_mask([[non_neg_integer()]], MapSet.t(non_neg_integer())) :: [[0 | 1]]
  def create_mask(region_image, accepted_regions) do
    for row <- region_image do
      for label <- row, do: if(MapSet.member?(accepted_regions, label), do: 1, else: 0)
    end
  end

  # -- SLIC -----------------------------------------------------------------

  @doc """
  The view cut into superpixels, one label per pixel.

  `skimage.segmentation.slic` with the parameters Monty's class passes, in its
  own order:

    1. the colour is read to `[0, 1]` and rescaled to fill it, so `compactness`
       means the same thing whatever the camera's range;
    2. it is converted to Lab, which is the space the k-means runs in;
    3. it is smoothed with a Gaussian of `sigma`, so one noisy pixel does not
       become a superpixel of its own;
    4. seeds go on a regular grid, and each axis's step is that grid's step;
    5. k-means: every pixel takes the nearest seed within twice the step, where
       the distance is colour distance plus `1/step²` times squared pixel
       distance;
    6. and a connectivity pass makes each label one connected blob, absorbing
       blobs smaller than half the nominal segment size.
  """
  @spec segment_image(t(), [[colour()]]) :: [[non_neg_integer()]]
  def segment_image(%__MODULE__{} = strategy, rgb) do
    if SalienceNif.loaded?(),
      do: segment(strategy, rgb, :native),
      else: segment(strategy, rgb, :reference)
  end

  @doc """
  The same segmentation with the Elixir k-means, whatever is loaded.

  The reference the native kernel is held to by a parity case, and what runs
  where the crate was never built. The rest of the algorithm — the colour
  conversion, the Gaussian, the connectivity pass — is shared.
  """
  @spec segment_image_reference(t(), [[colour()]]) :: [[non_neg_integer()]]
  def segment_image_reference(%__MODULE__{} = strategy, rgb),
    do: segment(strategy, rgb, :reference)

  defp segment(%__MODULE__{} = strategy, rgb, k_means) do
    height = length(rgb)
    width = length(hd(rgb))
    {steps, seeds} = grid_centroids({1, height, width}, strategy.n_seeds)

    lab =
      rgb
      |> prepared_lab()
      |> smooth(strategy.sigma)

    flat_factor = 1.0 / strategy.compactness

    {labels, _seeds} =
      labels(lab, width, flat_factor, seeds, steps, strategy.max_iter, k_means)

    segment_size = height * width / length(seeds)

    labels
    |> enforce_connectivity(
      trunc(strategy.min_size_factor * segment_size),
      trunc(strategy.max_size_factor * segment_size),
      width,
      height,
      k_means
    )
    |> to_rows(height, width)
  end

  # `img_as_float`, the wrapper's rescale to `[0, 1]` over every value, and
  # `rgb2lab`, whose Lab this answers: `L` in `0..100`, `a` and `b` unshifted.
  #
  # Three planes either way: the smoothing blurs each channel on its own and the
  # k-means interleaves them into its binary, so pixel rows exist only on the
  # reference path.
  defp prepared_lab(rgb) do
    values =
      for row <- rgb, [_alpha | _rest] = pixel <- row, value <- rescale_values(pixel), do: value

    low = Enum.min(values)
    high = Enum.max(values)
    span = if high == low, do: 1.0, else: high - low

    if SalienceNif.loaded?(),
      do: lab_by_kernel(rgb, low, span),
      else: lab_reference(rgb, low, span)
  end

  # The whole conversion in one call: sixteen operations a pixel in Elixir, over
  # 65 536 pixels and three channels, which was the largest single per-pixel
  # chain left in a step.
  defp lab_by_kernel(rgb, low, span) do
    height = length(rgb)
    width = rgb |> hd() |> length()

    packed =
      for row <- rgb, [red, green, blue | _alpha] <- row, into: <<>> do
        <<red::float-little-64, green::float-little-64, blue::float-little-64>>
      end

    {width, height, raw} = {width, height, SalienceNif.lab(packed, width * height, low, span)}
    plane_bytes = width * height * 8

    for plane <- 0..2 do
      for <<row::binary-size(^width * 8) <- binary_part(raw, plane * plane_bytes, plane_bytes)>> do
        for <<value::float-little-64 <- row>>, do: value
      end
    end
  end

  defp lab_reference(rgb, low, span) do
    rgb
    |> Enum.map(fn row -> for [_alpha | _rest] = pixel <- row, do: rescale(pixel, low, span) end)
    |> Images.rgb_to_lab()
    |> Enum.map(fn row -> Enum.map(row, &skimage_lab/1) end)
    |> planes()
  end

  defp rescale_values([red, green, blue | _alpha]), do: [red, green, blue]

  defp rescale([red, green, blue | _alpha], low, span),
    do: [(red - low) / span * 255.0, (green - low) / span * 255.0, (blue - low) / span * 255.0]

  # `Images.rgb_to_lab/1` answers the OpenCV scaling divided by 255 — `L/100`,
  # `(a + 128)/255`, `(b + 128)/255` — and `skimage` answers `L`, `a`, `b`.
  defp skimage_lab([lightness, a, b]),
    do: [lightness * 100.0, a * 255.0 - 128.0, b * 255.0 - 128.0]

  # `gaussian(image, sigma=[sigma, sigma, 0], mode="reflect")` on a view one
  # pixel deep: each colour channel smoothed on its own, so no colour bleeds into
  # another.
  # The three channels are separated in one pass and woven back in one pass.
  # Apart, `plane(lab, channel)` read every pixel's list from the front —
  # `Enum.at/2` on a list is a slice — and the two `Enum.zip_with` calls after
  # the blurs built the Stream machinery for every row and then every pixel.
  # Three planes, not pixel rows: the k-means interleaves them into its binary,
  # and the reference's loop weaves them back into pixels itself — so nothing
  # is split only to be joined again.
  defp smooth(lab, sigma) when is_number(sigma) and sigma > 0 do
    Enum.map(lab, &Images.gaussian_blur(&1, sigma, @truncate))
  end

  defp smooth(lab, _no_smoothing), do: lab

  defp planes(lab) do
    {lightness, a, b} =
      Enum.reduce(lab, {[], [], []}, fn row, {lightness, a, b} ->
        {l_row, a_row, b_row} = split_row(row)
        {[l_row | lightness], [a_row | a], [b_row | b]}
      end)

    [lightness, a, b] |> Enum.map(&Enum.reverse/1)
  end

  defp split_row(row) do
    Enum.reduce(row, {[], [], []}, fn
      [lightness, a, b], {l_row, a_row, b_row} -> {[lightness | l_row], [a | a_row], [b | b_row]}
    end)
    |> then(fn {l_row, a_row, b_row} ->
      {Enum.reverse(l_row), Enum.reverse(a_row), Enum.reverse(b_row)}
    end)
  end

  defp weave(lightness, a, b), do: weave_rows(lightness, a, b, [])

  defp weave_rows([], _a, _b, acc), do: Enum.reverse(acc)

  defp weave_rows([lightness | lightnesses], [a | as], [b | bs], acc),
    do: weave_rows(lightnesses, as, bs, [weave_pixels(lightness, a, b, []) | acc])

  defp weave_pixels([], _a, _b, acc), do: Enum.reverse(acc)

  defp weave_pixels([lightness | lightnesses], [a | as], [b | bs], acc),
    do: weave_pixels(lightnesses, as, bs, [[lightness, a, b] | acc])

  # A pixel per index, row-major (`index = row * width + column`), each already
  # scaled by `1/compactness` as the wrapper scales the whole image.
  #
  # The colour is a tuple, not a three-element list: the k-means compares the
  # colour of every pixel against every seed whose window reaches it — 7.8
  # million comparisons on a 256-square view — and a tuple reads its components
  # with `elem/2` while a list is walked and zipped, which was 31 million
  # `Enum.zip_list/3` calls and a quarter of the step's allocation budget.
  defp pixels(lab, factor) do
    lab
    |> Enum.concat()
    |> Enum.map(fn [lightness, a, b] -> {lightness * factor, a * factor, b * factor} end)
    |> List.to_tuple()
  end

  # -- the seed grid --------------------------------------------------------

  # `regular_grid`: points spaced by the nth root of the space, with an axis that
  # cannot hold a step of its own pinned at one.
  defp grid_centroids({depth, height, width}, n_seeds) do
    slices = grid_slices([depth, height, width], n_seeds)
    steps = for {_start, step} <- slices, do: step * 1.0

    seeds =
      for z <- indices(depth, Enum.at(slices, 0)),
          y <- indices(height, Enum.at(slices, 1)),
          x <- indices(width, Enum.at(slices, 2)) do
        %{z: z * 1.0, y: y * 1.0, x: x * 1.0, colour: {0.0, 0.0, 0.0}, dead?: false}
      end

    {steps, seeds}
  end

  defp indices(size, {start, step}), do: Enum.to_list(start..(size - 1)//step)

  defp grid_slices(shape, n_points) do
    if Enum.product(shape) <= n_points do
      List.duplicate({0, 1}, length(shape))
    else
      steps =
        List.duplicate(root(Enum.product(shape) / n_points, length(shape)), length(shape))
        |> fit_steps(Enum.sort(shape), n_points)

      Enum.map(steps, fn step -> {div(trunc(Float.floor(step)), 2), round(step)} end)
    end
  end

  defp root(value, dimensions), do: :math.pow(value, 1.0 / dimensions)

  defp fit_steps(steps, sorted_shape, n_points) do
    if Enum.any?(Enum.zip(sorted_shape, steps), fn {size, step} -> size < step end),
      do: narrow(steps, sorted_shape, n_points, 0),
      else: steps
  end

  # The axes from `axis` on share what is left of the space, once `axis` itself
  # has been pinned to its own size.
  defp narrow(steps, sorted_shape, n_points, axis) do
    dimensions = length(steps)

    steps =
      steps
      |> List.replace_at(axis, Enum.at(sorted_shape, axis) * 1.0)
      |> share_the_rest(axis, sorted_shape, n_points, dimensions)

    fits? = Enum.all?(Enum.zip(sorted_shape, steps), fn {size, step} -> size >= step end)

    if fits? or axis + 1 >= dimensions,
      do: steps,
      else: narrow(steps, sorted_shape, n_points, axis + 1)
  end

  defp share_the_rest(steps, axis, sorted_shape, n_points, dimensions) do
    remaining = sorted_shape |> Enum.drop(axis + 1) |> Enum.product()
    step = root(remaining / n_points, dimensions - axis - 1)

    Enum.with_index(steps)
    |> Enum.map(fn {value, index} -> if index > axis, do: step, else: value end)
  end

  defp window_steps(steps), do: Enum.map(steps, &trunc/1)

  # -- k-means --------------------------------------------------------------

  # The label field, from the kernel or from the loop below. The kernel answers
  # the same numbers — the parity case compares the two — as one `u32` per pixel
  # in one binary, because the work is 7.8 million comparisons on a 256-square
  # view and encoding them as lists on the way in and out was a tenth of it.
  defp labels(lab, width, factor, seeds, steps, max_iter, :native) do
    window = window_steps(steps)
    flat = interleaved(lab, factor)

    packed =
      for %{y: y, x: x, colour: {l, a, b}} <- seeds, into: <<>> do
        <<y::float-little-64, x::float-little-64, l::float-little-64, a::float-little-64,
          b::float-little-64>>
      end

    flat
    |> SalienceNif.slic_labels(
      width,
      packed,
      Enum.at(window, 1),
      Enum.at(window, 2),
      1.0 / :math.pow(Enum.max(steps), 2),
      max_iter
    )
    |> then(&{&1, seeds})
  end

  defp labels(lab, width, factor, seeds, steps, max_iter, :reference) do
    [lightness, a, b] = lab

    {labels, seeds} =
      lightness
      |> weave(a, b)
      |> pixels(factor)
      |> k_means(width, seeds, steps, max_iter)

    {packed_labels(labels), seeds}
  end

  # The three channels interleaved and scaled, as one binary — what the kernel
  # reads. Built straight from the planes: `pixels/2`'s 65 536 `{l, a, b}`
  # tuples exist because the reference's loop compares tuples, and packing them
  # again afterwards wrote every value twice.
  defp interleaved([lightness, a, b], factor) do
    lightness = Enum.concat(lightness)
    a = Enum.concat(a)
    b = Enum.concat(b)

    interleaved(lightness, a, b, factor, [])
  end

  defp interleaved([], _a, _b, _factor, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp interleaved([lightness | lightnesses], [a | as], [b | bs], factor, acc) do
    acc = [
      <<lightness * factor::float-little-64, a * factor::float-little-64,
        b * factor::float-little-64>>
      | acc
    ]

    interleaved(lightnesses, as, bs, factor, acc)
  end

  # One label field, one shape downstream of the k-means: one little-endian
  # `u32` per pixel. The loop above works on an `:array`, so this is where the
  # reference path pays for it — which is what makes the two paths comparable
  # stage by stage.
  defp packed_labels(labels) do
    for index <- 0..(:array.size(labels) - 1), into: <<>> do
      <<:array.get(index, labels)::little-32>>
    end
  end

  defp unpacked_labels(binary) do
    labels = for <<label::little-32 <- binary>>, do: label
    :array.from_list(labels, 0)
  end

  defp k_means(pixels, width, seeds, steps, max_iter) do
    iterate(pixels, width, seeds, steps, max_iter, :array.new(tuple_size(pixels), default: 0))
  end

  defp iterate(_pixels, _width, seeds, _steps, 0, labels), do: {labels, seeds}

  defp iterate(pixels, width, seeds, steps, max_iter, labels) do
    {labels, changed?} = claim_all(pixels, width, seeds, steps, labels)

    if changed? do
      {seeds, labels} = recentre(pixels, width, seeds, labels)
      iterate(pixels, width, seeds, steps, max_iter - 1, labels)
    else
      {labels, seeds}
    end
  end

  defp claim_all(pixels, width, seeds, steps, labels) do
    {labels, _distances, changed?} =
      seeds
      |> Enum.with_index()
      |> Enum.reduce(
        {labels, :array.new(tuple_size(pixels), default: @unclaimed), false},
        fn {seed, k}, {labels, distances, changed?} ->
          claim(pixels, width, seed, k, steps, labels, distances, changed?)
        end
      )

    {labels, changed?}
  end

  # One seed's turn: every pixel within twice the step takes it when that is
  # nearer than anything else so far.
  defp claim(_pixels, _width, %{dead?: true}, _k, _steps, labels, distances, changed?),
    do: {labels, distances, changed?}

  defp claim(pixels, width, seed, k, steps, labels, distances, changed?) do
    height = div(tuple_size(pixels), width)
    window = window_steps(steps)
    # A seed's window is the same for every pixel in it, so the scale that turns
    # squared pixel distance into the wrapper's units is worked out once here.
    spatial_factor = 1.0 / :math.pow(Enum.max(steps), 2)

    for y <- window_range(seed.y, Enum.at(window, 1), height),
        x <- window_range(seed.x, Enum.at(window, 2), width),
        reduce: {labels, distances, changed?} do
      acc -> claim_pixel(pixels, width, seed, k, spatial_factor, y, x, acc)
    end
  end

  # The window is `[centre - 2*step, centre + 2*step]`, clipped to the image.
  defp window_range(centre, step, size) do
    low = max(trunc(centre) - 2 * step, 0)
    high = min(trunc(centre) + 2 * step + 1, size) - 1

    if high < low, do: [], else: Enum.to_list(low..high)
  end

  defp claim_pixel(pixels, width, seed, k, spatial_factor, y, x, {labels, distances, changed?}) do
    index = y * width + x
    colour = elem(pixels, index)

    # A view is one pixel deep, so `skimage`'s `z` term is nought either way.
    # Written as a product rather than `:math.pow(_, 2)` because the native
    # kernel does the same: one definition of the number, two implementations.
    dy = seed.y - y
    dx = seed.x - x
    spatial = (dy * dy + dx * dx) * spatial_factor

    distance = spatial + squared_distance(colour, seed.colour)

    if :array.get(index, distances) > distance do
      {:array.set(index, k, labels), :array.set(index, distance, distances), true}
    else
      {labels, distances, changed?}
    end
  end

  # The same three differences, summed in the same order (`l`, then `a`, then
  # `b`) as `Enum.zip/2 |> Enum.reduce(0.0, …)`, which allocated two tuples and
  # a float for every one of the 7.8 million comparisons a view costs.
  defp squared_distance({l1, a1, b1}, {l2, a2, b2}) do
    dl = l1 - l2
    da = a1 - a2
    db = b1 - b2
    dl * dl + da * da + db * db
  end

  # Every centroid becomes the mean of the pixels it won. A centroid that won
  # none is dead: `skimage` divides by zero and carries a NaN that can never
  # claim a pixel again, which is the same thing without a NaN.
  defp recentre(pixels, width, seeds, labels) do
    totals =
      Enum.reduce(0..(tuple_size(pixels) - 1), %{}, fn index, totals ->
        key = :array.get(index, labels)

        Map.update(
          totals,
          key,
          {1, div(index, width) * 1.0, rem(index, width) * 1.0, elem(pixels, index)},
          &sum_member(&1, index, width, elem(pixels, index))
        )
      end)

    seeds =
      seeds
      |> Enum.with_index()
      |> Enum.map(fn {seed, k} ->
        case Map.fetch(totals, k) do
          :error ->
            %{seed | dead?: true}

          {:ok, {count, y, x, {l, a, b}}} ->
            %{seed | y: y / count, x: x / count, colour: {l / count, a / count, b / count}}
        end
      end)

    {seeds, labels}
  end

  defp sum_member({count, y, x, {l, a, b}}, index, width, {pl, pa, pb}) do
    {count + 1, y + div(index, width), x + rem(index, width), {l + pl, a + pa, b + pb}}
  end

  # -- connectivity ---------------------------------------------------------

  # `_enforce_label_connectivity_cython`: in raster order, a breadth-first search
  # for each blob, and a blob smaller than `min_size` handed to the neighbour it
  # touches. A blob that reaches `max_size` keeps a label of its own.
  defp enforce_connectivity(labels, min_size, max_size, width, height, :native),
    do: SalienceNif.enforce_connectivity(labels, width, height, min_size, max_size)

  defp enforce_connectivity(labels, min_size, max_size, width, _height, :reference) do
    labels
    |> unpacked_labels()
    |> enforce_connectivity_reference(min_size, max_size, width)
    |> packed_labels()
  end

  @doc """
  The Elixir connectivity pass: the reference the native kernel is held to.

  Kept public because it is what a parity case compares against, and what runs
  where the crate was never built.
  """
  @spec enforce_connectivity_reference(
          term(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          term()
  def enforce_connectivity_reference(labels, min_size, max_size, width) do
    size = :array.size(labels)

    {connected, _next_label} =
      Enum.reduce(
        0..(size - 1),
        {:array.new(size, default: -1), 0},
        fn
          index, {connected, next_label} ->
            if :array.get(index, connected) > -1,
              do: {connected, next_label},
              else: grow(labels, connected, index, next_label, min_size, max_size, width)
        end
      )

    connected
  end

  defp grow(labels, connected, index, new_label, min_size, max_size, width) do
    state = %{
      labels: labels,
      width: width,
      label: :array.get(index, labels),
      new_label: new_label,
      max_size: max_size,
      connected: :array.set(index, new_label, connected),
      coordinates: [index],
      queue: [index],
      adjacent: new_label
    }

    state = search(state)

    if length(state.coordinates) < min_size,
      do: {absorb(state.connected, state.coordinates, state.adjacent), new_label},
      else: {state.connected, new_label + 1}
  end

  # The queue holds the pixels still to look from; `coordinates` holds every
  # pixel of the blob so far, which is what its size means here.
  defp search(%{queue: []} = state), do: state

  defp search(%{coordinates: coordinates, max_size: max_size} = state)
       when length(coordinates) >= max_size,
       do: state

  defp search(state) do
    [from | rest] = state.queue

    state
    |> Map.put(:queue, rest)
    |> then(fn state ->
      Enum.reduce(neighbours(from, state.width), state, &visit/2)
    end)
    |> search()
  end

  defp visit(neighbour, state) do
    label = :array.get(neighbour, state.labels)

    claimed = :array.get(neighbour, state.connected)

    cond do
      claimed == -1 and label == state.label ->
        %{
          state
          | connected: :array.set(neighbour, state.new_label, state.connected),
            coordinates: state.coordinates ++ [neighbour],
            queue: state.queue ++ [neighbour]
        }

      claimed > -1 and claimed != state.new_label ->
        %{state | adjacent: claimed}

      true ->
        state
    end
  end

  # `+x, -x, +y, -y` in that order: `skimage`'s order with the two z neighbours
  # dropped, because a view is one pixel deep.
  defp neighbours(index, width) do
    row = div(index, width)
    column = rem(index, width)

    [{0, 1}, {0, -1}, {1, 0}, {-1, 0}]
    |> Enum.map(fn {d_row, d_column} -> {row + d_row, column + d_column} end)
    |> Enum.filter(fn {r, c} -> r >= 0 and r < width and c >= 0 and c < width end)
    |> Enum.map(fn {r, c} -> r * width + c end)
  end

  defp absorb(connected, coordinates, adjacent) do
    Enum.reduce(coordinates, connected, fn index, connected ->
      :array.set(index, adjacent, connected)
    end)
  end

  # -- answers --------------------------------------------------------------

  defp to_rows(labels, _height, width) do
    for <<row::binary-size(^width * 4) <- labels>> do
      for <<label::little-32 <- row>>, do: label
    end
  end

  defp transpose([]), do: []

  defp transpose([first | _rest] = rows) do
    for column <- 0..(length(first) - 1), do: Enum.map(rows, &Enum.at(&1, column))
  end

  defp region_max(region_image), do: region_image |> List.flatten() |> Enum.max(fn -> 0 end)

  defp at_centre(region_image) do
    row = Enum.at(region_image, div(length(region_image), 2))
    Enum.at(row, div(length(row), 2))
  end
end
