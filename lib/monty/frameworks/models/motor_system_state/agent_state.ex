defmodule Monty.Frameworks.Models.MotorSystemState.AgentState do
  @moduledoc """
  Where one agent is, how it is turned, and where its sensors are.

  Mirrors `tbp/monty/frameworks/models/motor_system_state.py::AgentState`. The
  sensors are keyed by sensor id, and their positions and rotations are relative
  to this agent's — which is what lets an environment move an agent without
  rewriting every sensor.
  """

  alias Monty.Frameworks.Models.MotorSystemState.SensorState

  @enforce_keys [:sensors, :position, :rotation]
  defstruct sensors: %{}, position: [0.0, 0.0, 0.0], rotation: nil

  @type sensor_id :: atom() | String.t()

  @type t :: %__MODULE__{
          sensors: %{optional(sensor_id()) => SensorState.t()},
          position: [float()],
          rotation: Monty.Geometry.Rotation.t()
        }
end
