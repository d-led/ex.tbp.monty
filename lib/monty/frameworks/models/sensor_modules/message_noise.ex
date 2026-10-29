defmodule Monty.Frameworks.Models.SensorModules.MessageNoise do
  @moduledoc """
  Something that adds noise to a percept, or does not.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::MessageNoise`, the
  protocol a sensor module's noise layer answers.

  Monty passes a numpy `RandomState` that the noise mutates as it draws. Here the
  stream is an argument instead: a noise layer draws from it and answers a
  percept, drawing nothing else afterwards. The stream comes from
  `Monty.Context.rng_for/2`, so it is a function of the episode seed, the
  sensor's id and the step, and of nothing else — which is what makes a run
  replayable (`docs/monty-bugs.md` §2.1).
  """

  alias Monty.Cmp.Message

  @type t :: struct()
  @type rng :: :rand.state()

  @doc "The percept, noisier."
  @callback call(t(), Message.t(), rng()) :: Message.t()
end
