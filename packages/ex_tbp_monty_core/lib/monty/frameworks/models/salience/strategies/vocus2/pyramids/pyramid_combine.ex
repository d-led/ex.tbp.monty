defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.PyramidCombine do
  @moduledoc """
  How several pyramids become one.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/pyramids.py::PyramidCombine`,
  a `Protocol` in Monty so a config can name how its maps are combined. It is a
  behaviour here: a combiner answers one pyramid from several of the same shape.

  Monty's implementations — maximum and mean — are `combine_max/1` and
  `combine_mean/1` in the module beside this one; they are plain functions that
  match this shape rather than instances of the protocol.
  """

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @type t :: struct()

  @doc "One pyramid, from `pyramids`, which all have the same shape."
  @callback call(t(), [Pyramid.t()]) :: Pyramid.t()
end
