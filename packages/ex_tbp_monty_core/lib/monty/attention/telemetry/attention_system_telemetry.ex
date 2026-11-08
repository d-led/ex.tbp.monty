defmodule Monty.Attention.Telemetry.AttentionSystemTelemetry do
  @moduledoc """
  The contract every attention telemetry satisfies — Monty's
  `attention/telemetry.py::AttentionSystemTelemetry`.

  Monty declares it as a `Protocol` with `reset`, `proposed_grid`, `grid` and
  `state_dict`. Three of those change the telemetry, so here they take it and
  answer the changed one; `state_dict/1` is a read and is the only one that could
  have stayed a one-argument method.

  The contract is written down as a behaviour because it has two implementations
  and a caller (the attention system) that must not care which it has.
  """

  alias Monty.Attention.VoxelGrid
  alias Monty.Memento

  @doc "Forget every grid recorded so far."
  @callback reset(telemetry :: term()) :: telemetry :: term()

  @doc "Record the grid the attention system kept."
  @callback grid(telemetry :: term(), VoxelGrid.t()) :: telemetry :: term()

  @doc "Record the grid the sensors proposed, before the attention system touched it."
  @callback proposed_grid(telemetry :: term(), VoxelGrid.t()) :: telemetry :: term()

  @doc "Everything recorded since the last reset, as a Memento."
  @callback state_dict(telemetry :: term()) :: Memento.t()
end
