defmodule Monty.Frameworks.Actions.SetSensorRotation do
  @moduledoc """
  Turn one sensor, relative to the agent it is attached to.

  Mirrors `tbp/monty/frameworks/actions/actions.py::SetSensorRotation`. This is
  the action a gaze goal ends with: the goal says which way to look, and this
  says how far the eye has to turn to look that way.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :rotation_quat]
  defstruct agent_id: nil, rotation_quat: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          rotation_quat: {float(), float(), float(), float()}
        }

  @impl true
  def name, do: "set_sensor_rotation"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "rotation_quat" => action.rotation_quat
    }
  end
end
