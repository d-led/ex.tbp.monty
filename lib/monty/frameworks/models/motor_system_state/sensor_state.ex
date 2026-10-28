defmodule Monty.Frameworks.Models.MotorSystemState.SensorState do
  @moduledoc """
  Where one sensor is, and how it is turned.

  Mirrors `tbp/monty/frameworks/models/motor_system_state.py::SensorState`.
  Inside an `AgentState` the position and rotation are relative to the agent's
  own; taken straight from the environment they are in the environment's frame.
  Monty notes the rotation is still a `quaternion.quaternion` while the project
  settles on one representation; here it is a `Monty.Geometry.Rotation`, which
  is the representation the rest of this port uses.
  """

  @enforce_keys [:position, :rotation]
  defstruct [:position, :rotation]

  @type t :: %__MODULE__{
          position: [float()],
          rotation: Monty.Geometry.Rotation.t()
        }
end
