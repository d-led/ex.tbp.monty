defmodule Monty.Cmp.AttentionRegion do
  @moduledoc """
  Locations carrying an attention weight, proposed by a sensor or learning
  module to the attention system.

  Mirrors `tbp/monty/cmp.py::AttentionRegion`. Weights run from `MIN_WEIGHT`
  (do not look here) to `MAX_WEIGHT` (look here).
  """

  @enforce_keys [:locations, :weights]
  defstruct locations: [], weights: []

  @type location :: [float()]
  @type t :: %__MODULE__{locations: [location()], weights: [float()]}

  @min_weight -1.0
  @max_weight 1.0

  @doc "The largest weight a region may carry: a strong invitation to look."
  @spec max_weight() :: float()
  def max_weight, do: @max_weight

  @doc "The smallest weight a region may carry: a strong inhibition."
  @spec min_weight() :: float()
  def min_weight, do: @min_weight

  @doc "A region with nothing in it."
  @spec empty() :: t()
  def empty, do: %__MODULE__{locations: [], weights: []}

  @doc "A region of locations that all carry the same weight."
  @spec uniform([location()], float()) :: t()
  def uniform(locations, weight) when weight >= @min_weight and weight <= @max_weight do
    %__MODULE__{locations: locations, weights: List.duplicate(weight, length(locations))}
  end

  @doc """
  Concatenates regions. No regions is an empty region, which is what the
  attention system sees when nobody proposes anything.
  """
  @spec concat([t()]) :: t()
  def concat(regions) do
    %__MODULE__{
      locations: Enum.flat_map(regions, & &1.locations),
      weights: Enum.flat_map(regions, & &1.weights)
    }
  end

  @doc "True when the region proposes nothing."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{locations: [], weights: []}), do: true
  def empty?(%__MODULE__{}), do: false
end
