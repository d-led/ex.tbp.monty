defmodule Monty.Frameworks.Models.MotorSystemState do
  @moduledoc """
  Where the body is: the motor system's view of the agents it moves.

  Mirrors `tbp/monty/frameworks/models/motor_system_state.py`, which holds four
  names:

    * `...MotorSystemState.SensorState` and `...MotorSystemState.AgentState` —
      **ported**: one sensor's place and turn, and one agent's place, turn and
      sensors;
    * `...MotorSystemState.ProprioceptiveState` — **ported**: what the
      environment reports, a map of agent id to `AgentState`;
    * `...MotorSystemState` (this module) — **ported**: what the motor system
      works with, which Monty describes as the proprioceptive state "as well as
      any state that the motor system needs for operation".

  The last two are separate classes in Monty because they are separate *ideas*,
  but both are plain dictionaries with no behaviour, so `t/0` here is the same
  shape as `ProprioceptiveState.t/0` until the motor system has state of its
  own to add. A caller that means "what the environment said" should still say
  so, because that is where the distinction will have to be made.
  """

  alias Monty.Frameworks.Models.MotorSystemState.AgentState

  @type agent_id :: atom() | String.t()

  @type t :: %{optional(agent_id()) => AgentState.t()}
end
