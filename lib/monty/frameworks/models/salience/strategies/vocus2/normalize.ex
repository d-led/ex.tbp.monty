defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Normalize do
  @moduledoc """
  How a finished salience map is brought into a usable range.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::Normalize`,
  a `Protocol` in Monty so a config can name how the map is normalised. It is a
  behaviour here: a salience map in, a salience map out.

  Monty's two are `range_normalize/1` and `no_normalize/1` in
  `Monty.Frameworks.Models.Salience.Strategies.Vocus2`. Range normalisation is
  the default because a salience module's caller decides where to look by
  comparing salience values, and an unnormalised map's scale depends on the
  brightness and detail of the view rather than on how interesting it is.
  """

  @type t :: struct()

  @doc "The map, normalised."
  @callback call(t(), [[float()]]) :: [[float()]]
end
