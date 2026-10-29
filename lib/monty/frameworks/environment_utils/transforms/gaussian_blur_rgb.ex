defmodule Monty.Frameworks.EnvironmentUtils.Transforms.GaussianBlurRGB do
  @moduledoc """
  Blur the colour image, leaving its alpha alone.

  Mirrors
  `tbp/monty/frameworks/environment_utils/transforms.py::GaussianBlurRGB`, which
  calls OpenCV's `GaussianBlur` on the first three channels and concatenates the
  alpha channel back on.

  ## OpenCV's numbers, checked

  OpenCV is not a dependency of the port, so its behaviour was measured against
  OpenCV 4.10 here and reproduced: a normalised Gaussian of one vector with
  itself, applied separably, with the border *reflected without repeating the
  edge pixel* (`BORDER_REFLECT_101`) — the port's kernel agrees with
  `cv2.GaussianBlur` to `1.0e-7` on a random float image, which is float32
  precision. That verification is what the tests pin.

  Monty's comment says OpenCV picks `6*sigma + 1` when the kernel size is left at
  zero; measured, it picks `8*sigma + 1` rounded up to odd for a float image
  (`sigma: 2` is a 17-pixel kernel, not 13). The code calls OpenCV, so the code
  is what the port follows and the comment is what it does not — recorded with
  the other suspected defects (`docs/monty-bugs.md` §1.11).

  ## Which sensors

  `:sensor_ids` limits the blur to some sensors; `nil` means all of them. An
  empty list is an error, as it is in Monty, because a config that names no
  sensor asked for nothing and would blur nothing silently.
  """

  @behaviour Monty.Frameworks.EnvironmentUtils.Transforms.Transform

  alias Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext

  @default_sigma 1.0

  @enforce_keys [:agent_id]
  defstruct agent_id: nil, sigma: @default_sigma, kernel_size: 0, sensor_ids: nil, kernel: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          sigma: float(),
          kernel_size: non_neg_integer(),
          sensor_ids: [atom() | String.t()] | nil,
          kernel: [float()]
        }

  @spec new(keyword()) :: t()
  def new(options) do
    sigma = Keyword.get(options, :sigma, @default_sigma)
    kernel_size = Keyword.get(options, :kernel_size, 0)
    sensor_ids = Keyword.get(options, :sensor_ids)

    validate!(sigma, kernel_size, sensor_ids)

    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sigma: sigma,
      kernel_size: kernel_size,
      sensor_ids: sensor_ids,
      kernel: kernel(sigma, kernel_size)
    }
  end

  @doc "The transform a config describes."
  @spec from_config(map()) :: t()
  def from_config(config) do
    new(
      agent_id: Map.fetch!(config, "agent_id"),
      sigma: Map.get(config, "sigma", @default_sigma),
      kernel_size: Map.get(config, "kernel_size", 0),
      sensor_ids: Map.get(config, "sensor_ids")
    )
  end

  defp validate!(sigma, kernel_size, sensor_ids) do
    cond do
      sensor_ids == [] ->
        raise ArgumentError, "sensor_ids must not be empty; use nil for all sensors"

      kernel_size < 0 ->
        raise ArgumentError, "the kernel_size must be non-negative, got #{kernel_size}"

      kernel_size != 0 and rem(kernel_size, 2) == 0 ->
        raise ArgumentError,
              "the kernel_size must be odd or 0 (for auto-compute), got #{kernel_size}"

      kernel_size == 0 and sigma <= 0 ->
        raise ArgumentError, "the sigma must be positive when kernel_size is 0, got #{sigma}"

      sigma <= 0 ->
        raise ArgumentError,
              "OpenCV derives a sigma from an explicit kernel size with a fixed-point table " <>
                "this port has not reproduced: give an explicit sigma, as every config that " <>
                "uses this transform does"

      true ->
        :ok
    end
  end

  @impl true
  @spec call(map(), t(), TransformContext.t()) :: map()
  def call(observations, %__MODULE__{} = transform, %TransformContext{}) do
    agent = Map.fetch!(observations, transform.agent_id)

    blurred =
      Map.new(sensors(agent, transform), fn {sensor_id, observation} ->
        rgba = rgba!(observation, sensor_id)

        {sensor_id,
         Map.put(
           observation,
           "rgba",
           rgba
           |> blur_channel(transform)
           |> Enum.zip(rgba)
           |> Enum.map(fn {blurred_row, original_row} ->
             Enum.zip_with([blurred_row, original_row], fn [pixel, original] ->
               pixel ++ [List.last(original)]
             end)
           end)
         )}
      end)

    Map.put(observations, transform.agent_id, Map.merge(agent, blurred))
  end

  defp sensors(agent, %__MODULE__{sensor_ids: nil}), do: agent

  defp sensors(agent, %__MODULE__{sensor_ids: sensor_ids}) do
    Enum.map(sensor_ids, fn sensor_id ->
      case Map.fetch(agent, sensor_id) do
        {:ok, observation} ->
          {sensor_id, observation}

        :error ->
          raise KeyError,
                "sensor #{inspect(sensor_id)} is not in the observations for " <>
                  "#{inspect(Enum.map(Map.keys(agent), & &1))}"
      end
    end)
    |> Map.new()
  end

  defp rgba!(observation, sensor_id) do
    case Map.fetch(observation, "rgba") do
      {:ok, rgba} -> rgba
      :error -> raise KeyError, "sensor #{inspect(sensor_id)} has no 'rgba' image"
    end
  end

  # The three colour channels of every pixel, blurred.
  defp blur_channel(rgba, %__MODULE__{kernel: kernel}) do
    pad = div(length(kernel), 2)

    rgba
    |> Enum.map(fn row -> Enum.map(row, fn pixel -> Enum.take(pixel, 3) end) end)
    |> pad_reflect(pad)
    |> then(fn rows -> Enum.map(rows, &convolve(&1, kernel)) end)
    |> then(fn rows -> rows |> transpose() |> Enum.map(&convolve(&1, kernel)) |> transpose() end)
  end

  # OpenCV's default border, `BORDER_REFLECT_101`: mirror about the edge pixel
  # without repeating it, so `[a b c d]` continues `[c b | a b c d | c b]`.
  defp pad_reflect(rows, 0), do: rows

  defp pad_reflect(rows, pad) do
    rows
    |> pad_axis(pad)
    |> Enum.map(&pad_axis(&1, pad))
  end

  # An axis of one pixel has nothing to reflect onto: every position is that
  # pixel, which is also what OpenCV does.
  defp pad_axis([value], pad), do: List.duplicate(value, 1 + 2 * pad)

  # Reflected by index, which is the definition itself: a position outside the
  # row folds back with period `2*(n-1)`.
  defp pad_axis(values, pad) do
    last = length(values) - 1
    period = 2 * last

    Enum.map(-pad..(last + pad), fn position ->
      folded = Integer.mod(position, period)

      Enum.at(values, if(folded > last, do: period - folded, else: folded))
    end)
  end

  # Convolve every complete window of a row against the kernel, keeping the row
  # the same length: the padding above makes `valid` and `same` agree.
  defp convolve(row, kernel) do
    width = length(row) - length(kernel) + 1

    Enum.map(0..(width - 1), fn start ->
      row
      |> Enum.slice(start, length(kernel))
      |> Enum.zip(kernel)
      |> Enum.reduce([0.0, 0.0, 0.0], fn {pixel, weight}, acc ->
        Enum.zip_with([acc, pixel], fn [sum, channel] -> sum + channel * weight end)
      end)
    end)
  end

  defp transpose([]), do: []

  defp transpose([first | _rest] = rows) do
    first
    |> Enum.with_index()
    |> Enum.map(fn {_value, column} -> Enum.map(rows, &Enum.at(&1, column)) end)
  end

  defp kernel(sigma, 0), do: kernel(sigma, auto_kernel_size(sigma))

  defp kernel(sigma, kernel_size) do
    pad = div(kernel_size, 2)

    weights =
      Enum.map(-pad..pad, fn offset ->
        :math.exp(-(offset * offset) / (2 * sigma * sigma))
      end)

    total = Enum.sum(weights)
    Enum.map(weights, &(&1 / total))
  end

  # What OpenCV does for a float image when asked for a kernel of zero: it takes
  # `8*sigma + 1` rounded, and forces it odd.
  defp auto_kernel_size(sigma) do
    size = round(sigma * 8 + 1)
    if rem(size, 2) == 0, do: size + 1, else: size
  end
end
