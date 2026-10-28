defmodule Monty.Frameworks.Actions.SetAgentPitch do
  @moduledoc """
  Set how far the agent's body is pitched, in degrees.

  Mirrors `tbp/monty/frameworks/actions/actions.py::SetAgentPitch`. The sensors
  keep their orientation relative to the agent unless something changes it, so
  this pitches the agent's sensors too — which is why a policy that wants to
  pitch only the eye asks `...Actions.SetSensorPitch` instead.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :pitch_degrees]
  defstruct agent_id: nil, pitch_degrees: nil

  @type t :: %__MODULE__{agent_id: atom() | String.t(), pitch_degrees: float()}

  @impl true
  def name, do: "set_agent_pitch"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{"action" => name(), "agent_id" => action.agent_id, "pitch_degrees" => action.pitch_degrees}
  end
end
