defmodule Monty.Frameworks.Actions.SetYaw do
  @moduledoc """
  Set the agent body's yaw, in degrees.

  Mirrors `tbp/monty/frameworks/actions/actions.py::SetYaw`. Unlike
  `...Actions.TurnLeft` and `...Actions.TurnRight` this names the heading rather
  than the change, so it cannot drift: asking twice for the same heading leaves
  the agent where it was.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :rotation_degrees]
  defstruct agent_id: nil, rotation_degrees: nil

  @type t :: %__MODULE__{agent_id: atom() | String.t(), rotation_degrees: float()}

  @impl true
  def name, do: "set_yaw"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "rotation_degrees" => action.rotation_degrees
    }
  end
end
