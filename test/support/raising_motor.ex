defmodule Monty.Test.RaisingMotor do
  @moduledoc """
  A motor system that raises on a chosen call, so a test can watch a step die.

  A surface agent's policy raises when its belief and the world disagree, and
  that raise is the run's ending: what the run keeps of it is the point here, not
  the policy that produced it.

  The failure is on the `fail_call`th call rather than on every one. A motor that
  can only ever raise is a function dialyzer rightly calls `no_return`, and a
  double should be a possible function.
  """

  @behaviour Monty.Frameworks.Models.MotorSystem.RuntimeMotorSystem

  defstruct message: "the motor disagreed", calls: 0, fail_call: 1

  @spec new(String.t()) :: %__MODULE__{}
  def new(message \\ "the motor disagreed"), do: %__MODULE__{message: message}

  @impl true
  def call(%__MODULE__{} = motor, _ctx, _observations, _proprioceptive_state, _percept, _goals) do
    calls = motor.calls + 1
    motor = %{motor | calls: calls}

    if calls == motor.fail_call do
      raise motor.message
    else
      {[], motor}
    end
  end

  @doc "A motor system is never the only module that has something to say."
  def motor_only_step(_state), do: false

  @doc "Forgets what the previous episode taught."
  def reset(state), do: state
end
