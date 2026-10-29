defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.OperatingLimits do
  @moduledoc """
  What an image has to be for an attention model to mean anything on it.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::OperatingLimits`,
  a `Protocol` in Monty. A sigma is a *distance in pixels*, so the same sigma
  means a broad blur on a small image and a tight one on a large image; limits
  are how "these numbers were only ever tried on images this size" is enforced
  instead of remembered.

  Monty answers a `ValueError` or `None`; a behaviour cannot answer an exception,
  so this answers `:ok` or `{:error, message}` and the caller decides whether to
  raise (which is what Monty does unless the run suppresses runtime errors).
  """

  @type t :: struct()

  @typedoc "Why these numbers are outside the limits, in a sentence."
  @type rejection :: {:error, String.t()}

  @doc """
  Whether a `sigma` pair is usable on an image whose smallest side is
  `min_image_dim_size`.
  """
  @callback validate(t(), pos_integer(), float(), float()) :: :ok | rejection()
end
