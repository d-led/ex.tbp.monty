defmodule Monty.Frameworks.Utils.SensorProcessing do
  @moduledoc """
  What a sensor module makes of a depth image.

  Mirrors `tbp/monty/frameworks/utils/sensor_processing.py`, which is a file of
  functions rather than classes — the curvature estimation, the patch
  normalisation, the surface normalisation. What is ported so far:

    * `log_sign/1` — **ported**: a signed logarithm, which is how a curvature
      becomes a feature a learning module can average;
    * `pixel_dist_to_center/3`, `weight_matrix/3`, `center_neighbors/3` —
      **ported**: which pixels of a patch take part in a fit, and how much;
    * `surface_normal_total_least_squares/4` — **ported**: the plane through
      those pixels, whose least-spread direction is the surface normal;
    * `principal_curvatures/4` — **ported**: the quadric fitted to the same
      pixels, whose shape operator answers the two principal curvatures and
      their directions.

  Not ported: `surface_normal_naive/2` and `surface_normal_ordinary_least_squares/4`
  (Monty defaults to total least squares), `directional_curvature/5` and the
  arc-length helpers, and the point-pair features.

  And one function that file does not have but its module uses:

    * `rgb2hsv/1` — reproduced from `skimage.color.rgb2hsv`, which is what
      `CameraSM` calls to turn the centre pixel into Monty's `hsv` feature. It
      is here rather than in the simulator because a simulator that invented its
      own hue would train a learning module on a different feature from Monty's.

  The two estimators take a point cloud in the shape the depth-to-points
  transform leaves it: one row per pixel, `[x, y, z, on_surface]`, in Monty's
  order — so `center_id` is a row index and a patch's width is the square root of
  its row count. `Monty.Simulators.Synthetic.SensorModule` still reads the
  geometry a world reports rather than calling these; wiring them in is a step of
  its own.
  """

  @doc """
  A signed logarithm: `sign(x) * ln(|x| + 1)`.

  Monty's `log_sign`, which scales a curvature without losing which way the
  surface bends — a convex surface has negative principal curvatures, and a
  plain logarithm would lose that. The `+ 1` keeps values near zero from
  running off to negative infinity.

      iex> Monty.Frameworks.Utils.SensorProcessing.log_sign(0.0)
      0.0

      iex> Monty.Frameworks.Utils.SensorProcessing.log_sign(-1.0)
      -0.6931471805599453
  """
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.LinearAlgebra
  alias Monty.Geometry.Rotation

  # How wide a neighbourhood each fit uses, as a fraction of the patch: Monty's
  # own defaults, 3.2 for the plane and 2.13 for the quadric.
  @neighbor_patch_frac 3.2
  @curvature_patch_frac 2.13

  @spec log_sign(number() | [number()]) :: float() | [float()]
  def log_sign(value) when is_number(value) do
    sign = if value < 0, do: -1.0, else: 1.0
    sign * :math.log(abs(value) + 1.0)
  end

  def log_sign(values) when is_list(values), do: Enum.map(values, &log_sign/1)

  @doc """
  One `rgb` pixel as hue, saturation and value, each in `0..1`.

  `skimage.color.rgb2hsv`, whose conventions this follows: hue is the angle
  round the colour wheel divided by 360, so red is 0, green a third and blue two
  thirds; saturation is how far the colour is from grey; value is the brightest
  channel. A grey pixel has no hue to speak of and skimage answers 0 for it, as
  this does.

      iex> Monty.Frameworks.Utils.SensorProcessing.rgb2hsv([1.0, 0.0, 0.0])
      [0.0, 1.0, 1.0]
  """
  @spec rgb2hsv([number()]) :: [float()]
  def rgb2hsv([red, green, blue]) do
    brightest = max(red, max(green, blue))
    darkest = min(red, min(green, blue))
    delta = brightest - darkest

    [hue(red, green, blue, brightest, delta), saturation(brightest, delta), brightest]
  end

  defp saturation(brightest, _delta) when brightest == 0.0, do: 0.0

  defp saturation(brightest, delta), do: delta / brightest

  # No spread between the channels means no hue: the pixel is grey.
  defp hue(_red, _green, _blue, _brightest, delta) when delta == 0.0, do: 0.0

  defp hue(red, green, blue, brightest, delta) do
    degrees =
      cond do
        brightest == red -> 60.0 * (green - blue) / delta
        brightest == green -> 60.0 * ((blue - red) / delta + 2.0)
        true -> 60.0 * ((red - green) / delta + 4.0)
      end

    # A red-dominant pixel can come out negative: the wheel wraps at red.
    wrap(degrees / 360.0)
  end

  defp wrap(hue) when hue < 0.0, do: wrap(hue + 1.0)
  defp wrap(hue) when hue >= 1.0, do: wrap(hue - 1.0)
  defp wrap(hue), do: hue

  @doc """
  The surface normal at the middle of a patch, and whether it is worth having.

  Total least squares: the plane the neighbourhood's points lie in least badly,
  whose normal direction is the one with the least spread. The viewing direction
  only decides which way along that line the answer points — Monty aligns it
  with the camera, so a normal always faces the sensor that saw it.

  Options: `:neighbor_patch_frac`, how wide the neighbourhood is as a fraction
  of the patch's width.

  Answers `{[0.0, 0.0, 1.0], false}` when the middle pixel is not on the object,
  or when the neighbourhood is too small or too degenerate to fit.
  """
  @spec surface_normal_total_least_squares(
          [[float()]],
          non_neg_integer(),
          [float()],
          keyword()
        ) :: {[float()], boolean()}
  def surface_normal_total_least_squares(point_cloud, center_id, view_direction, options \\ []) do
    neighbors =
      center_neighbors(
        point_cloud,
        center_id,
        Keyword.get(options, :neighbor_patch_frac, @neighbor_patch_frac)
      )

    with true <- on_object?(point_cloud, center_id),
         [_, _, _ | _rest] <- neighbors,
         {normal, true} <- plane_normal(neighbors) do
      {align_with_view(normal, view_direction), true}
    else
      _not_defined -> {[0.0, 0.0, 1.0], false}
    end
  end

  # The least-spread direction of the neighbourhood.
  #
  # Monty's scatter matrix is reproduced as it stands: `p_mean` is the mean
  # divided by the count a second time, so the mean's outer product is
  # under-subtracted and the matrix is inflated along the neighbourhood's own
  # offset (`docs/monty-bugs.md` §1.9). The points are already relative to the
  # middle pixel, so that offset is small and the estimate is barely moved; a
  # one-sided neighbourhood is where the difference shows.
  defp plane_normal(points) do
    count = length(points)
    mean = points |> transpose() |> Enum.map(&(Enum.sum(&1) / count))
    offset = Enum.map(mean, &(&1 / count))

    scatter =
      for row <- 0..2 do
        for column <- 0..2 do
          # `1/n · Xᵀ X − p_mean · p_meanᵀ`.
          Enum.sum(for point <- points, do: Enum.at(point, row) * Enum.at(point, column)) / count -
            Enum.at(offset, row) * Enum.at(offset, column)
        end
      end

    case LinearAlgebra.symmetric_eigen(scatter) do
      [{_value, normal} | _rest] -> {normal, true}
      [] -> {[0.0, 0.0, 1.0], false}
    end
  end

  defp align_with_view(normal, view_direction) do
    if SpatialArithmetics.dot(view_direction, normal) < 0.0,
      do: SpatialArithmetics.scale(normal, -1.0),
      else: normal
  end

  @doc """
  The two principal curvatures at the middle of a patch, and their directions.

  A quadric is fitted to the patch's points in the frame of the surface normal —
  `n = a u² + b v² + c u v + d u + e v + f` — and the shape operator that falls
  out of it answers the curvatures. Negative means convex, as Monty's are, and
  the largest is answered first.

  Options: `:neighbor_patch_frac` (the width of the Gaussian that weights the
  fit), `:weighted` and `:fit_intercept`, as Monty's own are.

  Answers `{k1, k2, dir1, dir2, valid?}`: zeros and zero vectors when the middle
  pixel is not on the object or the fit has too little to work with.
  """
  @spec principal_curvatures([[float()]], non_neg_integer(), [float()], keyword()) ::
          {float(), float(), [float()], [float()], boolean()}
  def principal_curvatures(point_cloud, center_id, normal, options \\ []) do
    if on_object?(point_cloud, center_id) do
      case curvature_fit(point_cloud, center_id, normal, options) do
        {:ok, k1, k2, direction_1, direction_2} -> {k1, k2, direction_1, direction_2, true}
        :not_defined -> undefined_curvatures()
      end
    else
      undefined_curvatures()
    end
  end

  defp undefined_curvatures, do: {0.0, 0.0, [0.0, 0.0, 0.0], [0.0, 0.0, 0.0], false}

  @doc """
  Every pixel's distance from the middle of the patch, in pixels.

  The patch is square, and its rows are one pixel each, so the width is the
  square root of the row count — Monty's own assumption. Distances are what a
  neighbourhood and a weight are decided by.
  """
  @spec pixel_dist_to_center(pos_integer(), pos_integer(), non_neg_integer()) :: [float()]
  def pixel_dist_to_center(n_points, patch_width, center_id) do
    center_row = div(center_id, patch_width)
    center_column = rem(center_id, patch_width)

    for index <- 0..(n_points - 1) do
      row = div(index, patch_width)
      column = rem(index, patch_width)

      :math.sqrt(
        (row - center_row) * (row - center_row) +
          (column - center_column) * (column - center_column)
      )
    end
  end

  @doc """
  A Gaussian weight per pixel of the patch, summing to one.

  The fit is a local one: a pixel `neighbor_patch_frac`-th of the patch away
  from the middle counts `e^-2` as much as the pixel at the middle, so the
  quadric follows the surface near the point the sensor is reporting rather than
  the whole patch.
  """
  @spec weight_matrix(pos_integer(), non_neg_integer(), keyword()) :: [float()]
  def weight_matrix(n_points, center_id, options \\ []) do
    patch_width = patch_width(n_points)
    sigma = patch_width / Keyword.get(options, :neighbor_patch_frac, @curvature_patch_frac)
    normaliser = :math.sqrt(2.0 * :math.pi()) * sigma

    weights =
      Enum.map(pixel_dist_to_center(n_points, patch_width, center_id), fn distance ->
        1.0 / normaliser * :math.exp(-distance * distance / (2.0 * sigma * sigma))
      end)

    total = Enum.sum(weights)
    Enum.map(weights, &(&1 / total))
  end

  @doc """
  The points of the patch within a neighbourhood of its middle, as coordinates.

  They are answered relative to the middle pixel, and only the ones on the
  object: a normal fitted across points that are not on it is a normal of
  nothing. `neighbor_patch_frac` is how wide the neighbourhood is, as a fraction
  of the patch's width.
  """
  @spec center_neighbors([[float()]], non_neg_integer(), float()) :: [Rotation.vector()]
  def center_neighbors(point_cloud, center_id, neighbor_patch_frac) do
    [center_x, center_y, center_z | _rest] = Enum.at(point_cloud, center_id)
    n_points = length(point_cloud)
    radius = patch_width(n_points) / neighbor_patch_frac

    point_cloud
    |> Enum.zip(pixel_dist_to_center(n_points, patch_width(n_points), center_id))
    |> Enum.filter(fn {row, distance} -> distance <= radius and List.last(row) > 0.0 end)
    |> Enum.map(fn {[x, y, z | _rest], _distance} ->
      [x - center_x, y - center_y, z - center_z]
    end)
  end

  defp patch_width(n_points), do: n_points |> :math.sqrt() |> round()

  # Whether the middle pixel of the patch is on the object, which is Monty's
  # precondition for estimating anything about the surface there.
  defp on_object?(point_cloud, center_id) do
    List.last(Enum.at(point_cloud, center_id)) > 0.0
  end

  defp curvature_fit(point_cloud, center_id, normal, options) do
    center = Enum.at(point_cloud, center_id)
    [center_x, center_y, center_z | _rest] = center

    relative =
      Enum.map(point_cloud, fn [x, y, z, mask | tail] ->
        [x - center_x, y - center_y, z - center_z, mask | tail]
      end)

    on_object = Enum.filter(relative, fn row -> List.last(row) > 0.0 end)
    points = Enum.map(on_object, &Enum.take(&1, 3))

    {u_direction, v_direction} = tangent_frame(normal)
    u = Enum.map(points, &SpatialArithmetics.dot(&1, u_direction))
    v = Enum.map(points, &SpatialArithmetics.dot(&1, v_direction))
    heights = Enum.map(points, &SpatialArithmetics.dot(&1, normal))

    design = design_matrix(u, v, Keyword.get(options, :fit_intercept, true))
    weights = fit_weights(point_cloud, center_id, options)

    with {:ok, params} <- fit(design, weights, heights),
         {:ok, k1, k2, first, second} <- curvatures(params) do
      direction_1 = combine(first, u_direction, v_direction)
      direction_2 = combine(second, u_direction, v_direction)
      {:ok, k1, k2, direction_1, right_hand_partner(direction_1, direction_2, normal)}
    else
      _not_defined -> :not_defined
    end
  end

  # Two directions square to the normal. Monty picks the x axis crossed with the
  # normal, unless the normal is along z, in which case it takes z itself.
  defp tangent_frame(normal) do
    [normal_x, _normal_y, normal_z] = normal

    u_direction =
      if normal_z != 0.0,
        do: SpatialArithmetics.normalize([1.0, 0.0, -normal_x / normal_z]),
        else: [0.0, 0.0, 1.0]

    v_direction = SpatialArithmetics.cross(normal, u_direction) |> SpatialArithmetics.normalize()
    {u_direction, v_direction}
  end

  defp combine([across, down], u_direction, v_direction) do
    SpatialArithmetics.add(
      SpatialArithmetics.scale(u_direction, across),
      SpatialArithmetics.scale(v_direction, down)
    )
    |> SpatialArithmetics.normalize()
  end

  # Monty always has the second direction to the right of the first about the
  # normal, so the pair is a right-handed frame.
  defp right_hand_partner(direction_1, direction_2, normal) do
    if SpatialArithmetics.get_right_hand_angle(direction_1, direction_2, normal) < 0.0,
      do: SpatialArithmetics.scale(direction_2, -1.0),
      else: direction_2
  end

  defp design_matrix(u, v, fit_intercept?) do
    Enum.zip_with([u, v], fn [across, down] ->
      basis = [across * across, down * down, across * down, across, down]
      if fit_intercept?, do: basis ++ [1.0], else: basis
    end)
  end

  # A Gaussian weight per pixel, by how far it is from the middle of the patch:
  # what makes the fit a local one. Monty builds the weights for the whole patch
  # and keeps the ones on the object; so does this.
  defp fit_weights(point_cloud, center_id, options) do
    if Keyword.get(options, :weighted, true) do
      full =
        weight_matrix(length(point_cloud), center_id,
          neighbor_patch_frac: Keyword.get(options, :neighbor_patch_frac, @curvature_patch_frac)
        )

      point_cloud
      |> Enum.map(fn row -> List.last(row) > 0.0 end)
      |> Enum.zip(full)
      |> Enum.filter(fn {on_object?, _weight} -> on_object? end)
      |> Enum.map(fn {_on_object?, weight} -> weight end)
    else
      :all
    end
  end

  # The weighted least-squares fit: `A = Xᵀ W X` and `b = Xᵀ W n`, solved.
  #
  # Monty asks whether `A` can be inverted at all — by its condition number —
  # before solving. Here a system that cannot be solved answers `:singular`,
  # which is the same decision for the case that happens: a patch with too few
  # pixels on the object to fit six parameters.
  defp fit(design, weights, heights) do
    transposed = transpose(design)

    a_matrix = multiply(transposed, scale_rows(design, weights))
    b = Enum.map(transposed, &inner(&1, scale_values(heights, weights)))

    LinearAlgebra.solve(a_matrix, b)
  end

  defp scale_rows(rows, :all), do: rows

  defp scale_rows(rows, weights) do
    Enum.zip_with([rows, weights], fn [row, weight] -> Enum.map(row, &(&1 * weight)) end)
  end

  defp scale_values(values, :all), do: values

  defp scale_values(values, weights) do
    Enum.zip_with([values, weights], fn [value, weight] -> value * weight end)
  end

  # `guv` and `buv`, the first and second fundamental forms of the fitted
  # quadric, and the shape operator `guv⁻¹ buv` between them. Its eigenvalues are
  # the principal curvatures, and its eigenvectors their directions in the `(u,
  # v)` frame.
  defp curvatures([a, b, c, d, e | _rest]) do
    guv = [[1.0 + d * d, d * e], [d * e, 1.0 + e * e]]
    buv = [[2.0 * a, c], [c, 2.0 * b]]

    with {:ok, first} <- LinearAlgebra.solve(guv, column(buv, 0)),
         {:ok, second} <- LinearAlgebra.solve(guv, column(buv, 1)) do
      [{k1, direction_1}, {k2, direction_2}] = LinearAlgebra.eigen_2x2(rows_of([first, second]))
      {:ok, k1, k2, direction_1, direction_2}
    end
  end

  defp column(matrix, index), do: Enum.map(matrix, &Enum.at(&1, index))

  defp rows_of([first, second]), do: Enum.zip_with([first, second], & &1)

  defp multiply(left, right) do
    columns = transpose(right)
    Enum.map(left, fn row -> Enum.map(columns, &inner(row, &1)) end)
  end

  # A dot product of any length: the fit's rows are five or six numbers, not
  # three, so `SpatialArithmetics.dot/2` does not reach.
  defp inner(left, right), do: Enum.zip_with([left, right], fn [a, b] -> a * b end) |> Enum.sum()

  defp transpose(matrix), do: Enum.zip_with(matrix, & &1)
end
