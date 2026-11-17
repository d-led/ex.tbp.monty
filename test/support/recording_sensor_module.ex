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
      %{
        pass?: true,
        features?: true,
        location: [0.0, 0.0, 0.0],
        goals: [],
        region: Monty.Cmp.AttentionRegion.empty(),
        notify: self()
      },
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
        process_features_in_lm: state.features?,
        semantic_id: Map.get(state, :semantic_id)
      })

    {percept, state}
  end

  @impl true
  def propose_goals(state), do: {state.goals, state}

  # A test says `draws?: true` when it is standing in for a module whose numbers
  # come from the episode's stream — the salience module's dither, a camera's
  # noise — so that the sensor phase has to be asked one at a time.
  @impl true
  def draws_from_stream?(state), do: Map.get(state, :draws?, false)

  @impl true
  def propose_region(state), do: {state.region, state}

  @impl true
  def reset(state), do: state
end
