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

  The client API below is the only way in, so call sites read as
  `LearningModuleServer.matching_step(server, percepts, ctx)` and every entry
  point carries a typespec.
  """

  use GenServer

  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Runtime.Registry

  @type id :: atom() | String.t()

  @type spec :: %{
          required(:id) => id(),
          required(:model_id) => id(),
          required(:module) => module(),
          required(:state) => term()
        }

  @type server :: GenServer.server()
  @type percepts :: [Message.t()]
  @type vote :: term()

  # -- client API -----------------------------------------------------------

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

  @spec matching_step(server(), percepts(), Monty.Context.t()) :: :ok
  def matching_step(server, percepts, ctx) do
    GenServer.call(server, {:matching_step, percepts, ctx}, :infinity)
  end

  @spec exploratory_step(server(), percepts(), Monty.Context.t()) :: :ok
  def exploratory_step(server, percepts, ctx) do
    GenServer.call(server, {:exploratory_step, percepts, ctx}, :infinity)
  end

  @doc "Sends what this module believes, for the vote round to combine."
  @spec send_out_vote(server()) :: vote()
  def send_out_vote(server), do: GenServer.call(server, :send_out_vote, :infinity)

  @spec receive_votes(server(), [vote()]) :: :ok
  def receive_votes(server, votes), do: GenServer.call(server, {:receive_votes, votes}, :infinity)

  @spec propose_goals(server()) :: [Goal.t()]
  def propose_goals(server), do: GenServer.call(server, :propose_goals, :infinity)

  @spec propose_region(server()) :: AttentionRegion.t()
  def propose_region(server), do: GenServer.call(server, :propose_region, :infinity)

  @doc """
  The module's top-down output, or `nil`.

  Read at the start of a step; the coordinator decides whether it is
  delivered (the receiver must also have seen a sensor percept).
  """
  @spec get_output(server()) :: Message.t() | nil
  def get_output(server), do: GenServer.call(server, :get_output, :infinity)

  @spec reset_stm(server()) :: :ok
  def reset_stm(server), do: GenServer.call(server, :reset_stm, :infinity)

  @doc "Records whether this step's observation reached the module."
  @spec add_lm_processing_to_buffer_stats(server(), boolean()) :: :ok
  def add_lm_processing_to_buffer_stats(server, processed),
    do: GenServer.call(server, {:add_lm_processing_to_buffer_stats, processed}, :infinity)

  @doc "Whether the last buffered observation was one this module processed."
  @spec observation_processed?(server()) :: boolean()
  def observation_processed?(server),
    do: GenServer.call(server, :observation_processed?, :infinity)

  @doc "Checks the module's terminal condition and replies with what it concluded."
  @spec update_terminal_condition(server()) :: term()
  def update_terminal_condition(server),
    do: GenServer.call(server, :update_terminal_condition, :infinity)

  @doc "Times the module out without asking it to reconsider."
  @spec set_terminal_state(server(), term()) :: :ok
  def set_terminal_state(server, terminal_state),
    do: GenServer.call(server, {:set_terminal_state, terminal_state}, :infinity)

  @doc "Tells the module whether this episode trains or evaluates."
  @spec set_experiment_mode(server(), term()) :: :ok
  def set_experiment_mode(server, mode),
    do: GenServer.call(server, {:set_experiment_mode, mode}, :infinity)

  @doc "Folds the episode into long-term memory, if it was a training episode."
  @spec update_ltm_from_stm(server()) :: :ok
  def update_ltm_from_stm(server), do: GenServer.call(server, :update_ltm_from_stm, :infinity)

  @doc "The module's own state, for tests and the run inspector."
  @spec state(server()) :: term()
  def state(server), do: GenServer.call(server, :state, :infinity)

  # -- callbacks ------------------------------------------------------------

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

  def handle_call(:send_out_vote, _from, server) do
    {vote, state} = server.module.send_out_vote(server.state)
    {:reply, vote, %{server | state: state}}
  end

  def handle_call({:receive_votes, votes}, _from, server) do
    {:ok, state} = server.module.receive_votes(votes, server.state)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call(:propose_goals, _from, server) do
    {goals, state} = server.module.propose_goals(server.state)
    {:reply, goals, %{server | state: state}}
  end

  def handle_call(:propose_region, _from, server) do
    {region, state} = server.module.propose_region(server.state)
    {:reply, region, %{server | state: state}}
  end

  def handle_call(:get_output, _from, server) do
    {output, state} = server.module.get_output(server.state)
    {:reply, output, %{server | state: state}}
  end

  def handle_call(:reset_stm, _from, server) do
    {:reply, :ok, %{server | state: server.module.reset_stm(server.state)}}
  end

  def handle_call({:add_lm_processing_to_buffer_stats, processed}, _from, server) do
    state = server.module.add_lm_processing_to_buffer_stats(server.state, processed)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call(:observation_processed?, _from, server) do
    {:reply, server.module.observation_processed?(server.state), server}
  end

  def handle_call(:update_terminal_condition, _from, server) do
    {state, terminal_state} = server.module.update_terminal_condition(server.state)
    {:reply, terminal_state, %{server | state: state}}
  end

  def handle_call({:set_terminal_state, terminal_state}, _from, server) do
    state = server.module.set_terminal_state(server.state, terminal_state)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call({:set_experiment_mode, mode}, _from, server) do
    state = server.module.set_experiment_mode(server.state, mode)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call(:update_ltm_from_stm, _from, server) do
    state = server.module.update_ltm_from_stm(server.state)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call(:state, _from, server), do: {:reply, server.state, server}
end
