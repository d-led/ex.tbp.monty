defmodule Monty.Simulators.Synthetic.Motor do
  @moduledoc """
  A motor system that always takes one small step forward.

  Mirrors the smallest useful `MotorSystem`: it receives the first sensor
  module's percept and the filtered goals, and returns the actions for the next
  environment step plus whether this step was motor-only.
  """

  @behaviour Monty.Frameworks.Models.AbstractMontyClasses.MotorSystem

  @type state :: %{steps_taken: non_neg_integer(), goals_seen: non_neg_integer()}

  @spec new() :: state()
  def new, do: %{steps_taken: 0, goals_seen: 0}

  @impl true
  def act(request, state) do
    action = %{"action" => "move_forward", "agent_id" => "agent_id_0", "distance" => 0.01}

    {[action], %{state | steps_taken: state.steps_taken + 1, goals_seen: length(request.goals)},
     false}
  end

  @impl true
  def reset(state), do: %{state | goals_seen: 0}
end
