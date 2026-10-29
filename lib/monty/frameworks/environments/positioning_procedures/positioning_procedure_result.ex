defmodule Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedureResult do
  @moduledoc """
  What a positioning procedure decided, and why it stopped.

  Mirrors
  `tbp/monty/frameworks/environments/positioning_procedures.py::PositioningProcedureResult`.
  Three endings, and a procedure says which one it reached: `success` the sensor
  ended up on the object, `terminated` it is done (which is also how a successful
  step ends), and `truncated` it gave up — no attempt left to turn towards the
  object, so the episode starts with the sensor where it happens to be.
  """

  defstruct actions: [], success: false, terminated: false, truncated: false

  @type action :: Monty.Frameworks.Actions.Action.t()

  @type t :: %__MODULE__{
          actions: [action()],
          success: boolean(),
          terminated: boolean(),
          truncated: boolean()
        }
end
