defmodule Monty.Test.RecordingMotor do
  @moduledoc "A motor system that reports what it was given and returns one action."

  @behaviour Monty.Frameworks.Models.AbstractMontyClasses.MotorSystem

  def new(opts \\ []), do: Map.merge(%{notify: self(), motor_only?: false}, Map.new(opts))

  @impl true
  def act(request, state) do
    send(state.notify, {:motor, request.percept, request.goals})
    {[%{"action" => "noop"}], state, state.motor_only?}
  end

  @impl true
  def reset(state), do: state
end
