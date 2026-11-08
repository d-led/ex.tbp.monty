defmodule Monty.Attention.Decay.LinearWeightDecay do
  @moduledoc """
  Move every weight a fixed distance toward zero each step: Monty's
  `attention/decay.py::LinearWeightDecay`.

  A weight of `0.7` with a rate of `0.1` becomes `0.6`, and `-0.7` becomes
  `-0.6`. A weight already within `rate` of zero is not nudged past it — it
  becomes exactly `0.0`, so that a steady decay cannot make a weight oscillate
  around zero or flip its sign, which would turn "look here" into "avoid here"
  by forgetting.
  """

  @behaviour Monty.Attention.Decay

  alias Monty.Attention.{Decay, VoxelGrid}

  @enforce_keys [:rate]
  defstruct [:rate]

  @type t :: %__MODULE__{rate: float()}

  @doc """
  A decay of `rate` per step, which must not be negative.

  A negative rate would move weights away from zero, which is the opposite of
  forgetting, so it is refused rather than accepted and misread.
  """
  @spec new(number()) :: t()
  def new(rate) when is_number(rate) and rate >= 0.0, do: %__MODULE__{rate: rate}

  def new(rate) do
    raise ArgumentError,
          "a linear weight decay moves weights toward zero, so its rate must be " <>
            "non-negative, got #{inspect(rate)}"
  end

  @doc "A grid in which every weight has moved one step toward zero."
  @impl Monty.Attention.Decay
  def decay(%__MODULE__{rate: rate}, %VoxelGrid{} = grid) do
    if VoxelGrid.size(grid) == 0 or rate == 0.0 do
      grid
    else
      %{
        grid
        | weights: Map.new(grid.weights, fn {voxel, weight} -> {voxel, step(weight, rate)} end)
      }
    end
  end

  defp step(weight, rate) when abs(weight) > rate, do: weight - rate * sign(weight)
  defp step(_weight, _rate), do: 0.0

  defp sign(weight) when weight < 0, do: -1
  defp sign(_weight), do: 1

  @doc "The default rate, so a config can say `linear` and mean what Monty means."
  @spec default_rate() :: float()
  def default_rate, do: Decay.default_linear_weight_decay_rate()
end
