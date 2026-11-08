defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.OrientationSalience do
  @moduledoc """
  How much a patch looks like an edge, at several orientations.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::OrientationSalience`.

  Four Gabor filters at 0°, 45°, 90° and 135° are run over the detail of the
  lightness pyramid, and the absolute response is kept. A Gabor filter answers
  strongly where the image has structure at its wavelength, so "this patch is an
  edge" becomes a number — and the four orientations together make an edge
  salient whichever way it runs. Filtering the Laplacian rather than the image
  keeps a response local to the scale it was found at.

  Each kernel has its mean subtracted before use, so a large flat region answers
  nothing instead of answering in proportion to its brightness: the filter is
  meant to detect structure, not light.

  ## Measured, not recalled

  `cv2.getGaborKernel` is not a dependency of the port, so both of its halves
  were measured against OpenCV 4.10 and reproduced: the Gaussian envelope with
  `sigma_y = sigma / gamma`, the rotation `x_r = x cos θ + y sin θ` and
  `y_r = -x sin θ + y cos θ`, and — the part that is easy to get wrong — the
  modulation entering as `cos(2π x_r / λ - ψ)`, with a *minus* psi. A plus psi
  agrees when `psi` is zero and is wrong for every other phase, which is how the
  mistake survived a first reading.

  Filtering is correlation, not convolution, with OpenCV's default
  `BORDER_REFLECT_101`; measured to `1.0e-6` on random images.
  """

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.MapCombine
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @quarter_turn :math.pi() / 2

  @enforce_keys [:period]
  defstruct period: nil,
            sigma: nil,
            phase: @quarter_turn,
            gamma: 0.75,
            n_orientations: 4,
            combine: &Vocus2.map_mean/1,
            collapse: &Pyramids.collapse_mean/1,
            kernels: %{}

  @type t :: %__MODULE__{
          period: float(),
          sigma: float(),
          phase: float(),
          gamma: float(),
          n_orientations: pos_integer(),
          combine: (MapCombine.maps() -> [[float()]]),
          collapse: (Pyramid.t() -> [[float()]]),
          kernels: %{optional(String.t()) => [[float()]]}
        }

  @doc """
  Orientation salience from `:n_orientations` Gabor filters of `:period`.

  `:sigma` defaults to `0.3 * period`, which is Monty's rule of thumb, and
  `:phase` to a quarter turn, which finds edges; a phase of zero finds strips.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    salience = %__MODULE__{
      period: Keyword.fetch!(options, :period),
      sigma: Keyword.get(options, :sigma),
      phase: Keyword.get(options, :phase, @quarter_turn),
      gamma: Keyword.get(options, :gamma, 0.75),
      n_orientations: Keyword.get(options, :n_orientations, 4),
      combine: Keyword.get(options, :combine, &Vocus2.map_mean/1),
      collapse: Keyword.get(options, :collapse, &Pyramids.collapse_mean/1)
    }

    sigma = salience.sigma || 0.3 * salience.period

    %__MODULE__{
      salience
      | sigma: sigma,
        kernels:
          kernels(
            period: salience.period,
            sigma: sigma,
            phase: salience.phase,
            gamma: salience.gamma,
            n_orientations: salience.n_orientations
          )
    }
  end

  @doc """
  The Gabor kernels: one per orientation, each centred on zero mean.

  The kernel is `int(7*sigma + 1) | 1` pixels square — Monty's arithmetic, and
  OpenCV's rule for a kernel size it is not given.
  """
  @spec kernels(keyword()) :: %{optional(String.t()) => [[float()]]}
  def kernels(options) do
    period = Keyword.fetch!(options, :period)
    sigma = Keyword.fetch!(options, :sigma)
    phase = Keyword.get(options, :phase, @quarter_turn)
    gamma = Keyword.get(options, :gamma, 0.75)
    n_orientations = Keyword.get(options, :n_orientations, 4)

    size = trunc(7 * sigma + 1) |> then(&if(rem(&1, 2) == 0, do: &1 + 1, else: &1))

    for orientation <- 0..(n_orientations - 1), into: %{} do
      theta = orientation * :math.pi() / n_orientations

      {"orientation_#{orientation}", gabor(size, sigma, theta, period, gamma, phase) |> centred()}
    end
  end

  # One Gabor kernel, as OpenCV builds it.
  defp gabor(size, sigma, theta, period, gamma, phase) do
    sigma_x = sigma
    sigma_y = sigma / gamma
    half = div(size, 2)
    cosine = :math.cos(theta)
    sine = :math.sin(theta)
    envelope_x = -0.5 / (sigma_x * sigma_x)
    envelope_y = -0.5 / (sigma_y * sigma_y)
    frequency = 2 * :math.pi() / period

    for y <- -half..half do
      for x <- -half..half do
        rotated_x = x * cosine + y * sine
        rotated_y = -x * sine + y * cosine

        :math.exp(envelope_x * rotated_x * rotated_x + envelope_y * rotated_y * rotated_y) *
          :math.cos(frequency * rotated_x - phase)
      end
    end
  end

  # Subtract the mean, so a flat region answers nothing.
  defp centred(kernel) do
    values = List.flatten(kernel)
    mean = Enum.sum(values) / length(values)

    Enum.map(kernel, fn row -> Enum.map(row, &(&1 - mean)) end)
  end

  @doc """
  The orientation salience map for one pyramid of lightness.

  Each orientation answers one map — the detail of the pyramid filtered and
  rectified — and the maps are combined by `:combine`, whose default is their
  mean.
  """
  @spec process(t(), Monty.Context.t(), Pyramid.t()) :: [[float()]]
  def process(%__MODULE__{} = salience, %Monty.Context{}, pyramid) do
    laplacian = Pyramids.laplacian(pyramid)

    feature_maps =
      Map.new(salience.kernels, fn {name, kernel} ->
        {name, laplacian |> Pyramid.apply(&rectified(&1, kernel)) |> salience.collapse.()}
      end)

    salience.combine.(feature_maps)
  end

  defp rectified(plane, kernel) do
    plane
    |> correlate(kernel)
    |> Enum.map(fn row -> Enum.map(row, &abs/1) end)
  end

  @doc """
  Correlates a plane with a kernel, as `cv2.filter2D` does.

  The kernel is laid over the pixel unflipped — correlation, not convolution —
  and the border is reflected without repeating the edge pixel
  (`BORDER_REFLECT_101`), so `[a b c d]` continues `[c b | a b c d | c b]`.

  The padded plane and the kernel are turned into tuples first, because every
  pixel reads the same neighbourhood many times and a list is a walk from the
  front each time.
  """
  @spec correlate([[float()]], [[float()]]) :: [[float()]]
  def correlate(plane, kernel) do
    kernel_height = length(kernel)
    kernel_width = kernel |> hd() |> length()

    padded =
      plane
      |> pad(div(kernel_height, 2), div(kernel_width, 2))
      |> Enum.map(&List.to_tuple/1)
      |> List.to_tuple()

    kernel_rows = kernel |> Enum.map(&List.to_tuple/1) |> List.to_tuple()

    height = length(plane)
    width = plane |> hd() |> length()

    for y <- 0..(height - 1) do
      for x <- 0..(width - 1) do
        correlate_at(kernel_rows, padded, kernel_height, kernel_width, {y, x})
      end
    end
  end

  defp correlate_at(kernel_rows, padded, kernel_height, kernel_width, {y, x}) do
    Enum.reduce(0..(kernel_height - 1), 0.0, fn offset, sum ->
      kernel_row = :erlang.element(offset + 1, kernel_rows)
      image_row = :erlang.element(y + offset + 1, padded)

      sum + window_dot(kernel_row, image_row, x, kernel_width)
    end)
  end

  defp window_dot(kernel_row, image_row, x, width) do
    Enum.reduce(0..(width - 1), 0.0, fn offset, sum ->
      sum +
        :erlang.element(offset + 1, kernel_row) * :erlang.element(x + offset + 1, image_row)
    end)
  end

  # The border OpenCV reflects: mirror about the edge pixel without repeating it.
  defp pad(rows, pad_y, pad_x) do
    height = length(rows)
    vertical = for y <- -pad_y..(height + pad_y - 1), do: Enum.at(rows, reflect(y, height))

    Enum.map(vertical, fn row ->
      width = length(row)
      for x <- -pad_x..(width + pad_x - 1), do: Enum.at(row, reflect(x, width))
    end)
  end

  # An axis of one pixel has nothing to reflect onto.
  defp reflect(_index, 1), do: 0

  defp reflect(index, length) do
    period = 2 * (length - 1)
    folded = Integer.mod(index, period)

    if folded > length - 1, do: period - folded, else: folded
  end
end
