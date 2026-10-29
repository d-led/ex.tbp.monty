defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.MapCombine do
  @moduledoc """
  How several feature maps become one salience map.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::MapCombine`,
  a `Protocol` in Monty so a config can name how its channels are combined. It
  is a behaviour here: named maps in — `"L"`, `"a"`, `"b"`, `"depth"`,
  `"orientation"` — and one map of the same shape out.

  Monty's plain functions are `map_max/1`, `map_sum/1`, `map_mean/1` in
  `Monty.Frameworks.Models.Salience.Strategies.Vocus2`; the weighted ones, which
  need configuration, are `WeightedSum` and `WeightedMean`.
  """

  @type t :: struct()

  @typedoc "One map per feature, all the same shape."
  @type maps :: %{optional(String.t()) => [[float()]]}

  @doc "The maps reduced to one, pixel by pixel."
  @callback call(t(), maps()) :: [[float()]]
end
