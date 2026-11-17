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
          required(:state) => term(),
          optional(:report_votes) => boolean()
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

  @doc """
  Hands the module one step's work and answers at once.

  This port's addition, and the first half of a continuous pipeline: the
  coordinator hands over the percepts of step `epoch` as a message and goes on,
  and asks `await/3` only where it needs the answer — the vote round, which is
  the one place the modules' theories are integrated.

  `target` is the object the module's sensor is on this step. The caller decides
  it because only the coordinator holds the semantic-id map, and the module
  records it before it reads the percepts it came with — Monty's
  `_set_stepwise_targets`, in the same order as `learn/4` in
  `Monty.Runtime.Step` had it.
  """
  @spec hand_off(server(), non_neg_integer(), percepts(), Monty.Context.t(), String.t()) :: :ok
  def hand_off(server, epoch, percepts, ctx, target) do
    GenServer.cast(server, {:hand_off, epoch, percepts, ctx, target})
  end

  @doc """
  Hands a module the votes one epoch's round combined, and answers at once.

  This port's addition, for a lagged run: the coordinator is a step ahead of the
  module it is telling, so the votes are buffered and applied at the module's own
  boundary (`handle_cast/2`) rather than inside a call the coordinator waits for.
  """
  @spec deliver_votes(server(), non_neg_integer(), term()) :: :ok
  def deliver_votes(server, epoch, votes) do
    GenServer.cast(server, {:deliver_votes, epoch, votes})
  end

  @doc "The last step this module finished processing, or `nil` before its first."
  @spec processed_through(server()) :: non_neg_integer() | nil
  def processed_through(server), do: GenServer.call(server, :processed_through, :infinity)

  @doc """
  Waits until this module has processed step `epoch`.

  The one synchronisation point of a continuous sensor/learning pipeline: the
  modules run at their own pace, and this is where a caller says "not before
  step n". It is a barrier in the data rather than in the scheduler — nothing
  is started in lockstep, and a module that is already ahead answers at once.

  Two messages from one sender arrive in order, so a `hand_off/5` sent before
  this call is handled before it: handing work over and then waiting for it
  cannot race.
  """
  @spec await(server(), non_neg_integer(), timeout()) :: :ok
  def await(server, epoch, timeout \\ :infinity) do
    GenServer.call(server, {:await, epoch}, timeout)
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

  @doc """
  Monty's `_pass_target_info_to_model`: the conclusion an experiment states.

  A pretraining experiment does not match; it knows what it showed the agent.
  `location_on_model` is where the object stood the first time this experiment
  showed it, so a graph stays where it was learned.
  """
  @spec supervise(server(), map(), [number()]) :: :ok
  def supervise(server, target, location_on_model),
    do: apply_state(server, & &1.supervise(&2, target, location_on_model))

  @doc "Drops the hypotheses of a module the experiment does not supervise."
  @spec clear_hypotheses(server()) :: :ok
  def clear_hypotheses(server), do: apply_state(server, & &1.clear_hypotheses(&2))

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
    {:ok,
     %{
       module: spec.module,
       state: spec.state,
       id: spec.id,
       model_id: spec.model_id,
       epoch: nil,
       waiting: [],
       report_votes?: Map.get(spec, :report_votes, false),
       pending_votes: %{}
     }}
  end

  # A step handed over: the same three things `learn/4` in `Monty.Runtime.Step`
  # used to do through three calls, done here in one, in the same order — the
  # stepwise target, the step itself, then whether the step was one this module
  # had something to process. An empty hand-off is a module with no input: it is
  # not stepped, and it is told so.
  #
  # A module built for a lagged coordinator also says what it now believes, as a
  # message to the coordinator, because that is the whole point of the lag: the
  # belief of epoch `n` is readable while the module is already working on
  # `n + 1`, which a call could not be (it would queue behind that work).
  @impl true
  def handle_cast({:hand_off, epoch, percepts, ctx, target}, server) do
    server =
      server
      |> take_step(percepts, ctx, target)
      |> finished(epoch)
      |> report(epoch)
      |> apply_votes(epoch - 1)

    {:noreply, reply_waiters(server)}
  end

  # The votes an epoch's round combined, for a module that was handed them rather
  # than asked for them.
  #
  # They are applied at the *next* boundary — when this module finishes epoch
  # `e + 1` — and not on arrival. Arrival is a race: the coordinator sends them
  # after epoch `e + 1` was handed over, so a fast module has already finished it
  # and a slow one has not, and applying on arrival would mean the same run
  # computed two different things depending on which. A boundary is a rule about
  # epochs, and the ordering that makes it safe is the mailbox's: the votes for
  # `e` are always ahead of the hand-off for `e + 2`.
  @impl true
  def handle_cast({:deliver_votes, epoch, votes}, server) do
    server = %{server | pending_votes: Map.put(server.pending_votes, epoch, votes)}

    if server.epoch == epoch + 1, do: {:noreply, apply_votes(server, epoch)}, else: {:noreply, server}
  end

  defp take_step(%{module: module, state: state} = server, [], _ctx, _target) do
    %{server | state: module.add_lm_processing_to_buffer_stats(state, false)}
  end

  defp take_step(%{module: module, state: state} = server, percepts, ctx, target) do
    state = module.set_stepwise_target(state, target)

    state =
      case ctx.mode do
        :exploratory ->
          {:ok, state} = module.exploratory_step(percepts, ctx, state)
          state

        _matching ->
          {:ok, state} = module.matching_step(percepts, ctx, state)
          state
      end

    %{
      server
      | state: module.add_lm_processing_to_buffer_stats(state, not location_only?(percepts))
    }
  end

  defp location_only?(percepts), do: Monty.Runtime.location_only_step?(percepts)

  defp finished(server, epoch), do: %{server | epoch: epoch}

  # Monty's `update_stats_after_vote`, at the boundary the votes for an epoch
  # belong to: a module that was handed votes applies them here, decides what they
  # left it believing, and forgets them. A module the coordinator never handed
  # votes to — every module of a barrier run — has nothing pending and does
  # nothing here, because its round is settled by the coordinator's own calls.
  defp apply_votes(server, epoch) do
    case Map.pop(server.pending_votes, epoch) do
      {nil, _pending} ->
        server

      {votes, pending} ->
        {:ok, state} = server.module.receive_votes(votes, server.state)

        %{
          server
          | state: server.module.update_stats_after_vote(state),
            pending_votes: pending
        }
    end
  end

  # `send_out_vote/1` is what this module believes, not a step of it: every
  # module in this tree answers it with the state it was given. It is called
  # here only where a coordinator asked to be told, so a run that reads votes the
  # synchronous way is not given an extra call per module per step.
  defp report(%{report_votes?: false} = server, _epoch), do: server

  defp report(%{module: module, state: state} = server, epoch) do
    {vote, state} = module.send_out_vote(state)
    notify_coordinator(server, epoch, vote)
    %{server | state: state}
  end

  # The coordinator is the model's, registered beside the modules; a model being
  # torn down has none, and a belief nobody can hear is not an error.
  defp notify_coordinator(%{model_id: model_id, id: id}, epoch, vote) do
    case Registry.lookup({:step, model_id}) do
      [{pid, _value}] -> GenServer.cast(pid, {:voted, id, epoch, vote})
      [] -> :ok
    end
  end

  defp reached?(%{epoch: nil}, _epoch), do: false
  defp reached?(%{epoch: processed}, epoch), do: processed >= epoch

  defp reply_waiters(server) do
    {ready, waiting} =
      Enum.split_with(server.waiting, fn {_from, epoch} -> reached?(server, epoch) end)

    Enum.each(ready, fn {from, _epoch} -> GenServer.reply(from, :ok) end)

    %{server | waiting: waiting}
  end

  def handle_call({:await, epoch}, from, server) do
    if reached?(server, epoch) do
      {:reply, :ok, server}
    else
      {:noreply, %{server | waiting: [{from, epoch} | server.waiting]}}
    end
  end

  def handle_call(:processed_through, _from, server), do: {:reply, server.epoch, server}

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
