defmodule Monty.Test.RecordingMotor do
  @moduledoc "A motor system that reports what it was given and returns one action."

  @behaviour Monty.Frameworks.Models.MotorSystem.RuntimeMotorSystem

  def new(opts \\ []), do: Map.merge(%{notify: self(), motor_only?: false}, Map.new(opts))

  @impl true
  def call(state, _ctx, _observations, _proprioceptive_state, percept, goals) do
    send(state.notify, {:motor, percept, goals})
    {[%{"action" => "noop"}], state}
  end

  @doc "Whether learning modules should sit this step out."
  def motor_only_step(state), do: state.motor_only?

  @doc "Forgets what the previous episode taught."
  def reset(state), do: state
end
