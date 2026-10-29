defmodule Monty.SensorModules.SensorModule.Transform do
  @moduledoc """
  One stage of a sensor module's pipeline.

  Mirrors `tbp/monty/sensor_modules/sensor_module.py::Transform`, which Monty
  declares as a `Protocol` so a config can name any callable. Here it is a
  behaviour, and the sensor module stores each transform as `{module, transform}`
  — the module that knows how to call it, and the config that says how.

  A transform answers the payload it was given, changed. It may make a percept
  from the observation, add goals, claim a region, or write telemetry; it may
  also pass the payload through untouched, which is what a stage for a feature
  this run does not use does.

  ## Why it also answers itself

  Monty's transforms are objects that keep state: a smoothing filter remembers
  the frames it has seen, a background model remembers the background. In Elixir
  a struct cannot be mutated, so a transform answers the transform it leaves
  behind — `{payload, transform}` — and the sensor module keeps that one for the
  next step. Same reason samplers answer their stream (`docs/monty-bugs.md`
  §2.5), and the reason a reset has something to reset (§2.13).
  """

  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}

  @type t :: struct()

  @doc "The payload transformed, and the transform that transformed it."
  @callback call(t(), TransformContext.t(), Payload.t()) :: {Payload.t(), t()}
end
