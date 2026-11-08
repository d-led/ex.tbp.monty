defmodule Monty.Frameworks.Models.SensorModules.PassthroughPerceptFilter do
  @moduledoc """
  The filter that passes everything on.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::PassthroughPerceptFilter`:
  a sensor module configured with no `delta_thresholds` sends every percept to
  its learning modules, unchanged.
  """

  @behaviour Monty.Frameworks.Models.SensorModules.PerceptFilter

  alias Monty.Cmp.Message

  @type t :: %__MODULE__{}
  defstruct []

  @doc "The filter, and the memory it keeps (none)."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def call(%__MODULE__{}, %Message{} = percept, memory), do: {percept, memory}

  @impl true
  def reset(_memory), do: nil
end
