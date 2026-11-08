defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.NoOperatingLimits do
  @moduledoc """
  No limits at all: whatever sigmas the config names are the sigmas used.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::NoOperatingLimits`.
  A config chooses this when it knows its images and would rather be trusted
  than checked.
  """

  @behaviour Monty.Frameworks.Models.Salience.Strategies.Vocus2.OperatingLimits

  @enforce_keys []
  defstruct []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  @spec validate(t(), pos_integer(), float(), float()) :: :ok
  def validate(%__MODULE__{}, _min_image_dim_size, _center_sigma, _surround_sigma), do: :ok
end
