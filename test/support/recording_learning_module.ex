defmodule Monty.Test.RecordingLearningModule do
  @moduledoc """
  A learning module that reports every call to the test process.

  Votes and outputs are configurable per module, so a test can describe the
  wiring it wants to prove without writing another module.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

  def new(opts) do
    Map.merge(
      %{
        notify: self(),
        vote: nil,
        output: nil,
        goals: [],
        region: Monty.Cmp.AttentionRegion.empty(),
        seen: [],
        terminal: nil,
        processed?: false,
        mode: nil
      },
      Map.new(opts)
    )
  end

  @impl true
  def matching_step(percepts, ctx, state) do
    send(state.notify, {:learning_step, state.id, percepts, ctx.mode})
    {:ok, %{state | seen: state.seen ++ percepts}}
  end

  @impl true
  def exploratory_step(percepts, ctx, state) do
    send(state.notify, {:exploratory_step, state.id, percepts, ctx.mode})
    {:ok, %{state | seen: state.seen ++ percepts}}
  end

  @impl true
  def send_out_vote(state) do
    send(state.notify, {:send_vote, state.id})
    {state.vote || state.id, state}
  end

  @impl true
  def receive_votes(votes, state) do
    send(state.notify, {:receive_votes, state.id, votes})
    {:ok, state}
  end

  @impl true
  def propose_goals(state) do
    send(state.notify, {:propose_goals, state.id})
    {state.goals, state}
  end

  @impl true
  def propose_region(state), do: {state.region, state}

  @impl true
  def get_output(state), do: {state.output, state}

  @impl true
  def reset_stm(state), do: %{state | seen: [], processed?: false}

  @impl true
  def add_lm_processing_to_buffer_stats(state, processed) do
    send(state.notify, {:lm_processing, state.id, processed})
    %{state | processed?: processed}
  end

  @impl true
  def observation_processed?(state), do: state.processed?

  @impl true
  def update_terminal_condition(state) do
    send(state.notify, {:update_terminal_condition, state.id})
    {state, state.terminal}
  end

  @impl true
  def set_terminal_state(state, terminal_state) do
    send(state.notify, {:set_terminal_state, state.id, terminal_state})
    %{state | terminal: terminal_state}
  end

  @impl true
  def set_experiment_mode(state, mode) do
    send(state.notify, {:set_experiment_mode, state.id, mode})
    %{state | mode: mode}
  end

  @impl true
  def update_ltm_from_stm(state) do
    send(state.notify, {:update_ltm, state.id})
    state
  end
end
