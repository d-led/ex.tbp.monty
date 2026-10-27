defmodule Monty.Test.RecordingLearningModule do
  @moduledoc """
  A learning module that reports every call to the test process.

  Votes and outputs are configurable per module, so a test can describe the
  wiring it wants to prove without writing another module.
  """

  @behaviour Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

  def new(opts) do
    Map.merge(
      %{
        notify: self(),
        vote: nil,
        output: nil,
        goals: [],
        region: Monty.Cmp.AttentionRegion.empty(),
        seen: []
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
  def reset_stm(state), do: %{state | seen: []}
end
