defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.WeightedSum do
  @moduledoc """
  Adds the feature maps up, each scaled by its weight.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::WeightedSum`.
  A weight of zero silences a channel without having to reconfigure the strategy
  that produced it.

  Note the difference from `WeightedMean`: this one does not renormalise, so a
  config's weights set the overall scale of the salience map as well as the
  relative importance of the channels.
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
    maps
    |> Enum.map(fn {name, map} -> scale(map, Map.fetch!(weights, name)) end)
    |> sum()
  end

  defp scale(map, weight) do
    Enum.map(map, fn row -> Enum.map(row, &(&1 * weight)) end)
  end

  # Pixel by pixel over every map at once: rows first, then the values in them.
  defp sum([single]), do: single

  defp sum(maps) do
    Enum.zip_with(maps, fn rows -> Enum.zip_with(rows, fn values -> Enum.sum(values) end) end)
  end
end
