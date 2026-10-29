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
    field.kernels
    |> Enum.map(&DecayKernel.weights(&1, points))
    |> Enum.zip_with(fn per_kernel -> Enum.max(per_kernel) end)
  end
end
