defmodule Monty.Frameworks.Actions.OrientHorizontal do
  @moduledoc """
  Move in the horizontal plane and turn to face where it went.

  Mirrors `tbp/monty/frameworks/actions/actions.py::OrientHorizontal`, one
  action rather than two because the move and the turn happen together: a body
  that slid sideways without turning would be looking at what it left behind.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :rotation_degrees, :left_distance, :forward_distance]
  defstruct agent_id: nil,
            rotation_degrees: nil,
            left_distance: nil,
            forward_distance: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          rotation_degrees: float(),
          left_distance: float(),
          forward_distance: float()
        }

  @impl true
  def name, do: "orient_horizontal"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "rotation_degrees" => action.rotation_degrees,
      "left_distance" => action.left_distance,
      "forward_distance" => action.forward_distance
    }
  end
end
