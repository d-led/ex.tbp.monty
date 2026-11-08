defmodule Monty.Frameworks.Models.SensorModules.MessageNoise do
  @moduledoc """
  Something that adds noise to a percept, or does not.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::MessageNoise`, the
  protocol a sensor module's noise layer answers.

  Monty passes a numpy `RandomState` that the noise mutates as it draws. Here the
  stream is an argument instead: a noise layer draws from it and answers a
  percept. It is the episode's one stream (`Monty.Random.Stream`), the same one
  the motor system and the goal generators draw from, because it is the same one
  in Monty — so the draws a noisy percept makes move the numbers of everything
  stepped after it (`docs/monty-differences.md` §2.1).
  """

  alias Monty.Cmp.Message

  @type t :: struct()
  @type rng :: GenServer.server()

  @doc "The percept, noisier."
  @callback call(t(), Message.t(), rng()) :: Message.t()
end
