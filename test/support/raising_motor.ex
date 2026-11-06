defmodule Monty.Test.RaisingMotor do
  @moduledoc """
  A motor system that raises, so a test can watch what a step that died becomes.

  A surface agent's policy raises when its belief and the world disagree, and
  that raise is the run's ending: what the run keeps of it is the point here, not
  the policy that produced it.
  """

  @behaviour Monty.Frameworks.Models.MotorSystem.RuntimeMotorSystem

  defstruct message: "the motor disagreed"

  @spec new(String.t()) :: %__MODULE__{}
  def new(message \\ "the motor disagreed"), do: %__MODULE__{message: message}

  @impl true
  def call(
        %__MODULE__{message: message},
        _ctx,
        _observations,
        _proprioceptive_state,
        _percept,
        _goals
      ),
      do: raise(message)

  @doc "A motor system is never the only module that has something to say."
  def motor_only_step(_state), do: false

  @doc "Forgets what the previous episode taught."
  def reset(state), do: state
end
