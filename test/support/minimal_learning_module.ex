defmodule Monty.Test.MinimalLearningModule do
  @moduledoc """
  A learning module that implements only the required callbacks, as plainly as
  they can be implemented.

  Exists to prove the behaviour's defaults: a module that says nothing about
  goals, regions or output proposes nothing and emits nothing, like Monty's
  base class. It also never concludes anything, which is what a module with no
  algorithm left to run looks like to the model.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

  @doc "The only state this module needs is its own id, and whether it processed the last step."
  @spec new(atom() | String.t()) :: %{id: atom() | String.t(), processed?: boolean()}
  def new(id), do: %{id: id, processed?: false}

  @impl true
  def matching_step(_percepts, _ctx, state), do: {:ok, state}

  @impl true
  def exploratory_step(_percepts, _ctx, state), do: {:ok, state}

  @impl true
  def send_out_vote(state), do: {nil, state}

  @impl true
  def receive_votes(_votes, state), do: {:ok, state}

  @impl true
  def reset_stm(state), do: %{state | processed?: false}

  @impl true
  def add_lm_processing_to_buffer_stats(state, processed), do: %{state | processed?: processed}

  @impl true
  def observation_processed?(state), do: state.processed?

  @impl true
  def update_terminal_condition(state), do: {state, nil}

  @impl true
  def set_terminal_state(state, _terminal_state), do: state

  @impl true
  def set_experiment_mode(state, _mode), do: state

  @impl true
  def update_ltm_from_stm(state), do: state

  @impl true
  def set_target(state, _primary_target), do: state

  @impl true
  def set_stepwise_target(state, _label), do: state

  @impl true
  def fixme_update_ground_truth(state), do: state
end
