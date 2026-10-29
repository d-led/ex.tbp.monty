defmodule Monty.Frameworks.Models.SensorModules.NoMessageNoise do
  @moduledoc """
  The noise layer that adds nothing.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::NoMessageNoise`: a
  sensor module with no `noise_params` reports what it sensed, and draws from no
  stream at all — which is why a run of a clean experiment is reproducible
  whatever the seed.
  """

  @behaviour Monty.Frameworks.Models.SensorModules.MessageNoise

  alias Monty.Cmp.Message

  @type t :: %__MODULE__{}
  defstruct []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def call(%__MODULE__{}, %Message{} = percept, _rng), do: percept
end
