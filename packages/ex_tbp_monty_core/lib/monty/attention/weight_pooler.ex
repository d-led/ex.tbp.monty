defmodule Monty.Attention.WeightPooler do
  @moduledoc """
  How several weights about one voxel become one — Monty's
  `attention/weight_pooler.py`.

  A voxel can be told about by more than one sensor, or more than once by the
  same one, and something has to decide which of those opinions the attention
  system keeps.

  Monty's `WeightPooler` is a one-method `Protocol`: anything callable with the
  values is a pooler. Here that is a function of arity one, `([number]) ->
  number`, and `pool/1` names the contract the way a behaviour would.
  """

  @doc "The contract a weight pooler satisfies: many weights in, one weight out."
  @callback pool([number()]) :: number()

  @doc """
  Inhibition-dominating pooling: the maximum, unless anything is negative.

  A negative weight means "do not look here", and a single such vote must not be
  outvoted by several positive ones, so the most negative value wins whenever
  there is one. Otherwise this is the plain maximum.
  """
  @spec negative_priority_max_pool([number()]) :: number()
  def negative_priority_max_pool(values) do
    if Enum.any?(values, &(&1 < 0)), do: Enum.min(values), else: Enum.max(values)
  end
end
