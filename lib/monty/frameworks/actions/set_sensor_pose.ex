defmodule Monty.Frameworks.Actions.SetSensorPose do
  @moduledoc """
  Put one sensor at an absolute place, facing an absolute way.

  Mirrors `tbp/monty/frameworks/actions/actions.py::SetSensorPose`. The pose is
  in the environment's frame, not the agent's, unlike the sensor state inside an
  `AgentState` — an action names a place in the world.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :location, :rotation_quat]
  defstruct agent_id: nil, location: nil, rotation_quat: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          location: [float()],
          rotation_quat: {float(), float(), float(), float()}
        }

  @impl true
  def name, do: "set_sensor_pose"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "location" => action.location,
      "rotation_quat" => action.rotation_quat
    }
  end
end
