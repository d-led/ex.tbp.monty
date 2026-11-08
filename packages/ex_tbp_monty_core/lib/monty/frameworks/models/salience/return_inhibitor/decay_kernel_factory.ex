defmodule Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayKernelFactory do
  @moduledoc """
  Makes the kernels a field is filled with, all configured alike.

  Mirrors
  `tbp/monty/frameworks/models/salience/return_inhibitor.py::DecayKernelFactory`.
  A field needs a kernel for every place the sensor visited, and they should all
  decay on the same schedule, so the schedule lives here rather than at each
  call site.
  """

  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayKernel

  @enforce_keys []
  defstruct tau_t: 10.0, tau_s: 0.01, spatial_cutoff: 0.02, w_t_min: 0.1

  @type t :: %__MODULE__{
          tau_t: float(),
          tau_s: float(),
          spatial_cutoff: float() | nil,
          w_t_min: float()
        }

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      tau_t: Keyword.get(options, :tau_t, 10.0),
      tau_s: Keyword.get(options, :tau_s, 0.01),
      spatial_cutoff: Keyword.get(options, :spatial_cutoff, 0.02),
      w_t_min: Keyword.get(options, :w_t_min, 0.1)
    }
  end

  @doc "A kernel that has just been created at `location`."
  @spec call(t(), [float()]) :: DecayKernel.t()
  def call(%__MODULE__{} = factory, location) do
    DecayKernel.new(location,
      tau_t: factory.tau_t,
      tau_s: factory.tau_s,
      spatial_cutoff: factory.spatial_cutoff,
      w_t_min: factory.w_t_min
    )
  end
end
