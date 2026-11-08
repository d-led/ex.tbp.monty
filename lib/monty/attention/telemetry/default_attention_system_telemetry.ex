defmodule Monty.Attention.Telemetry.DefaultAttentionSystemTelemetry do
  @moduledoc """
  Telemetry that keeps every grid it is told about — Monty's
  `attention/telemetry.py::DefaultAttentionSystemTelemetry`.

  Two lists, in the order the grids arrived: what the sensors proposed, and what
  the attention system kept. Keeping them side by side is the point — the pair is
  what lets a reviewer see a goal survive or be dropped.
  """

  @behaviour Monty.Attention.Telemetry.AttentionSystemTelemetry

  alias Monty.Attention.VoxelGrid

  defstruct grids: [], proposed_grids: []

  @type t :: %__MODULE__{grids: [VoxelGrid.t()], proposed_grids: [VoxelGrid.t()]}

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def reset(%__MODULE__{}), do: %__MODULE__{}

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def grid(%__MODULE__{grids: grids} = telemetry, %VoxelGrid{} = grid),
    do: %{telemetry | grids: grids ++ [grid]}

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def proposed_grid(%__MODULE__{proposed_grids: proposed} = telemetry, %VoxelGrid{} = grid),
    do: %{telemetry | proposed_grids: proposed ++ [grid]}

  @impl Monty.Attention.Telemetry.AttentionSystemTelemetry
  def state_dict(%__MODULE__{grids: grids, proposed_grids: proposed}) do
    %{grids: grids, proposed_grids: proposed}
  end
end
