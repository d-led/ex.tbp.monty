defmodule Monty.Attention.Telemetry.NoopAttentionSystemTelemetry do
  @moduledoc """
  Telemetry that records nothing: Monty's
  `attention/telemetry.py::NoopAttentionSystemTelemetry`.

  A run that is not being inspected still asks its telemetry for a state dict, so
  the answer here is an empty one rather than no answer at all.
  """

  @behaviour Monty.Attention.Telemetry.AttentionSystemTelemetry

  defstruct []

  @type t :: %__MODULE__{}

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def reset(%__MODULE__{} = telemetry), do: telemetry

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def grid(%__MODULE__{} = telemetry, _grid), do: telemetry

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def proposed_grid(%__MODULE__{} = telemetry, _grid), do: telemetry

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def state_dict(%__MODULE__{}), do: %{grids: [], proposed_grids: []}
end
