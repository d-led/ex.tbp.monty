defmodule Monty.SensorModules.SensorModule.Payload do
  @moduledoc """
  What one sensor module step carries between its transforms.

  Mirrors `tbp/monty/sensor_modules/sensor_module.py::Payload`. A step begins
  with the raw observation and nothing else; each transform in the sensor's
  pipeline may replace the percept, add goals, claim an attention region, and
  write to the telemetry. What comes out of the last transform is what the step
  reports.

  `percept` is `nil` until a transform makes one — which is the whole point of
  the pipeline: a view finder that only measures the scene has no percept to
  send, and saying so is `nil`, not an empty message.
  """

  alias Monty.Cmp.{AttentionRegion, Goal, Message}

  defstruct observation: nil,
            percept: nil,
            goals: [],
            region: nil,
            telemetry: %{}

  @type t :: %__MODULE__{
          observation: map(),
          percept: Message.t() | nil,
          goals: [Goal.t()],
          region: AttentionRegion.t() | nil,
          telemetry: map()
        }
end
