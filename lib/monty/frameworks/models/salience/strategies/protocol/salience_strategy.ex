defmodule Monty.Frameworks.Models.Salience.Strategies.Protocol.SalienceStrategy do
  @moduledoc """
  How a salience module decides where in a view is worth looking.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/protocol.py::SalienceStrategy`,
  a `Protocol` in Monty so a config can name any callable. It is a behaviour
  here: a strategy answers a salience map of the same shape as the depth image —
  one number per pixel saying how interesting that pixel is.

  The `Monty.Context` comes with the images because a strategy may sample — a
  random walk over candidate locations does — and anything that samples has to be
  reproducible from the episode seed (`docs/monty-bugs.md` §2.1).
  """

  @type t :: struct()

  @typedoc "A pixel's depth, rows of numbers."
  @type depth :: [[float()]]

  @typedoc "An RGBA image: rows of pixels, each four channels."
  @type rgba :: [[[float()]]]

  @doc "One salience value per pixel of `depth`."
  @callback call(t(), Monty.Context.t(), rgba(), depth()) :: [[float()]]
end
