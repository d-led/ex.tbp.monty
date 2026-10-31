defmodule Monty.Runtime.Step do
  @moduledoc """
  The timestep coordinator: Monty's `MontyBase.step` as a sequence of barriers.

  Everything that defines *when* a module is asked something lives here, in the
  order Monty defines (`aggregate_sensory_inputs` → `_step_learning_modules` →
  `_vote` → `_pass_goals` → `_step_motor_system`). The modules themselves are
  processes (`Monty.Runtime.SensorModuleServer`,
  `Monty.Runtime.LearningModuleServer`) with pure callbacks, so this module
  reads as the algorithm and the modules stay testable on their own.

  The coordinator talks to modules only through their public APIs, never
  through raw GenServer messages. The wiring it needs between steps lives in
  `Monty.Runtime.Step.State`, normalised once at start.

  Rules inherited from Monty, and tested here rather than assumed:

    * a learning module gets sensor percepts whose `pass_message` is true;
    * it gets another learning module's output only if it also got a sensor
      percept that step;
    * every module sends a vote before any module receives one;
    * the action chosen at step *t* belongs to step *t+1*;
    * a module with no inputs is not stepped at all, and a step that reached
      no module is not counted as a matching or exploratory step.

  The coordinator is also the model Monty's experiment talks to
  (`ExperimentMonty`): it owns the experiment mode, the step type, the step
  counters, the terminal states, and the decision to stop. `MontyBase` keeps
  that on the model and lets the experiment read it; here the experiment asks
  for it (`done?/1`) and tells it what to do (`reset_episode/1`,
  `set_experiment_mode/2`, `update_ltm/1`), because the coordinator is the
  process that holds it.
  """

  use GenServer

  require Logger

  alias Monty.Cmp.Message
  alias Monty.Runtime.{Barrier, LearningModuleServer, Registry, SensorModuleServer}
  alias Monty.Runtime.Step.State

  @type model_id :: atom() | String.t()
  @type server :: GenServer.server()
  @type info :: %{
          step: non_neg_integer(),
          percept_ids: [atom()],
          inputs: %{optional(atom()) => non_neg_integer()},
          votes: map(),
          goals: non_neg_integer(),
          actions: [map()],
          sensor_timeouts: [atom()],
          step_type: State.step_type(),
          terminal_states: %{optional(atom()) => State.terminal_state()},
          done?: boolean(),
          duration_us: non_neg_integer()
        }

  # -- client API -----------------------------------------------------------

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{model_id: model_id} = options) do
    GenServer.start_link(__MODULE__, options, name: Registry.via({:step, model_id}))
  end

  def child_spec(%{model_id: model_id} = options) do
    %{
      id: {:step, model_id},
      start: {__MODULE__, :start_link, [options]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Runs one step and returns the actions for the next environment step."
  @spec step(server(), map(), map(), Monty.Context.t()) :: {:ok, [map()], info()}
  def step(server, observations, proprioceptive_state, ctx) do
    GenServer.call(server, {:step, observations, proprioceptive_state, ctx}, :infinity)
  end

  @doc "The coordinator's state, for tests and the run inspector."
  @spec state(server()) :: State.t()
  def state(server), do: GenServer.call(server, :state, :infinity)

  @doc """
  The four things a recognition policy may read off the model.

  Monty's `MontyIsDone` and its siblings read `model.is_done`, the model's step
  type, its matching-step count and each module's conclusion — four fields, not
  the model. The coordinator holds the pretrained memory in its own state, so
  answering with the whole thing would copy tens of megabytes per step to
  deliver four values (`docs/monty-bugs.md` §2.17).
  """
  @spec status(server()) :: Monty.Experiment.RecognitionPolicy.model()
  def status(server), do: GenServer.call(server, :status, :infinity)

  @doc """
  Whether the model has concluded this episode.

  Monty's `model.is_done`: set by the model when its match criterion is
  satisfied, or by the experiment when it gives up on an episode.
  """
  @spec done?(server()) :: boolean()
  def done?(server), do: GenServer.call(server, :done?, :infinity)

  @doc """
  Clears short-term memory for a new episode, keeping long-term memory.

  Monty's `model.reset/0`: the modules forget the episode they just had, the
  motor system forgets where it was in its policy, and the counters and
  terminal states start again. The step type returns to matching — an episode
  that starts by exploring is an experiment's choice, not a model's default.
  """
  @spec reset_episode(server()) :: :ok
  def reset_episode(server), do: GenServer.call(server, :reset_episode, :infinity)

  @doc "Tells the model and its modules whether this episode trains or evaluates."
  @spec set_experiment_mode(
          server(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
        ) ::
          :ok
  def set_experiment_mode(server, mode),
    do: GenServer.call(server, {:set_experiment_mode, mode}, :infinity)

  @doc """
  Tells every module which object this episode is about.

  Monty's `MontyForGraphMatching.fixme_set_ground_truth`: the experiment knows
  it, the modules cannot work it out, and without it nothing the episode does can
  be scored.
  """
  @spec fixme_set_ground_truth(server(), map() | nil, keyword()) :: :ok
  def fixme_set_ground_truth(server, primary_target, opts \\ []),
    do: GenServer.call(server, {:fixme_set_ground_truth, primary_target, opts}, :infinity)

  @doc """
  Hands what the episode saw to long-term memory.

  Called at the end of an episode: it is the only moment a training episode
  writes to memory, and the only moment an evaluation episode could.
  """
  @spec update_ltm(server()) :: :ok
  def update_ltm(server), do: GenServer.call(server, :update_ltm, :infinity)

  @doc """
  Ends the episode without a conclusion.

  Monty's `deal_with_time_out` with `global_time_out=True`: the modules that
  never concluded are timed out, so an episode's statistics say "no answer"
  rather than leaving them open, and the model calls itself done.
  """
  @spec time_out(server()) :: :ok
  def time_out(server), do: GenServer.call(server, :time_out, :infinity)

  @doc """
  Switches the model into exploratory mode.

  Monty's `model.switch_to_exploratory_step()`, which a recognition policy asks
  for with `start_exploring` — how a training episode keeps moving over an
  object it has already recognised.
  """
  @spec switch_to_exploratory_step(server()) :: :ok
  def switch_to_exploratory_step(server),
    do: GenServer.call(server, :switch_to_exploratory, :infinity)

  # -- callbacks ------------------------------------------------------------

  @impl true
  def init(options), do: {:ok, State.new(options)}

  @impl true
  def handle_call({:step, observations, proprioceptive_state, ctx}, _from, %State{} = state) do
    state = start_stream_if_new_episode(state, ctx)

    ctx = %{
      ctx
      | step: state.step,
        mode: state.step_type,
        rng: Monty.Random.Stream.via(state.model_id)
    }

    started_at = System.monotonic_time()

    {percepts, sensor_timeouts} =
      step_sensor_modules(state, observations, proprioceptive_state, ctx)

    {outputs, _output_timeouts} = gather_outputs(state)
    {inputs, input_counts} = route_inputs(state, percepts, outputs)

    step_learning_modules(state, inputs, ctx)
    {vote_info, goals} = vote_and_pass_goals(state)

    {actions, state} =
      step_motor_system(state, observations, proprioceptive_state, percepts, goals, ctx)

    state = advance(state)

    info = %{
      step: state.step,
      # A sensor that answered nothing is not a percept: a view finder measures
      # the scene for the motor system and sends none (`docs/monty-bugs.md`
      # §2.11).
      percept_ids:
        percepts
        |> Map.reject(fn {_id, percept} -> is_nil(percept) end)
        |> Map.keys()
        |> Enum.sort(),
      inputs: input_counts,
      votes: vote_info,
      goals: length(goals),
      actions: actions,
      sensor_timeouts: sensor_timeouts,
      step_type: state.step_type,
      terminal_states: state.terminal_states,
      done?: state.done?,
      duration_us: elapsed_us(started_at)
    }

    emit(info)
    {:reply, {:ok, actions, info}, %{state | step: state.step + 1}}
  end

  def handle_call(:done?, _from, state), do: {:reply, state.done?, state}
  def handle_call(:status, _from, %State{} = state), do: {:reply, describe_status(state), state}
  def handle_call(:reset_episode, _from, state), do: {:reply, :ok, reset_episode_state(state)}
  def handle_call(:update_ltm, _from, state), do: {:reply, :ok, update_ltm_state(state)}

  # A global time-out ends the episode: an episode that ran out of steps did
  # not recognise the object, so there is nothing to explore for either.
  def handle_call(:time_out, _from, state) do
    {:reply, :ok, %{time_out_undecided(state) | done?: true}}
  end

  def handle_call(:switch_to_exploratory, _from, %State{} = state) do
    {:reply, :ok, switch_to(state, :exploratory)}
  end

  def handle_call({:set_experiment_mode, mode}, _from, state) do
    {:reply, :ok, set_experiment_mode_state(state, mode)}
  end

  def handle_call({:fixme_set_ground_truth, primary_target, opts}, _from, state) do
    {:reply, :ok, set_ground_truth_state(state, primary_target, opts)}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  # -- phases ---------------------------------------------------------------

  # An episode's first step names its seed in the context, and a seed the stream
  # has not been started on yet is a new episode: Monty reseeds there, in
  # `MontyExperiment.pre_episode`, and the numbers of one episode must not depend
  # on how many draws the one before it made.
  defp start_stream_if_new_episode(%State{episode_seed: seed} = state, %{episode_seed: seed}),
    do: state

  defp start_stream_if_new_episode(%State{model_id: model_id} = state, %{episode_seed: seed}) do
    :ok = Monty.Random.Stream.reseed(Monty.Random.Stream.via(model_id), seed)

    %{state | episode_seed: seed}
  end

  defp step_sensor_modules(
         %State{model_id: model_id} = state,
         observations,
         proprioceptive_state,
         ctx
       ) do
    # One at a time, because an episode draws from one random stream and a
    # sensor module may draw (the salience module dithers its scores): asking
    # them together would let the scheduler decide the numbers. Monty's own
    # loop is one call after another for the same reason.
    state.sensor_modules
    |> Enum.map(fn sm ->
      {sm.id,
       fn ->
         SensorModuleServer.step(
           Registry.via({:sensor_module, model_id, sm.id}),
           observation_for(observations, sm),
           Map.get(proprioceptive_state, sm.agent_id, %{}),
           ctx,
           state.motor_only?
         )
       end}
    end)
    |> Enum.reduce({%{}, []}, fn request, {percepts, timed_out} ->
      %{replies: reply, timed_out: late} = Barrier.run([request], state.call_timeout)

      {Map.merge(percepts, reply), timed_out ++ late}
    end)
  end

  defp gather_outputs(%State{model_id: model_id} = state) do
    requests =
      Enum.map(state.learning_modules, fn lm ->
        {lm.id,
         fn ->
           LearningModuleServer.get_output(Registry.via({:learning_module, model_id, lm.id}))
         end}
      end)

    %{replies: outputs, timed_out: timed_out} = Barrier.run(requests, state.call_timeout)
    {outputs, timed_out}
  end

  defp route_inputs(%State{inputs: inputs}, percepts, outputs) do
    routed =
      Map.new(inputs, fn {lm_id, input} -> {lm_id, inputs_for(input, percepts, outputs)} end)

    {routed, Map.new(routed, fn {lm_id, percepts} -> {lm_id, length(percepts)} end)}
  end

  # Monty's `_combine_inputs`: only percepts that passed, and a hierarchy input
  # only reaches a module that saw a sensor percept itself.
  defp inputs_for(%{sensor_modules: sensor_ids, learning_modules: module_ids}, percepts, outputs) do
    case passing(percepts, sensor_ids) do
      [] -> []
      sensor_percepts -> sensor_percepts ++ passing(outputs, module_ids)
    end
  end

  defp passing(source, ids) do
    for id <- ids,
        %Message{pass_message: true} = message <- [Map.get(source, id)],
        do: message
  end

  defp step_learning_modules(
         %State{model_id: model_id, call_timeout: timeout, semantic_id_to_label: labels},
         inputs,
         ctx
       ) do
    requests =
      Enum.map(inputs, fn {lm_id, percepts} ->
        server = Registry.via({:learning_module, model_id, lm_id})
        {lm_id, fn -> learn(server, percepts, ctx, labels) end}
      end)

    Barrier.run(requests, timeout)
    :ok
  end

  # Monty's `MontyForGraphMatching._step_learning_modules`: a module with no
  # inputs is not stepped, and every module is told whether this step gave it
  # something to learn from. A step that carried only a location is buffered
  # but is not evidence, which is what keeps it out of the symmetry count.
  #
  # A module that does get input is named the object under its sensor first,
  # which is Monty's `_set_stepwise_targets`: it belongs to the step, so it is
  # recorded before the module reads the percepts it came with.
  defp learn(server, [], _ctx, _labels) do
    LearningModuleServer.add_lm_processing_to_buffer_stats(server, false)
  end

  defp learn(server, percepts, %{mode: :exploratory} = ctx, labels) do
    :ok = LearningModuleServer.set_stepwise_target(server, stepwise_target(percepts, labels))
    :ok = LearningModuleServer.exploratory_step(server, percepts, ctx)
    record_processing(server, percepts)
  end

  defp learn(server, percepts, ctx, labels) do
    :ok = LearningModuleServer.set_stepwise_target(server, stepwise_target(percepts, labels))
    :ok = LearningModuleServer.matching_step(server, percepts, ctx)
    record_processing(server, percepts)
  end

  # Monty reads the id off the first percept and looks it up. An id the map does
  # not know, a world that sent no map at all, and a percept that says nothing
  # about which object it came from are one answer there — `no_label` — and are
  # one answer here, which is also what a sensor without semantics reports.
  defp stepwise_target([percept | _rest], labels) when is_map(labels) do
    case Map.fetch(labels, percept.semantic_id) do
      {:ok, label} -> label
      :error -> "no_label"
    end
  end

  defp stepwise_target(_percepts, _no_map), do: "no_label"

  defp record_processing(server, percepts) do
    LearningModuleServer.add_lm_processing_to_buffer_stats(
      server,
      not Monty.Runtime.location_only_step?(percepts)
    )
  end

  # A finite vote deadline closes the round with the votes that arrived; the
  # default `:infinity` reproduces Monty's synchronous round.
  defp vote_and_pass_goals(%State{lm_to_lm_vote: nil} = state) do
    zero = %{sent: 0, used: 0, deadline_hit?: false, timed_out: []}
    {zero, state.attention.(propose_goals(state), propose_regions(state))}
  end

  defp vote_and_pass_goals(%State{model_id: model_id, lm_to_lm_vote: vote_matrix} = state) do
    receivers = Map.keys(vote_matrix)

    requests =
      Enum.map(receivers, fn id ->
        {id,
         fn ->
           LearningModuleServer.send_out_vote(Registry.via({:learning_module, model_id, id}))
         end}
      end)

    %{replies: votes, timed_out: timed_out} = Barrier.run(requests, state.vote_timeout)

    vote_info = %{
      sent: length(receivers),
      used: map_size(votes),
      deadline_hit?: timed_out != [],
      timed_out: timed_out
    }

    deliver_votes(state, state.combine_votes.(votes, state))
    {vote_info, state.attention.(propose_goals(state), propose_regions(state))}
  end

  defp deliver_votes(%State{model_id: model_id} = state, combined) do
    requests =
      Enum.map(combined, fn {receiver, payload} ->
        server = Registry.via({:learning_module, model_id, receiver})
        {receiver, fn -> LearningModuleServer.receive_votes(server, payload) end}
      end)

    Barrier.run(requests, state.call_timeout)
  end

  defp propose_goals(%State{model_id: model_id} = state) do
    learning = Enum.map(learning_servers(state, model_id), &LearningModuleServer.propose_goals/1)
    sensors = Enum.map(sensor_servers(state, model_id), &SensorModuleServer.propose_goals/1)
    Enum.concat(learning ++ sensors)
  end

  defp propose_regions(%State{model_id: model_id} = state) do
    learning = Enum.map(learning_servers(state, model_id), &LearningModuleServer.propose_region/1)
    sensors = Enum.map(sensor_servers(state, model_id), &SensorModuleServer.propose_region/1)
    learning ++ sensors
  end

  defp step_motor_system(
         %State{motor: nil} = state,
         _observations,
         _proprio,
         _percepts,
         _goals,
         _ctx
       ),
       do: {[], state}

  defp step_motor_system(
         %State{} = state,
         observations,
         proprioceptive_state,
         percepts,
         goals,
         ctx
       ) do
    {module, _initial_state} = state.motor
    percept = first_percept(state, percepts)

    {actions, motor_state} =
      module.call(state.motor_state, ctx, observations, proprioceptive_state, percept, goals)

    state = %{state | motor_state: motor_state, motor_only?: module.motor_only_step(motor_state)}

    {actions, state}
  end

  # -- what a policy reads --------------------------------------------------

  # Monty's `model.is_done` and the three other fields `MontyIsDone` and its
  # siblings read. Built here, from the state that holds the memory, so that the
  # four values travel and not the graphs behind them.
  defp describe_status(%State{} = state) do
    %{
      is_done: state.done?,
      is_exploring: state.step_type == :exploratory,
      matching_steps: state.matching_steps,
      conclusions: Enum.map(state.learning_modules, &Map.get(state.terminal_states, &1.id))
    }
  end

  # -- the model's own decisions --------------------------------------------
  #
  # Monty's `MontyForGraphMatching._set_step_type_and_check_if_done`, which runs
  # at the end of every step: count the step, ask the modules whether they are
  # done, and decide whether the episode switches to exploring or stops.

  defp advance(%State{} = state) do
    state = count_step(state)

    case state.step_type do
      :matching -> after_matching_step(state)
      :exploratory -> after_exploratory_step(state)
    end
  end

  defp count_step(%State{step_type: :matching} = state),
    do: %{state | matching_steps: state.matching_steps + 1}

  defp count_step(%State{step_type: :exploratory} = state),
    do: %{state | exploratory_steps: state.exploratory_steps + 1}

  defp after_matching_step(%State{} = state) do
    if any_module_processed?(state) do
      {state, matched?} = check_terminal_conditions(state)

      if matched? do
        state = time_out_undecided(state)

        cond do
          state.experiment_mode == :train ->
            switch_to(state, :exploratory)

          state.experiment_mode == :eval and state.matching_steps > state.min_eval_steps ->
            %{state | done?: true}

          true ->
            state
        end
      else
        state
      end
    else
      # A step that reached no module is not evidence of anything, so it does
      # not count towards the steps an episode's limits are measured in.
      %{state | matching_steps: state.matching_steps - 1}
    end
  end

  defp after_exploratory_step(%State{} = state) do
    cond do
      not any_module_processed?(state) ->
        %{state | exploratory_steps: state.exploratory_steps - 1}

      state.exploratory_steps >= state.num_exploratory_steps ->
        %{state | done?: true}

      true ->
        state
    end
  end

  defp any_module_processed?(%State{model_id: model_id} = state) do
    state.learning_modules
    |> Enum.map(&Registry.via({:learning_module, model_id, &1.id}))
    |> Enum.any?(&LearningModuleServer.observation_processed?/1)
  end

  # Every module having given up is the one conclusion that needs no criterion:
  # there is nothing to agree on, and no reason to keep stepping.
  defp check_terminal_conditions(%State{} = state) do
    cond do
      all_modules_gave_up?(state) -> {state, true}
      exceeded_min_steps?(state) -> state |> update_terminal_conditions() |> criterion_matched()
      true -> {state, false}
    end
  end

  defp all_modules_gave_up?(%State{} = state) do
    Enum.all?(state.learning_modules, fn lm ->
      Map.get(state.terminal_states, lm.id) == :no_match
    end)
  end

  defp update_terminal_conditions(%State{model_id: model_id} = state) do
    requests =
      Enum.map(state.learning_modules, fn lm ->
        server = Registry.via({:learning_module, model_id, lm.id})
        {lm.id, fn -> LearningModuleServer.update_terminal_condition(server) end}
      end)

    %{replies: terminal_states} = Barrier.run(requests, state.call_timeout)
    %{state | terminal_states: Map.merge(state.terminal_states, terminal_states)}
  end

  defp criterion_matched(%State{match_criterion: {module, argument}} = state) do
    {state, module.matched?(state.terminal_states, argument)}
  end

  defp exceeded_min_steps?(%State{} = state), do: step_type_count(state) > min_steps(state)

  defp step_type_count(%State{step_type: :matching} = state), do: state.matching_steps
  defp step_type_count(%State{step_type: :exploratory} = state), do: state.exploratory_steps

  defp min_steps(%State{step_type: :matching, experiment_mode: :train} = state),
    do: state.min_train_steps

  defp min_steps(%State{step_type: :matching, experiment_mode: :eval} = state),
    do: state.min_eval_steps

  defp min_steps(%State{step_type: :matching} = state), do: state.min_eval_steps

  defp min_steps(%State{step_type: :exploratory} = state), do: state.num_exploratory_steps

  # Monty's `_set_time_outs(global_time_out=False)`: the modules that never
  # concluded take the episode's ending as theirs, so an episode has one
  # answer per module rather than a mix of answers and silences. Already
  # concluded modules keep what they concluded.
  defp time_out_undecided(%State{step_type: :exploratory} = state), do: state

  defp time_out_undecided(%State{model_id: model_id} = state) do
    undecided =
      for lm <- state.learning_modules, is_nil(Map.get(state.terminal_states, lm.id)), do: lm.id

    Enum.reduce(undecided, state, fn lm_id, state ->
      server = Registry.via({:learning_module, model_id, lm_id})
      :ok = LearningModuleServer.set_terminal_state(server, :time_out)
      put_in(state.terminal_states[lm_id], :time_out)
    end)
  end

  defp switch_to(%State{} = state, step_type) do
    Logger.debug("switching to #{step_type} after #{state.matching_steps} matching steps")
    %{state | step_type: step_type}
  end

  # -- the episode boundary -------------------------------------------------

  defp reset_episode_state(%State{model_id: model_id} = state) do
    Enum.each(state.learning_modules, fn lm ->
      LearningModuleServer.reset_stm(Registry.via({:learning_module, model_id, lm.id}))
    end)

    Enum.each(state.sensor_modules, fn sm ->
      SensorModuleServer.reset(Registry.via({:sensor_module, model_id, sm.id}))
    end)

    %{
      state
      | motor_state: reset_motor(state.motor),
        step_type: :matching,
        matching_steps: 0,
        exploratory_steps: 0,
        terminal_states: %{},
        done?: false,
        step: 0
    }
  end

  defp reset_motor(nil), do: nil

  defp reset_motor({module, motor_state}), do: module.reset(motor_state)

  defp set_experiment_mode_state(%State{model_id: model_id} = state, mode) do
    Enum.each(state.learning_modules, fn lm ->
      LearningModuleServer.set_experiment_mode(
        Registry.via({:learning_module, model_id, lm.id}),
        mode
      )
    end)

    %{state | experiment_mode: mode, step_type: :matching}
  end

  defp update_ltm_state(%State{model_id: model_id} = state) do
    Enum.each(state.learning_modules, fn lm ->
      server = Registry.via({:learning_module, model_id, lm.id})

      # Monty's `MontyBase.update_ltm`: write the episode into long-term memory,
      # then record what that memory came from. The record is only made by a
      # training episode, which the module decides from its own mode.
      LearningModuleServer.update_ltm_from_stm(server)
      LearningModuleServer.fixme_update_ground_truth(server)
    end)

    state
  end

  defp set_ground_truth_state(%State{model_id: model_id} = state, primary_target, opts) do
    Enum.each(state.learning_modules, fn lm ->
      LearningModuleServer.set_target(
        Registry.via({:learning_module, model_id, lm.id}),
        primary_target
      )
    end)

    # Monty's `fixme_set_ground_truth(primary_target, semantic_id_to_label)`: the
    # world's map is what turns a percept's semantic id into the object's name,
    # and only the experiment knows it.
    Map.put(state, :semantic_id_to_label, Keyword.get(opts, :semantic_id_to_label, %{}))
  end

  defp learning_servers(%State{model_id: model_id} = state, model_id) do
    Enum.map(state.learning_modules, &Registry.via({:learning_module, model_id, &1.id}))
  end

  defp sensor_servers(%State{model_id: model_id} = state, model_id) do
    Enum.map(state.sensor_modules, &Registry.via({:sensor_module, model_id, &1.id}))
  end

  defp observation_for(observations, sensor_module) do
    observations
    |> Map.get(sensor_module.agent_id, %{})
    |> Map.get(sensor_module.id, %{})
  end

  # Monty hands the motor system the first sensor module's percept, not a merge.
  defp first_percept(%State{sensor_modules: [first | _]}, percepts),
    do: Map.get(percepts, first.id)

  defp elapsed_us(started_at) do
    System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)
  end

  defp emit(info) do
    :telemetry.execute(
      [:monty, :step, :stop],
      %{duration: info.duration_us},
      %{step: info.step, votes_used: info.votes.used, deadline_hit?: info.votes.deadline_hit?}
    )
  end
end
