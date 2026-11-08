defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.PyramidCollapse do
  @moduledoc """
  How a pyramid becomes one image again.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/pyramids.py::PyramidCollapse`,
  a `Protocol` in Monty so a config can name how its scales are brought back
  together. It is a behaviour here: every plane is enlarged to the finest
  plane's shape and then reduced to one image.

  Monty's own are `collapse/2` in the module beside this one, called with a
  reducer of the caller's choosing.
  """

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @type t :: struct()

  @doc "One image from every plane of `pyramid`."
  @callback call(t(), Pyramid.t()) :: [[float()]]
end
