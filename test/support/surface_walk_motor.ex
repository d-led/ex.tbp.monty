defmodule Monty.Test.SurfaceWalkMotor do
  @moduledoc """
  A body that walks one centimetre along +x per step, and never turns.

  The tests that walk a surface in these suites build their object models along
  +x (a `"value"` that rises with x, at the sensor's height), so the body that
  walks them has to move along +x too. `Monty.Simulators.Synthetic.Motor` moves
  the way Monty's actuator does — forward along the agent's local −Z — which is
  right for the studio and wrong for these fixtures: it would carry the sensor
  away from the surface under it.

  A tangential move is the one action that moves the agent without turning it,
  so the sensor keeps its pose relative to the agent and the walk stays on the
  line the models were built on.
  """

  @behaviour Monty.Frameworks.Models.MotorSystem.RuntimeMotorSystem

  alias Monty.Frameworks.Actions.MoveTangentially

  @agent_id "agent_id_0"
  @step 0.01

  @spec new() :: map()
  def new, do: %{}

  @impl true
  def call(state, _ctx, _observations, _proprioceptive_state, _percept, _goals) do
    action = %MoveTangentially{agent_id: @agent_id, distance: @step, direction: [1.0, 0.0, 0.0]}
    {[action], state}
  end

  @doc "Always a plain step: this body never asks the modules to sit one out."
  def motor_only_step(_state), do: false

  @doc "Nothing to forget between episodes."
  def reset(state), do: state
end
