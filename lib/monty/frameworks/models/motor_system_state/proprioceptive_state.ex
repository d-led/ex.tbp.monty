defmodule Monty.Frameworks.Models.MotorSystemState.ProprioceptiveState do
  @moduledoc """
  What the environment says about every agent it contains.

  Mirrors `tbp/monty/frameworks/models/motor_system_state.py::ProprioceptiveState`,
  which is a `dict[AgentID, AgentState]` and nothing more. Here it is that map,
  under a type, so a signature can say "the environment's account of the body"
  rather than `map()`.
  """

  alias Monty.Frameworks.Models.MotorSystemState.AgentState

  @type agent_id :: atom() | String.t()

  @type t :: %{optional(agent_id()) => AgentState.t()}
end
