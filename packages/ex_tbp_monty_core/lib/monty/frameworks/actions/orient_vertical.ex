defmodule Monty.Frameworks.Actions.OrientVertical do
  @moduledoc """
  Move in the vertical plane and turn to face where it went.

  Mirrors `tbp/monty/frameworks/actions/actions.py::OrientVertical`, the
  vertical counterpart of `...Actions.OrientHorizontal`: down and forward at
  once, with the turn that keeps the agent facing the move.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :rotation_degrees, :down_distance, :forward_distance]
  defstruct agent_id: nil,
            rotation_degrees: nil,
            down_distance: nil,
            forward_distance: nil

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          rotation_degrees: float(),
          down_distance: float(),
          forward_distance: float()
        }

  @impl true
  def name, do: "orient_vertical"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "rotation_degrees" => action.rotation_degrees,
      "down_distance" => action.down_distance,
      "forward_distance" => action.forward_distance
    }
  end
end
