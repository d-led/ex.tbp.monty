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
    compute_superpixel_mean_colors(region_image, Images.rgb_to_lab(rgb))
  end

  @doc """
  The mean colour of every region of `region_image`, given a coloured image.

  A region that holds no pixel keeps the zeros it started as, which is what
  Monty's `np.zeros` leaves behind.
  """
  @spec compute_superpixel_mean_colors([[non_neg_integer()]], [[colour()]]) :: [colour()]
  def compute_superpixel_mean_colors(region_image, merge_image) do
    sums =
      region_image
      |> Enum.zip(merge_image)
      |> Enum.reduce(%{}, fn {labels, colours}, sums ->
        labels
        |> Enum.zip(colours)
        |> Enum.reduce(sums, fn {label, colour}, sums ->
          Map.update(sums, label, {1, Enum.take(colour, 3)}, &add(&1, colour))
        end)
      end)

    for label <- 0..max(region_max(region_image), 0) do
      case Map.get(sums, label, {0, [0.0, 0.0, 0.0]}) do
        {0, zeros} -> zeros
        {count, sum} -> Enum.map(sum, &(&1 / count))
      end
    end
  end

  defp add({count, sum}, colour) do
    {count + 1, Enum.zip_with(sum, Enum.take(colour, 3), fn a, b -> a + b end)}
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
    height = length(rgb)
    width = length(hd(rgb))
    {steps, seeds} = grid_centroids({1, height, width}, strategy.n_seeds)

    pixels =
      rgb
      |> prepared_lab()
      |> smooth(strategy.sigma)
      |> pixels(1.0 / strategy.compactness)

    {labels, _seeds} = k_means(pixels, width, seeds, steps, strategy.max_iter)
    segment_size = height * width / length(seeds)

    labels
    |> enforce_connectivity(
      trunc(strategy.min_size_factor * segment_size),
      trunc(strategy.max_size_factor * segment_size),
      width
    )
    |> to_rows(height, width)
  end

  # `img_as_float`, the wrapper's rescale to `[0, 1]` over every value, and
  # `rgb2lab`, whose Lab this answers: `L` in `0..100`, `a` and `b` unshifted.
  defp prepared_lab(rgb) do
    pixels = for row <- rgb, pixel <- row, do: Enum.take(pixel, 3)
    values = List.flatten(pixels)
    low = Enum.min(values)
    high = Enum.max(values)
    span = if high == low, do: 1.0, else: high - low

    rgb
    |> Enum.map(fn row ->
      Enum.map(row, fn pixel -> Enum.map(Enum.take(pixel, 3), &((&1 - low) / span * 255.0)) end)
    end)
    |> Images.rgb_to_lab()
    |> Enum.map(fn row -> Enum.map(row, &skimage_lab/1) end)
  end

  # `Images.rgb_to_lab/1` answers the OpenCV scaling divided by 255 — `L/100`,
  # `(a + 128)/255`, `(b + 128)/255` — and `skimage` answers `L`, `a`, `b`.
  defp skimage_lab([lightness, a, b]),
    do: [lightness * 100.0, a * 255.0 - 128.0, b * 255.0 - 128.0]

  # `gaussian(image, sigma=[sigma, sigma, 0], mode="reflect")` on a view one
  # pixel deep: each colour channel smoothed on its own, so no colour bleeds into
  # another.
  defp smooth(lab, sigma) when is_number(sigma) and sigma > 0 do
    [0, 1, 2]
    |> Enum.map(fn channel -> lab |> plane(channel) |> Images.gaussian_blur(sigma, @truncate) end)
    |> Enum.zip_with(fn channel_rows -> channel_rows end)
    |> Enum.map(fn channel_rows -> Enum.zip_with(channel_rows, fn pixel -> pixel end) end)
  end

  defp smooth(lab, _no_smoothing), do: lab

  defp plane(lab, channel),
    do: for(row <- lab, do: for(pixel <- row, do: Enum.at(pixel, channel)))

  # A pixel per index, row-major (`index = row * width + column`), each already
  # scaled by `1/compactness` as the wrapper scales the whole image.
  defp pixels(lab, factor) do
    lab
    |> Enum.concat()
    |> Enum.map(fn pixel -> Enum.map(pixel, &(&1 * factor)) end)
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
        %{z: z * 1.0, y: y * 1.0, x: x * 1.0, colour: [0.0, 0.0, 0.0], dead?: false}
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

    for y <- window_range(seed.y, Enum.at(window, 1), height),
        x <- window_range(seed.x, Enum.at(window, 2), width),
        reduce: {labels, distances, changed?} do
      acc -> claim_pixel(pixels, width, seed, k, steps, y, x, acc)
    end
  end

  # The window is `[centre - 2*step, centre + 2*step]`, clipped to the image.
  defp window_range(centre, step, size) do
    low = max(trunc(centre) - 2 * step, 0)
    high = min(trunc(centre) + 2 * step + 1, size) - 1

    if high < low, do: [], else: Enum.to_list(low..high)
  end

  defp claim_pixel(pixels, width, seed, k, steps, y, x, {labels, distances, changed?}) do
    index = y * width + x
    colour = elem(pixels, index)

    # A view is one pixel deep, so `skimage`'s `z` term is nought either way.
    spatial =
      (:math.pow(seed.y - y, 2) + :math.pow(seed.x - x, 2)) *
        (1.0 / :math.pow(Enum.max(steps), 2))

    distance = spatial + squared_distance(colour, seed.colour)

    if :array.get(index, distances) > distance do
      {:array.set(index, k, labels), :array.set(index, distance, distances), true}
    else
      {labels, distances, changed?}
    end
  end

  defp squared_distance(left, right) do
    left |> Enum.zip(right) |> Enum.reduce(0.0, fn {a, b}, sum -> sum + (a - b) * (a - b) end)
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

          {:ok, {count, y, x, colour}} ->
            %{
              seed
              | y: y / count,
                x: x / count,
                colour: Enum.map(colour, &(&1 / count))
            }
        end
      end)

    {seeds, labels}
  end

  defp sum_member({count, y, x, colour}, index, width, pixel) do
    {count + 1, y + div(index, width), x + rem(index, width),
     Enum.zip_with(colour, pixel, fn a, b -> a + b end)}
  end

  # -- connectivity ---------------------------------------------------------

  # `_enforce_label_connectivity_cython`: in raster order, a breadth-first search
  # for each blob, and a blob smaller than `min_size` handed to the neighbour it
  # touches. A blob that reaches `max_size` keeps a label of its own.
  defp enforce_connectivity(labels, min_size, max_size, width) do
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

  defp to_rows(labels, height, width) do
    for row <- 0..(height - 1) do
      for column <- 0..(width - 1), do: :array.get(row * width + column, labels)
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
