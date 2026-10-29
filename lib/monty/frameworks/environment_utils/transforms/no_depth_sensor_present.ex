defmodule Monty.Frameworks.EnvironmentUtils.Transforms.NoDepthSensorPresent do
  @moduledoc """
  A transform that needs a depth image was given observations without one.

  Mirrors
  `tbp/monty/frameworks/environment_utils/transforms.py::NoDepthSensorPresent`.
  Monty raises it from the transforms that work on depth, and its message says
  what to do about it: the experiment configured a depth transform for a sensor
  that has no depth.

  Raised rather than returned, because a run whose depth transforms silently did
  nothing would look like a run of a different experiment — and a noisy one and a
  clean one would produce the same numbers.
  """

  defexception message: "NO DEPTH SENSOR PRESENT. Don't use this transform"
end
