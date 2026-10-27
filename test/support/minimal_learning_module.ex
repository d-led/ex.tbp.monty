defmodule Monty.Test.MinimalLearningModule do
  @moduledoc """
  A learning module that implements only the required callbacks.

  Exists to prove the behaviour's defaults: a module that says nothing about
  goals, regions or output proposes nothing and emits nothing, like Monty's
  base class.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

  @doc "The only state this module needs is its own id."
  @spec new(atom() | String.t()) :: %{id: atom() | String.t()}
  def new(id), do: %{id: id}

  @impl true
  def matching_step(_percepts, _ctx, state), do: {:ok, state}

  @impl true
  def exploratory_step(_percepts, _ctx, state), do: {:ok, state}

  @impl true
  def send_out_vote(state), do: {nil, state}

  @impl true
  def receive_votes(_votes, state), do: {:ok, state}

  @impl true
  def reset_stm(state), do: state
end
