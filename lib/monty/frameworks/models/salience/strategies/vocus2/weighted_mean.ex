defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.WeightedMean do
  @moduledoc """
  Averages the feature maps, each weighted by how much it is trusted.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::WeightedMean`.
  The weights are renormalised to sum to one (in absolute value), which is what
  makes this the default combiner: with `L`, `a`, `b` at 1 and `depth` at 0.1, a
  missing channel changes the *relative* pull of the others but not the overall
  scale of the map — the same property that makes the salience map comparable
  between a config that uses depth and one that does not.

  Weights that cancel out — all zero, or a set summing to zero in absolute value
  — have no mean to take, and Monty would answer a map of NaNs; this raises
  instead, because a NaN salience map is not something a caller can act on.
  """

  @behaviour Monty.Frameworks.Models.Salience.Strategies.Vocus2.MapCombine

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.MapCombine

  @enforce_keys [:weights]
  defstruct [:weights]

  @type t :: %__MODULE__{weights: %{optional(String.t()) => number()}}

  @spec new(%{optional(String.t()) => number()}) :: t()
  def new(weights), do: %__MODULE__{weights: weights}

  @impl true
  @spec call(t(), MapCombine.maps()) :: [[float()]]
  def call(%__MODULE__{weights: weights}, maps) do
    used = Map.new(maps, fn {name, _map} -> {name, Map.fetch!(weights, name)} end)
    total = used |> Map.values() |> Enum.map(&abs/1) |> Enum.sum()

    if total == 0 do
      raise ArgumentError, "the weights of a weighted mean must not sum to zero"
    end

    maps
    |> Enum.map(fn {name, map} -> scale(map, Map.fetch!(used, name) / total) end)
    |> sum()
  end

  defp scale(map, weight) do
    Enum.map(map, fn row -> Enum.map(row, &(&1 * weight)) end)
  end

  defp sum([single]), do: single

  defp sum(maps) do
    Enum.zip_with(maps, fn rows -> Enum.zip_with(rows, fn values -> Enum.sum(values) end) end)
  end
end
