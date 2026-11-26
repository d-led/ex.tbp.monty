defmodule Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayField do
  @moduledoc """
  Every place the sensor has been, as kernels that fade.

  Mirrors `tbp/monty/frameworks/models/salience/return_inhibitor.py::DecayField`.
  A field answers a salience module's inhibition-of-return: at each point, how
  strongly the sensor's recent visits argue against looking there. Overlapping
  visits do not add up — the strongest kernel wins — so walking over a patch
  twice does not make it twice as unattractive, only as unattractive as the most
  recent visit says.

  Kernels are dropped once they stop mattering, which is what keeps an episode's
  memory of where it has been finite.
  """

  alias ExTbpMonty.Core.SalienceNif
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.{DecayKernel, DecayKernelFactory}

  defstruct kernel_factory: nil, kernels: []

  @type t :: %__MODULE__{kernel_factory: DecayKernelFactory.t(), kernels: [DecayKernel.t()]}

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      kernel_factory: Keyword.get_lazy(options, :kernel_factory, &DecayKernelFactory.new/0)
    }
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = field), do: %__MODULE__{field | kernels: []}

  @doc "Adds a kernel where the sensor just was."
  @spec add(t(), [float()]) :: t()
  def add(%__MODULE__{} = field, location) do
    %__MODULE__{
      field
      | kernels: [DecayKernelFactory.call(field.kernel_factory, location) | field.kernels]
    }
  end

  @doc "One step older, and the kernels that have stopped mattering are gone."
  @spec step(t()) :: t()
  def step(%__MODULE__{} = field) do
    kernels =
      Enum.flat_map(field.kernels, fn kernel ->
        case DecayKernel.step(kernel) do
          {_expired_kernel, true} -> []
          {kernel, false} -> [kernel]
        end
      end)

    %__MODULE__{field | kernels: kernels}
  end

  @doc "How strongly the field argues against each point; zero when it is empty."
  @spec weights(t(), [[float()]]) :: [float()]
  def weights(%__MODULE__{kernels: []}, points), do: Enum.map(points, fn _point -> 0.0 end)

  def weights(%__MODULE__{} = field, points) do
    if SalienceNif.loaded?(),
      do: weights_by_kernel(field, points),
      else: weights_reference(field, points)
  end

  # Monty's `np.max` over the kernels is one call, and it is the whole of a step's
  # inhibition: on a cows step the field holds one kernel per visit and answers
  # 20 000 to 32 000 points, so 1.98 million kernels-times-points in twelve
  # steps. In Elixir that was 491.5 ms — 248 ns a pair, because each pair built
  # a two-cons list for the `Enum.zip_with` after it — and the arithmetic is one
  # square root and one exponential. One crossing, and the answer is the
  # reference's, which `test/.../return_inhibitor_test.exs` holds it to.
  defp weights_by_kernel(%__MODULE__{} = field, points) do
    count = length(points)

    kernels =
      for kernel <- field.kernels, into: <<>> do
        [ox, oy, oz] = kernel.location
        time = DecayKernel.time_weight(kernel)
        half_life = DecayKernel.half_life(kernel.tau_s)

        <<ox::float-little-64, oy::float-little-64, oz::float-little-64,
          time::float-little-64, half_life::float-little-64>> <> cutoff(kernel)
      end

    flat_points =
      for [x, y, z] <- points, into: <<>>, do: <<x::float-little-64, y::float-little-64, z::float-little-64>>

    SalienceNif.inhibition_weights(kernels, flat_points, count)
    |> then(fn raw -> for <<weight::float-little-64 <- raw>>, do: weight end)
  end

  # A kernel with no cutoff says something everywhere, which `+inf` means to the
  # comparison rather than a second flag beside it. Little-endian, like every
  # `f64` in the binary — `::64` writes the bit pattern the other way round, and
  # a denormal there rejects every point instead of accepting them.
  defp cutoff(%DecayKernel{} = kernel) do
    case kernel.spatial_cutoff do
      nil -> <<0x7FF0000000000000::little-64>>
      metres -> <<metres::float-little-64>>
    end
  end

  @doc """
  The same answer in Elixir, one kernel at a time — the reference the kernel is
  held to, and what runs where the crate was never built.
  """
  @spec weights_reference(t(), [[float()]]) :: [float()]
  def weights_reference(%__MODULE__{kernels: []}, points),
    do: Enum.map(points, fn _point -> 0.0 end)

  # One visit, and the field's answer is that kernel's answer: `np.max` over a
  # single row is the row, so the walk that would take it is not taken.
  def weights_reference(%__MODULE__{kernels: [kernel]}, points),
    do: DecayKernel.weights(kernel, points)

  # Overlapping visits do not add up: the strongest kernel at each point wins.
  def weights_reference(%__MODULE__{} = field, points) do
    field.kernels
    |> Enum.map(&DecayKernel.weights(&1, points))
    |> Enum.zip_with(fn per_kernel -> Enum.max(per_kernel) end)
  end
end
