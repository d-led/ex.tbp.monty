defmodule Monty.Experiment.SensorModule.ExperimentTransform do
  @moduledoc """
  A transform that can also forget what it has seen.

  Mirrors `tbp/monty/experiment/sensor_module.py::ExperimentTransform`, which
  Monty declares as `Transform` plus a `reset` — the experimental affordance that
  lets an episode start clean. A transform that keeps running state (a smoothing
  filter, a background model) implements this behaviour; one that does not
  implements `Monty.SensorModules.SensorModule.Transform` alone, and the wrapper
  leaves it be.

  In Python the difference is checked with `isinstance(transform,
  ExperimentTransform)`. Here it is `function_exported?(module, :reset, 1)`: a
  transform either has the callback or it does not.
  """

  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}

  @type t :: struct()

  @doc "The payload transformed, and the transform that transformed it."
  @callback call(t(), TransformContext.t(), Payload.t()) :: {Payload.t(), t()}

  @doc "Forgets whatever the last episode left in the transform."
  @callback reset(t()) :: t()
end
