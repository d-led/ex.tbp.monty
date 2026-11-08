defmodule Monty.Frameworks.Actions.SetSensorPitch do
  @moduledoc """
  Set how far one sensor is pitched, in degrees.

  Mirrors `tbp/monty/frameworks/actions/actions.py::SetSensorPitch`: the eye
  turns while the body stays where it is, which is the difference between this
  and `...Actions.SetAgentPitch`.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :pitch_degrees]
  defstruct agent_id: nil, pitch_degrees: nil

  @type t :: %__MODULE__{agent_id: atom() | String.t(), pitch_degrees: float()}

  @impl true
  def name, do: "set_sensor_pitch"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{"action" => name(), "agent_id" => action.agent_id, "pitch_degrees" => action.pitch_degrees}
  end
end
