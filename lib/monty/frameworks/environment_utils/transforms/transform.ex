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

  alias Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext

  @type t :: struct()
  @type observations :: map()

  @doc """
  The observations, changed by `transform`.

  The context carries what a transform may need beyond the observations: where
  the agents and their sensors were, and the random stream this transform may
  draw from at this step.
  """
  @callback call(observations(), t(), TransformContext.t()) :: observations()
end
