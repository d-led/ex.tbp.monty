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

  @doc """
  Settles what the vote round left this module believing.

  Monty's `update_stats_after_vote`, asked of every module after a round — the
  module that heard nothing is exactly the one that can have nothing possible.
  """
  @spec update_stats_after_vote(server()) :: :ok
  def update_stats_after_vote(server),
    do: apply_state(server, & &1.update_stats_after_vote(&2))

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
  def reset_stm(server), do: apply_state(server, & &1.reset_stm(&2))

  @doc """
  Drops what the module accumulated, keeping what it learned.

  What a run without episode boundaries asks of its modules when the object
  under the sensor changes: Monty's `_reset_modules_buffers`.
  """
  @spec clear_buffers(server()) :: :ok
  def clear_buffers(server), do: apply_state(server, & &1.clear_buffers(&2))

  @doc "Forgets what the module concluded, keeping what it believes."
  @spec clear_conclusion(server()) :: :ok
  def clear_conclusion(server), do: apply_state(server, & &1.clear_conclusion(&2))

  @doc "Names this episode's object without emptying the module's history."
  @spec set_primary_target(server(), map() | nil) :: :ok
  def set_primary_target(server, primary_target),
    do: apply_state(server, & &1.set_primary_target(&2, primary_target))

  @doc """
  The long-term memory this module holds, or `:none`.

  A training episode's memory is handed to the next one, and the module is what
  holds it — asked here rather than read off the state, because only the module
  knows where in its state the memory is.
  """
  @spec graph_memory(server()) :: Monty.Frameworks.Models.GraphMatching.GraphMemory.t() | :none
  def graph_memory(server), do: GenServer.call(server, :graph_memory, :infinity)

  @doc "Records whether this step's observation reached the module."
  @spec add_lm_processing_to_buffer_stats(server(), boolean()) :: :ok
  def add_lm_processing_to_buffer_stats(server, processed),
    do: apply_state(server, & &1.add_lm_processing_to_buffer_stats(&2, processed))

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
    do: apply_state(server, & &1.set_terminal_state(&2, terminal_state))

  @doc "Tells the module whether this episode trains or evaluates."
  @spec set_experiment_mode(server(), term()) :: :ok
  def set_experiment_mode(server, mode),
    do: apply_state(server, & &1.set_experiment_mode(&2, mode))

  @doc "Folds the episode into long-term memory, if it was a training episode."
  @spec update_ltm_from_stm(server()) :: :ok
  def update_ltm_from_stm(server), do: apply_state(server, & &1.update_ltm_from_stm(&2))

  @doc "Names the object this episode is about, as the experiment knows it."
  @spec set_target(server(), map() | nil) :: :ok
  def set_target(server, primary_target),
    do: apply_state(server, & &1.set_target(&2, primary_target))

  @doc "Records which object the module's sensor is on this step."
  @spec set_stepwise_target(server(), String.t()) :: :ok
  def set_stepwise_target(server, label),
    do: apply_state(server, & &1.set_stepwise_target(&2, label))

  @doc "Records which objects the graph a training episode built came from."
  @spec fixme_update_ground_truth(server()) :: :ok
  def fixme_update_ground_truth(server),
    do: apply_state(server, & &1.fixme_update_ground_truth(&2))

  @doc "The module's own state, for tests and the run inspector."
  @spec state(server()) :: term()
  def state(server), do: GenServer.call(server, :state, :infinity)

  @doc """
  Asks the module a question about its state, and answers only the answer.

  `projection` runs inside the process that owns the state, so a caller that
  wants four numbers out of a module holding ten object models asks for those
  four numbers instead of copying the models across to read them. Copying is
  not free: the graph memory of a pretrained ten-object module is tens of
  megabytes, and a page that refreshes every step was paying for it per step.

  The projection must not change the state — this is a read, and the module is
  left exactly as it was.
  """
  @spec query(server(), (term() -> answer)) :: answer when answer: var
  def query(server, projection), do: GenServer.call(server, {:query, projection}, :infinity)

  # A module function that answers the state it leaves the module in, called in
  # the process that holds it. The fun travels, so the server stays a boundary
  # rather than growing a clause per callback.
  @spec apply_state(server(), (module(), term() -> term())) :: :ok
  defp apply_state(server, fun), do: GenServer.call(server, {:apply, fun}, :infinity)

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

  # The calls that answer nothing but the module's new state — `reset_stm`,
  # `clear_buffers`, `set_target` and the nine others like them. They differ only
  # in which module function they ask for, so they share one clause and the
  # function arrives in the message: a learning module's server is a process
  # boundary, and an alphabet of twenty-four branches is the state machine of a
  # module that does not have one.
  def handle_call({:apply, fun}, _from, server) do
    {:reply, :ok, %{server | state: fun.(server.module, server.state)}}
  end

  def handle_call(:graph_memory, _from, server),
    do: {:reply, server.module.graph_memory(server.state), server}

  def handle_call(:observation_processed?, _from, server) do
    {:reply, server.module.observation_processed?(server.state), server}
  end

  def handle_call(:update_terminal_condition, _from, server) do
    {state, terminal_state} = server.module.update_terminal_condition(server.state)
    {:reply, terminal_state, %{server | state: state}}
  end

  def handle_call(:state, _from, server), do: {:reply, server.state, server}

  def handle_call({:query, projection}, _from, server) do
    {:reply, projection.(server.state), server}
  end
end
