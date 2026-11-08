defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images.ColorSpaceConverter do
  @moduledoc """
  How a salience strategy turns the camera's colour image into the channels it
  reasons about.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/images.py::ColorSpaceConverter`,
  a `Protocol` in Monty, so a strategy can name any function with this shape.
  It is a behaviour here: an RGB image in, a float image out, one channel or
  several, shifted and scaled so that `[0, 1]` is the whole range.

  Monty's three converters — `rgb_to_lab/1`, `rgb_to_opponent/1` and
  `rgb_to_opponent_codi/1` — are plain functions in the module beside this one
  and are not instances of the protocol; they match its shape, which is all
  either needs.
  """

  @type t :: struct()

  @typedoc "An RGB image: rows of pixels, each three channels, `0..255` as read."
  @type rgb :: [[[float()]]]

  @doc "The image in the converter's colour space."
  @callback call(t(), rgb()) :: [[[float()]]]
end
