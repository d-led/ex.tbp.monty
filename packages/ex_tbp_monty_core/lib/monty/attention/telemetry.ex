defmodule Monty.Attention.Telemetry do
  @moduledoc """
  What the attention system remembers about its own grids — Monty's
  `attention/telemetry.py`.

  Two grids matter each step: the one the sensors proposed and the one the
  attention system kept after decay, filtering and merging. A recording run keeps
  both so that a reviewer can see why a goal was dropped; a fast run keeps
  neither.

  Monty's telemetry is an object with `reset`, `grid`, `proposed_grid` and
  `state_dict`. Here the telemetry is a value and each of those is a function
  that answers the telemetry after the event — so a caller threads it, exactly as
  it threads the grid.
  """

  @doc "The telemetry a run records with, unless its config says otherwise."
  @spec default() :: Monty.Attention.Telemetry.DefaultAttentionSystemTelemetry.t()
  def default, do: %Monty.Attention.Telemetry.DefaultAttentionSystemTelemetry{}
end
