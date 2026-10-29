defmodule Monty.Test.RecordingSensorModule do
  @moduledoc """
  A sensor module that reports every call to the test process.

  The report is what makes ordering testable: a test asserts the sequence of
  messages it receives, which is the same thing the runtime promises.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.Test.Messages

  def new(opts) do
    Map.merge(
      %{pass?: true, features?: true, location: [0.0, 0.0, 0.0], notify: self()},
      Map.new(opts)
    )
  end

  @impl true
  def update_state(agent_state, state) do
    send(state.notify, {:sensor_state, state.id, agent_state})
    state
  end

  @impl true
  def step(observation, motor_only?, _ctx, state) do
    send(state.notify, {:sensor_step, state.id, motor_only?, observation})

    percept =
      Messages.percept(%{
        location: state.location,
        sender_id: to_string(state.id),
        pass_message: state.pass? and not motor_only?,
        process_features_in_lm: state.features?
      })

    {percept, state}
  end

  @impl true
  def reset(state), do: state
end
