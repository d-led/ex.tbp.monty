defmodule Monty.Runtime.LearningModuleServer do
  @moduledoc """
  One learning module, one process — a cortical column with a mailbox.

  The process is deliberately thin: `matching_step`, `send_out_vote`,
  `receive_votes` and the rest are callbacks on a pure module
  (`Monty.Frameworks.Models.AbstractMontyClasses.LearningModule`), and the
  order in which they are called belongs to `Monty.Runtime.Step`, not here.

  Keeping the algorithm out of the GenServer is what makes the column
  testable twice over: directly as a function, and through the process for the
  things only a process has — isolation, restart, mailbox ordering.
  """

  use GenServer

  alias Monty.Runtime.Registry

  @type spec :: %{
          required(:id) => atom() | String.t(),
          required(:model_id) => atom() | String.t(),
          required(:module) => module(),
          required(:state) => term()
        }

  @spec start_link(spec()) :: GenServer.on_start()
  def start_link(%{id: id, model_id: model_id} = spec) do
    GenServer.start_link(__MODULE__, spec, name: Registry.via({:learning_module, model_id, id}))
  end

  def child_spec(%{id: id, model_id: model_id} = spec) do
    %{
      id: {:learning_module, model_id, id},
      start: {__MODULE__, :start_link, [spec]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def init(spec) do
    {:ok, %{module: spec.module, state: spec.state, id: spec.id}}
  end

  @impl true
  def handle_call({:matching_step, percepts, ctx}, _from, server) do
    {:ok, state} = server.module.matching_step(percepts, ctx, server.state)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call({:exploratory_step, percepts, ctx}, _from, server) do
    {:ok, state} = server.module.exploratory_step(percepts, ctx, server.state)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call(:send_out_vote, _from, %{module: module, state: state} = server) do
    {vote, state} = module.send_out_vote(state)
    {:reply, vote, %{server | state: state}}
  end

  def handle_call({:receive_votes, votes}, _from, server) do
    {:ok, state} = server.module.receive_votes(votes, server.state)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call(:propose_goals, _from, %{module: module, state: state} = server) do
    {goals, state} = optional(module, :propose_goals, state, [])
    {:reply, goals, %{server | state: state}}
  end

  def handle_call(:propose_region, _from, %{module: module, state: state} = server) do
    {region, state} = optional(module, :propose_region, state, Monty.Cmp.AttentionRegion.empty())
    {:reply, region, %{server | state: state}}
  end

  def handle_call(:get_output, _from, %{module: module, state: state} = server) do
    {output, state} = optional(module, :get_output, state, nil)
    {:reply, output, %{server | state: state}}
  end

  def handle_call(:reset_stm, _from, %{module: module, state: state} = server) do
    {:reply, :ok, %{server | state: module.reset_stm(state)}}
  end

  def handle_call(:state, _from, server), do: {:reply, server.state, server}

  defp optional(module, function, state, default) do
    if function_exported?(module, function, 1),
      do: apply(module, function, [state]),
      else: {default, state}
  end
end
