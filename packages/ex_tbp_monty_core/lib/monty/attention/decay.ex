defmodule Monty.Attention.Decay do
  @moduledoc """
  How a weight that was not refreshed this step loses its say: Monty's
  `attention/decay.py`.

  Attention has to forget, or everything ever looked at stays as interesting as
  the thing in front of the sensor. A decay is what forgets, and this module
  holds the one thing the file holds besides its classes: the rate a config means
  when it says `linear` and names none.

  The decays themselves are `Monty.Attention.Decay.NoopDecay` and
  `Monty.Attention.Decay.LinearWeightDecay`, and what they have in common is
  `Monty.Attention.Decay.VoxelGridWeightDecay`.
  """

  @default_linear_weight_decay_rate 0.1
  @doc "Default per-step decay toward zero for linear decay."
  @spec default_linear_weight_decay_rate() :: float()
  def default_linear_weight_decay_rate, do: @default_linear_weight_decay_rate
end
