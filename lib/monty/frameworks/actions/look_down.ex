defmodule Monty.Frameworks.Actions.LookDown do
  @moduledoc """
  Turn the agent downwards, by a number of degrees.

  Mirrors `tbp/monty/frameworks/actions/actions.py::LookDown`. `constraint_degrees`
  is the step left before the environment refuses: an agent that keeps looking
  down stops at its own body rather than passing through it.
  """

  @behaviour Monty.Frameworks.Actions.Action

  @default_constraint_degrees 90.0

  @enforce_keys [:agent_id, :rotation_degrees]
  defstruct agent_id: nil, rotation_degrees: nil, constraint_degrees: @default_constraint_degrees

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          rotation_degrees: float(),
          constraint_degrees: float()
        }

  @impl true
  def name, do: "look_down"

  @impl true
  def to_map(%__MODULE__{} = action) do
    %{
      "action" => name(),
      "agent_id" => action.agent_id,
      "rotation_degrees" => action.rotation_degrees,
      "constraint_degrees" => action.constraint_degrees
    }
  end
end
