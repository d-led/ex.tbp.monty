defmodule Monty.Simulators.Synthetic.Motor do
  @moduledoc """
  A motor system that always takes one small step forward.

  The smallest thing that implements the ported motor system interface: it
  receives the first sensor module's percept and the filtered goals, and answers
  the actions for the next environment step.
  """

  @behaviour Monty.Frameworks.Models.MotorSystem.RuntimeMotorSystem

  @type state :: %{steps_taken: non_neg_integer(), goals_seen: non_neg_integer()}

  @spec new() :: state()
  def new, do: %{steps_taken: 0, goals_seen: 0}

  @impl true
  def call(state, _ctx, _observations, _proprioceptive_state, _percept, goals) do
    action = %{"action" => "move_forward", "agent_id" => "agent_id_0", "distance" => 0.01}

    {[action], %{state | steps_taken: state.steps_taken + 1, goals_seen: length(goals)}}
  end

  @doc "Whether learning modules should sit this step out: never, for a plain step."
  def motor_only_step(_state), do: false

  @doc "Forgets the previous episode's count, keeping the goals it was given."
  def reset(state), do: %{state | goals_seen: 0}
end
