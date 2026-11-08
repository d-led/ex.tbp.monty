defmodule Monty.Attention.Decay do
  @moduledoc """
  How a weight that was not refreshed this step loses its say — Monty's
  `attention/decay.py`.

  Attention has to forget, or everything ever looked at stays as interesting as
  the thing in front of the sensor. A decay is what forgets: it is handed the
  grid and answers a grid in which every weight has moved one step closer to
  zero.

  Monty's `VoxelGridWeightDecay` is a one-method `Protocol` whose call mutates the
  grid in place. Nothing here mutates — a `%Monty.Attention.VoxelGrid{}` is a
  value — so `decay/1` takes a grid and answers the decayed one. That is the whole
  difference, and it is why the implementations are structs: `NoopDecay` and
  `LinearWeightDecay.new/1` are what a config's `decay` setting becomes.
  """

  alias Monty.Attention.VoxelGrid

  @default_linear_weight_decay_rate 0.1
  @doc "Default per-step decay toward zero for linear decay."
  @spec default_linear_weight_decay_rate() :: float()
  def default_linear_weight_decay_rate, do: @default_linear_weight_decay_rate

  @doc """
  One step of decay: a decay and a grid in, the decayed grid out.

  Monty's decays are objects with a `__call__` that mutates the grid, so the
  decay itself is an argument there too — a bound method. Here the decay is a
  value (`%NoopDecay{}`, `%LinearWeightDecay{rate: 0.1}`), which is why it leads.
  """
  @callback decay(term(), VoxelGrid.t()) :: VoxelGrid.t()
end
