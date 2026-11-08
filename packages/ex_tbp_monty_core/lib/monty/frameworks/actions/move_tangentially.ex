defmodule Monty.Frameworks.Actions.MoveTangentially do
  @moduledoc """
  Move the agent sideways across the surface it is facing.

  Mirrors `tbp/monty/frameworks/actions/actions.py::MoveTangentially`. The
  direction is in the agent's own frame — a vector, not an angle — which is what
  lets a surface policy ask for a move along a principal curvature.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :distance, :direction]
  defstruct agent_id: nil, distance: nil, direction: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          distance: float(),
          direction: [float()]
        }

  @impl true
  def name, do: "move_tangentially"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "distance" => action.distance,
      "direction" => action.direction
    }
  end
end
