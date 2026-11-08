defmodule Monty.Frameworks.Actions.SetAgentPose do
  @moduledoc """
  Put the agent at an absolute place, facing an absolute way.

  Mirrors `tbp/monty/frameworks/actions/actions.py::SetAgentPose`. This is the
  action a goal-reaching policy ends with: everything else is a nudge, and this
  is the one that says "be exactly here".

  The rotation is a `wxyz` quaternion, which is Monty's order for poses and
  therefore this port's, as `Monty.Geometry.Rotation` stores it.
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
  def name, do: "set_agent_pose"

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
