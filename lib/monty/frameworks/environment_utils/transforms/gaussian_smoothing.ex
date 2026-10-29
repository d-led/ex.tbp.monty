defmodule Monty.Frameworks.EnvironmentUtils.Transforms.GaussianSmoothing do
  @moduledoc """
  Blur the raw depth image before anything reads it.

  Mirrors
  `tbp/monty/frameworks/environment_utils/transforms.py::GaussianSmoothing`: a
  normalised Gaussian kernel of `kernel_width` pixels convolved over each
  sensor's depth image, with the image's edges repeated so the result keeps its
  size. Monty's comment is that this is for a depth camera's noise; whether it
  helps real cameras is, in its own words, still untested.

  ## The maths, and where it comes from

  Monty builds the kernel from `np.linspace(-pad, pad, kernel_width)` and
  normalises it by its sum, pads with `mode="edge"`, and convolves with
  `mode="valid"`. The port pads both axes, filters each row and then each
  column — the kernel is an outer product of one vector with itself, so that is
  the same convolution, and it costs a factor of `kernel_width` less work.

  `scipy` is not available here, so the port was checked against a
  `sliding_window_view` reference of the same definition rather than against
  scipy itself. For a 5×5 ramp of 1..25 at `sigma: 2`, `kernel_width: 3` the
  corner pixel of the output is `2.915007` — the number a test pins.
  """

  @behaviour Monty.Frameworks.EnvironmentUtils.Transforms.Transform

  alias Monty.Frameworks.EnvironmentUtils.Transforms.{NoDepthSensorPresent, TransformContext}

  # Monty's constructor defaults.
  @default_sigma 2.0
  @default_kernel_width 3

  @enforce_keys [:agent_id]
  defstruct agent_id: nil, sigma: @default_sigma, kernel_width: @default_kernel_width, kernel: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          sigma: float(),
          kernel_width: pos_integer(),
          kernel: [float()]
        }

  @spec new(keyword()) :: t()
  def new(options) do
    sigma = Keyword.get(options, :sigma, @default_sigma)
    kernel_width = Keyword.get(options, :kernel_width, @default_kernel_width)

    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sigma: sigma,
      kernel_width: kernel_width,
      kernel: kernel(sigma, kernel_width)
    }
  end

  @doc "The transform a config describes."
  @spec from_config(map()) :: t()
  def from_config(config) do
    new(
      agent_id: Map.fetch!(config, "agent_id"),
      sigma: Map.get(config, "sigma", @default_sigma),
      kernel_width: Map.get(config, "kernel_width", @default_kernel_width)
    )
  end

  @impl true
  @spec call(map(), t(), TransformContext.t()) :: map()
  def call(observations, %__MODULE__{} = transform, %TransformContext{}) do
    agent = Map.fetch!(observations, transform.agent_id)

    smoothed =
      Map.new(agent, fn {sensor_id, observation} ->
        depth = depth!(observation, sensor_id)
        {sensor_id, Map.put(observation, "depth", smooth(depth, transform))}
      end)

    Map.put(observations, transform.agent_id, smoothed)
  end

  defp depth!(observation, sensor_id) do
    case Map.fetch(observation, "depth") do
      {:ok, depth} -> depth
      :error -> raise NoDepthSensorPresent, "sensor #{inspect(sensor_id)} has no depth image"
    end
  end

  # A normalised one-dimensional Gaussian, which the 2D kernel is the outer
  # product of.
  defp kernel(sigma, kernel_width) do
    pad = div(kernel_width, 2)
    x = linspace(-pad, pad, kernel_width)

    weights =
      Enum.map(x, fn value ->
        1.0 / (:math.sqrt(2 * :math.pi()) * sigma) *
          :math.exp(-(value * value) / (2 * sigma * sigma))
      end)

    total = Enum.sum(weights)
    Enum.map(weights, &(&1 / total))
  end

  # `np.linspace(start, stop, count)`: both ends included, and a single sample
  # is the start rather than a division by zero.
  defp linspace(_start, _stop, 1), do: [0.0]

  defp linspace(start, stop, count) do
    step = (stop - start) / (count - 1)
    Enum.map(0..(count - 1), fn index -> start + index * step end)
  end

  defp smooth(depth, %__MODULE__{kernel: kernel, kernel_width: kernel_width}) do
    pad = div(kernel_width, 2)

    depth
    |> pad_edges(pad)
    |> then(fn padded -> Enum.map(padded, &convolve_row(&1, kernel)) end)
    |> then(fn rows ->
      rows |> transpose() |> Enum.map(&convolve_row(&1, kernel)) |> transpose()
    end)
  end

  # `mode="edge"`: the outermost row or column repeated, so the image keeps its
  # size when the convolution only keeps complete windows.
  defp pad_edges(rows, 0), do: rows

  defp pad_edges(rows, pad) do
    first = hd(rows)
    last = List.last(rows)
    repeated_rows = List.duplicate(first, pad) ++ rows ++ List.duplicate(last, pad)

    repeated_rows
    |> Enum.map(fn row ->
      List.duplicate(hd(row), pad) ++ row ++ List.duplicate(List.last(row), pad)
    end)
  end

  # `mode="valid"`: only windows that fit, which is what keeps the output the
  # input's size after the padding above.
  defp convolve_row(row, kernel) do
    width = length(row) - length(kernel) + 1

    Enum.map(0..(width - 1), fn start ->
      row
      |> Enum.slice(start, length(kernel))
      |> Enum.zip(kernel)
      |> Enum.reduce(0.0, fn {value, weight}, acc -> acc + value * weight end)
    end)
  end

  defp transpose([]), do: []

  defp transpose([first | _rest] = rows) do
    first
    |> Enum.with_index()
    |> Enum.map(fn {_value, column} -> Enum.map(rows, &Enum.at(&1, column)) end)
  end
end
