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

  @doc """
  A region of `locations`, each carrying its `weights`.

  Refuses what Monty's `__post_init__` refuses: a location that is not three
  numbers, a weight that is not one number, and two counts that disagree. A
  region whose parts do not line up shifts every weight of the step it is read
  in, so it is refused where it is built rather than where it is used.
  """
  @spec new([location()], [float()]) :: {:ok, t()} | {:error, term()}
  def new(locations, weights) do
    with :ok <- locations_n_by_3(locations),
         :ok <- weights_one_dimensional(weights),
         :ok <- same_count(locations, weights) do
      {:ok, %__MODULE__{locations: locations, weights: weights}}
    end
  end

  defp locations_n_by_3(locations) when is_list(locations) do
    if Enum.all?(locations, &three_numbers?/1),
      do: :ok,
      else: {:error, {:locations_not_n_by_3, locations}}
  end

  defp locations_n_by_3(locations), do: {:error, {:locations_not_n_by_3, locations}}

  defp three_numbers?(location) when is_list(location),
    do: length(location) == 3 and Enum.all?(location, &is_number/1)

  defp three_numbers?(_location), do: false

  defp weights_one_dimensional(weights) when is_list(weights) do
    if Enum.all?(weights, &is_number/1),
      do: :ok,
      else: {:error, {:weights_not_one_dimensional, weights}}
  end

  defp weights_one_dimensional(weights),
    do: {:error, {:weights_not_one_dimensional, weights}}

  defp same_count(locations, weights) do
    if length(locations) == length(weights),
      do: :ok,
      else: {:error, {:count_mismatch, length(locations), length(weights)}}
  end

  @doc "A region of locations that all carry the same weight."
  @spec uniform([location()], float()) :: t()
  def uniform(locations, weight) when weight >= @min_weight and weight <= @max_weight do
    build!(locations, List.duplicate(weight, length(locations)))
  end

  @doc """
  Concatenates regions. No regions is an empty region, which is what the
  attention system sees when nobody proposes anything.
  """
  @spec concat([t()]) :: t()
  def concat(regions) do
    build!(
      Enum.flat_map(regions, & &1.locations),
      Enum.flat_map(regions, & &1.weights)
    )
  end

  # A region built from parts the module itself owns can only be wrong if a
  # caller handed in locations that are not locations; the refusal is a raise
  # here, where there is a caller to see it, and a tuple from `new/2` where
  # there is data arriving from outside.
  defp build!(locations, weights) do
    case new(locations, weights) do
      {:ok, region} -> region
      {:error, reason} -> raise ArgumentError, "invalid attention region: #{inspect(reason)}"
    end
  end

  @doc "True when the region proposes nothing."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{locations: [], weights: []}), do: true
  def empty?(%__MODULE__{}), do: false
end
