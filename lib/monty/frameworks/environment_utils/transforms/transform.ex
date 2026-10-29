defmodule Monty.Frameworks.EnvironmentUtils.Transforms.Transform do
  @moduledoc """
  Something done to observations before any module reads them.

  Mirrors `tbp/monty/frameworks/environment_utils/transforms.py::Transform`:
  Monty's experiments configure a list of these on the environment interface, and
  they run in order — replacing missing depth with a far value, turning a depth
  image into a point cloud, adding noise. They are the layer between "what the
  simulator rendered" and "what a sensor module is given".

  A transform answers the observations it was given, changed; it is a value, so
  `call/2` takes it as its second argument rather than the transform changing
  itself.
  """

  @type t :: struct()
  @type observations :: map()

  @typedoc """
  Where the agents and their sensors were: what a transform needs to put a
  pixel's depth where it belongs in the world. `nil` when a transform is run
  without it.
  """
  @type state :: Monty.Frameworks.Models.MotorSystemState.ProprioceptiveState.t() | nil

  @doc "The observations, changed by `transform`."
  @callback call(observations(), t(), state()) :: observations()
end
