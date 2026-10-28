defmodule Monty.Frameworks.Actions.MoveForward do
  @moduledoc """
  Move the agent forward by a distance.

  Mirrors `tbp/monty/frameworks/actions/actions.py::MoveForward`. Forward means
  along the agent's own facing, and the distance is in metres.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :distance]
  defstruct agent_id: nil, distance: nil

  @type t :: %__MODULE__{agent_id: atom() | String.t(), distance: float()}

  @impl true
  def name, do: "move_forward"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{"action" => name(), "agent_id" => action.agent_id, "distance" => action.distance}
  end
end
