defmodule Monty.Frameworks.Actions.TurnLeft do
  @moduledoc """
  Turn the agent to its left, by a number of degrees.

  Mirrors `tbp/monty/frameworks/actions/actions.py::TurnLeft`. Left is the
  agent's left, not the world's, which is what makes the same action useful
  whichever way the agent happens to be facing.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @enforce_keys [:agent_id, :rotation_degrees]
  defstruct agent_id: nil, rotation_degrees: nil

  @type t :: %__MODULE__{agent_id: atom() | String.t(), rotation_degrees: float()}

  @impl true
  def name, do: "turn_left"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "rotation_degrees" => action.rotation_degrees
    }
  end
end
