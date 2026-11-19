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
    * a module with no inputs is not stepped at all, and a step that left every
      module with nothing to process is not counted as a matching or
      exploratory step — which includes a step that handed a module a location
      and no features.

  The coordinator is also the model Monty's experiment talks to
  (`ExperimentMonty`): it owns the experiment mode, the step type, the step
  counters, the terminal states, and the decision to stop. `MontyBase` keeps
  that on the model and lets the experiment read it; here the experiment asks
  for it (`done?/1`) and tells it what to do (`reset_episode/1`,
  `set_experiment_mode/2`, `update_ltm/1`), because the coordinator is the
  process that holds it.
  """

  use GenServer

  alias Monty.Cmp.Message
  alias Monty.Runtime.{Barrier, LearningModuleServer, Registry, SensorModuleServer}
  alias Monty.Runtime.Step.State

  @type model_id :: atom() | String.t()
  @type server :: GenServer.server()
  @type info :: %{
          step: non_neg_integer(),
          percept_ids: [atom()],
          inputs: %{optional(atom()) => non_neg_integer()},
          processed?: boolean(),
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

  @typedoc """
  The model's modules as they stand now.

  Monty's logger reads `model.learning_modules[i].buffer` because its model holds
  the modules; here the modules are processes, and the coordinator is what owns
  their ids. So this is the coordinator asking each of them, once — which is the
  one moment a run needs a module's whole state, at the end of an episode.
  """
  @type detailed :: %{
          learning_modules: [%{id: State.id(), module: module(), state: term()}],
          sensor_modules: [%{id: State.id(), module: module(), state: term()}],
          motor: struct() | nil
        }

  @doc """
  The modules' own states, and the motor system, for a detailed log.

  `projection` runs inside each module's own process, so a logger that reads one
  number out of a module holding a whole hypothesis space asks for that number
  instead of for the space. `& &1` asks for the state itself: the DETAILED log
  writes an episode in full and is the one caller that wants it, and it is the
  one caller that pays for the copy.
  """
  @spec detailed(server(), (term() -> term())) :: detailed()
  def detailed(server, projection \\ & &1),
    do: GenServer.call(server, {:detailed, projection}, :infinity)

  @doc """
  The coordinator's state, with every module's own answer asked for in its process.

  This is what a statistics report is made of: the counters the coordinator owns,
  and each module's state as the episode left it. It is asked for rather than read
  out of the coordinator for two reasons.

  The first is correctness. The `state` the coordinator holds for a module is the
  one the module was *started* with — the modules are processes and the coordinator
  keeps their wiring, not their working set — so a report built from it describes
  an episode that has not been taken: every row said `patch_off_object` and nought
  steps, however the episode had gone.

  The second is cost. `projection` runs inside the module, so a report that reads
  a dozen fields asks for those fields instead of copying the module — 398 MB an
  episode of the ten-object config, most of it the goal generator, the hypothesis
  updater and the graph memory, none of which a report reads. `& &1` asks for the
  module itself, which a DETAILED log needs and pays for.
  """
  @spec statistics(server(), (term() -> term())) :: Monty.Runtime.Step.State.t()
  def statistics(server, projection \\ & &1),
    do: GenServer.call(server, {:statistics, projection}, :infinity)

  @doc """
  What a recognition policy may read off the model.

  Monty's `MontyIsDone` and its siblings read `model.is_done`, the model's step
  type, its matching-step count and each module's conclusion; `MatchCriteria`
  also reads the terminal states and the model's match criterion. Those
  readings, not the model. The coordinator holds the pretrained memory in its
  own state, so answering with the whole thing would copy tens of megabytes per
  step to deliver a handful of values
  (`docs/monty-differences.md` §2.17).
  """
  @spec status(server()) :: Monty.Experiment.RecognitionStrategy.model()
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
  Tells the modules the episode's answer, as a supervised experiment knows it.

  Monty's `_pass_target_info_to_model`. The modules `supervised_ids` names are
  given the object, the pose it was placed with and where it stood; the others
  have their hypotheses dropped, because a guess is not worth learning from.
  """
  @spec supervise(server(), map(), [number()], [String.t()]) :: :ok
  def supervise(server, target, location_on_model, supervised_ids),
    do: GenServer.call(server, {:supervise, target, location_on_model, supervised_ids}, :infinity)

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

  # A module saying what it believes after an epoch — the lagged coordinator's
  # input (`State.scheduling/1`). It is kept, not integrated: a step reads the
  # report *for the epoch it integrates*, so which module answered first cannot
  # decide what the model believes.
  @impl true
  def handle_cast({:voted, id, epoch, report}, %State{} = state) do
    state = %{state | reports: Map.put(state.reports, id, {epoch, report})}
    {:noreply, finish_parked_step(state)}
  end

  @impl true
  def handle_call({:step, observations, proprioceptive_state, ctx}, from, %State{} = state) do
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

    pending = %{
      observations: observations,
      proprioceptive_state: proprioceptive_state,
      ctx: ctx,
      percepts: percepts,
      sensor_timeouts: sensor_timeouts,
      started_at: started_at
    }

    case state.scheduling do
      # A lagged step cannot route its inputs yet: the top-down outputs it routes
      # are the epoch before's, and they arrive as reports the coordinator is not
      # reading while it is inside a call. So the step parks here — after its
      # sensors, which is the half that needs nothing from the modules — and the
      # rest runs when the last report has been handled.
      :lagged ->
        park_step(state, from, pending)

      :barrier ->
        {outputs, _output_timeouts} = gather_outputs(state)
        {inputs, input_counts} = route_inputs(state, percepts, outputs)
        step_learning_modules(state, inputs, ctx)

        {reply, state} = finish_step(state, Map.put(pending, :input_counts, input_counts))
        {:reply, reply, state}
    end
  end

  def handle_call(:done?, _from, state), do: {:reply, state.done?, state}
  def handle_call(:status, _from, %State{} = state), do: {:reply, describe_status(state), state}

  # A model's own `reset/0`: `MontyBase.reset` unless the class this run started
  # overrides it, which is how a run without episode boundaries keeps what its
  # modules believe (`NoResetEvidenceGraphMatching.reset_episode_state/1`).
  def handle_call(:reset_episode, _from, %State{model_class: class} = state),
    do: {:reply, :ok, class.reset_episode_state(state)}

  def handle_call(:update_ltm, _from, state), do: {:reply, :ok, update_ltm_state(state)}

  def handle_call({:supervise, target, location_on_model, supervised_ids}, _from, state),
    do: {:reply, :ok, supervise_state(state, target, location_on_model, supervised_ids)}

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

  def handle_call(
        {:fixme_set_ground_truth, primary_target, opts},
        _from,
        %State{model_class: class} = state
      ) do
    {:reply, :ok, class.set_ground_truth_state(state, primary_target, opts)}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:statistics, projection}, _from, %State{} = state) do
    {:reply,
     %{
       state
       | learning_modules:
           Enum.map(state.learning_modules, &live_learning_module(&1, state.model_id, projection))
     }, state}
  end

  def handle_call({:detailed, projection}, _from, %State{} = state) do
    {:reply,
     %{
       learning_modules:
         Enum.map(
           state.learning_modules,
           &live_learning_module(&1, state.model_id, projection)
         ),
       sensor_modules: Enum.map(state.sensor_modules, &live_sensor_module(&1, state.model_id)),
       motor: state.motor_state
     }, state}
  end

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

  # A lagged step finishes when the epoch before it has been reported, which can
  # be later than the call that began it — so the step is parked here and the
  # reply is sent from `finish_parked_step/1`, in the mailbox handler that hears
  # the last report. `handle_call` cannot wait for its own mailbox: anything it
  # waits on is answered by a message it will not read until it has replied.
  defp park_step(%State{} = state, from, pending) do
    epoch = state.step - 1

    if reported?(state, epoch) do
      {reply, state} = resume_step(state, pending, lagged_reports(state, epoch))
      {:reply, reply, state}
    else
      {:noreply, %{state | pending_step: %{from: from, epoch: epoch, pending: pending}}}
    end
  end

  defp finish_parked_step(%State{pending_step: nil} = state), do: state

  defp finish_parked_step(%State{pending_step: parked} = state) do
    if reported?(state, parked.epoch) do
      {reply, state} = resume_step(state, parked.pending, lagged_reports(state, parked.epoch))
      GenServer.reply(parked.from, reply)

      %{state | pending_step: nil}
    else
      state
    end
  end

  # The rest of a lagged step, which can only run once the epoch before it has
  # been reported: those reports carry the modules' top-down outputs, which is
  # what this step routes into them. A barrier step routes the outputs it can
  # read here and now; a lagged one routes the ones it was told, which is why the
  # modules are never held to the coordinator's pace — the next world step runs
  # while they finish the epoch they were just handed.
  defp resume_step(%State{} = state, pending, reports) do
    {inputs, input_counts} = route_inputs(state, pending.percepts, lagged_outputs(reports))
    step_learning_modules(state, inputs, pending.ctx)

    finish_step(state, Map.merge(pending, %{input_counts: input_counts, reports: reports}))
  end

  # Every module of a lagged model reports every epoch it is handed, whether or
  # not it had anything to process, so this is a fact about the epoch and not a
  # race between modules that did and did not answer.
  defp reported?(_state, epoch) when epoch < 0, do: true

  defp reported?(%State{reports: reports} = state, epoch) do
    Enum.all?(state.learning_modules, fn %{id: id} ->
      match?({^epoch, _report}, Map.get(reports, id))
    end)
  end

  # Everything a step does once its modules have been given the epoch: the vote
  # round, the motor system, the counters and the report a caller reads.
  #
  # It is a function of its own because a lagged run has to run it *later* than
  # the call that began the step (`Monty.Runtime.Step.State.scheduling/1`): the
  # round it integrates is the epoch before the one it is stepping, and the
  # coordinator can only hear that epoch's reports through its mailbox — which it
  # is not reading while it is inside a `handle_call`. The seam is here so that the
  # deferred reply is a second caller of the same tail, not a second tail.
  defp finish_step(%State{} = state, pending) do
    {state, vote_info, goals} = round_and_goals(state, pending)

    {actions, state} =
      step_motor_system(
        state,
        pending.observations,
        pending.proprioceptive_state,
        pending.percepts,
        goals,
        pending.ctx
      )

    {state, processed?} = advance(state)

    info = %{
      step: state.step,
      # Monty's `check_if_any_lms_updated`, which the experiment asks after every
      # step: whether the step gave a module something to process, as opposed to
      # only a location to buffer. It answers whether this step was a matching
      # step at all, which is what the episode's own limits are counted in.
      processed?: processed?,
      # A sensor that answered nothing is not a percept: a view finder measures
      # the scene for the motor system and sends none (`docs/monty-differences.md`
      # §2.11).
      percept_ids:
        pending.percepts
        |> Map.reject(fn {_id, percept} -> is_nil(percept) end)
        |> Map.keys()
        |> Enum.sort(),
      inputs: pending.input_counts,
      votes: vote_info,
      goals: length(goals),
      actions: actions,
      sensor_timeouts: pending.sensor_timeouts,
      step_type: state.step_type,
      terminal_states: state.terminal_states,
      still_believing: state.still_believing,
      done?: state.done?,
      duration_us: elapsed_us(pending.started_at)
    }

    {{:ok, actions, info}, %{state | step: state.step + 1}}
  end

  defp step_sensor_modules(
         %State{model_id: model_id} = state,
         observations,
         proprioceptive_state,
         ctx
       ) do
    # Each request closes over its own sensor's share and nothing else. It
    # matters: a round of several requests runs each in a process of its own, and
    # a process is handed a copy of what its closure holds, while a round of one
    # runs where it was called and copies nothing (`Monty.Runtime.Barrier`). So a
    # closure over `observations` would put every sensor's payload on the heap of
    # every sensor's process, once per sensor per step, and that is the cost the
    # concurrent round would pay for a phase whose work is a fraction of it.
    motor_only? = state.motor_only?

    requests =
      Enum.map(state.sensor_modules, fn sm ->
        server = Registry.via({:sensor_module, model_id, sm.id})
        observation = observation_for(observations, sm)
        proprioceptive = Map.get(proprioceptive_state, sm.agent_id, %{})

        {sm.id,
         fn -> SensorModuleServer.step(server, observation, proprioceptive, ctx, motor_only?) end}
      end)

    case State.sensors_step(state) do
      :concurrent ->
        # This branch is the port's addition; Monty's loop only ever has the one
        # below (`docs/monty-differences.md` §2.28). One round for the whole
        # phase: every sensor starts before any is awaited, so the phase costs
        # its slowest sensor instead of the sum of them. Nothing in it touches
        # the episode's random stream — that is what `State.sensors_step/1`
        # checked — so the numbers are the same as the serial round's, by
        # construction and not by luck.
        %{replies: percepts, timed_out: timed_out} = Barrier.run(requests, state.call_timeout)
        {percepts, timed_out}

      :serial ->
        # Monty's round, one call after another, because an episode draws from
        # one random stream and a sensor that draws (a dither, a noise) makes the
        # order part of the numbers.
        Enum.reduce(requests, {%{}, []}, fn request, {percepts, timed_out} ->
          %{replies: reply, timed_out: late} = Barrier.run([request], state.call_timeout)

          {Map.merge(percepts, reply), timed_out ++ late}
        end)
    end
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

  # Monty's `MontyForGraphMatching._step_learning_modules`, as a hand-off and an
  # epoch wait rather than a round of blocking calls.
  #
  # Each module is given its step as a message — the stepwise target it is named
  # by, the step itself, whether it had anything to process — and the coordinator
  # then waits for the epoch only because the vote round needs the answer: the
  # module's vote is its state after this step. That wait is a barrier in the
  # data, not in the scheduler: a module that is already ahead answers at once,
  # nothing is started in lockstep, and the work no longer has to be performed
  # inside the coordinator's call to it.
  #
  # A lagged model does not wait here at all. Its round is the epoch before this
  # one, and `reported?/2` is the wait for that — so the module is never held to
  # the coordinator's pace, and the only thing a step blocks on is a report it
  # genuinely cannot do without. The lag is fixed at one epoch rather than "as far
  # behind as the module happens to be", which is what keeps two runs of one
  # episode identical.
  #
  # A module with no inputs is not stepped — it is told it had nothing, which is
  # what keeps a location-only step out of the symmetry count.
  defp step_learning_modules(
         %State{model_id: model_id, call_timeout: timeout, semantic_id_to_label: labels} = state,
         inputs,
         ctx
       ) do
    servers =
      Map.new(inputs, fn {lm_id, percepts} ->
        server = Registry.via({:learning_module, model_id, lm_id})

        :ok =
          LearningModuleServer.hand_off(
            server,
            state.step,
            percepts,
            ctx,
            stepwise_target(percepts, labels)
          )

        {lm_id, server}
      end)

    case state.scheduling do
      :barrier ->
        Enum.each(servers, fn {_lm_id, server} ->
          LearningModuleServer.await(server, state.step, timeout)
        end)

      :lagged ->
        :ok
    end

    :ok
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

  # A lagged round reads the epoch *before* this step, from the reports the step
  # was resumed with: the modules have already been handed this step's work, so
  # asking one of them anything here would queue behind that work and the lag
  # would buy nothing. What a module would have been asked — its vote, its goals,
  # its region — travelled with its report for that reason.
  defp round_and_goals(%State{scheduling: :lagged, step: step} = state, %{reports: reports}) do
    epoch = step - 1

    vote_info = deliver_lagged_votes(state, epoch, reports)

    learning_goals = Enum.map(reports, fn {_id, report} -> report.goals end)
    learning_regions = Enum.map(reports, fn {_id, report} -> report.region end)

    # Monty's order in each round: goals are learning modules then sensors,
    # regions are sensors then learning modules (`propose_goals/1`,
    # `propose_regions/1`), and reordering them here would be a difference
    # nothing reads today and a later change would inherit. `Enum.concat/1` over
    # the joined answers, as `propose_goals/1` has it: every module answers with
    # a *list* of goals, and the motor system reads each element it is given as
    # one.
    goals = Enum.concat(learning_goals ++ sensor_goals(state))
    regions = sensor_regions(state) ++ learning_regions

    {state, goals} = State.step_attention(state, goals, regions)
    {state, vote_info, goals}
  end

  defp round_and_goals(%State{} = state, _pending), do: vote_and_pass_goals(state)

  # What the round of the epoch before hands on: each module's top-down output,
  # routed into this step exactly as `gather_outputs/1` routes the one it reads.
  defp lagged_outputs(reports), do: Map.new(reports, fn {id, report} -> {id, report.output} end)

  # A finite vote deadline closes the round with the votes that arrived; the
  # default `:infinity` reproduces Monty's synchronous round.
  defp vote_and_pass_goals(%State{lm_to_lm_vote: nil} = state) do
    zero = %{sent: 0, used: 0, deadline_hit?: false, timed_out: []}
    {state, goals} = State.step_attention(state, propose_goals(state), propose_regions(state))
    {state, zero, goals}
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

    {state, goals} = State.step_attention(state, propose_goals(state), propose_regions(state))
    {state, vote_info, goals}
  end

  # Nothing precedes epoch 0, so the step that begins an episode integrates
  # nothing — and is not parked waiting for a report that cannot exist.
  defp lagged_reports(_state, epoch) when epoch < 0, do: %{}

  # The gate (`reported?/2`) is what makes the fetch safe: a step does not reach
  # its round until every module has reported this epoch.
  defp lagged_reports(%State{reports: reports} = state, epoch) do
    Map.new(state.learning_modules, fn %{id: id} ->
      {^epoch, report} = Map.fetch!(reports, id)
      {id, report}
    end)
  end

  # The votes an epoch's round combined, handed over rather than delivered: this
  # module applies them at its own next boundary, because it is already working
  # on the epoch after the one being voted on. Settling is the module's own doing
  # at that boundary (`Monty.Runtime.LearningModuleServer.apply_votes/2`), which
  # is why there is no `update_stats_after_vote` round here.
  defp deliver_lagged_votes(%State{lm_to_lm_vote: nil}, _epoch, _reports),
    do: %{sent: 0, used: 0, deadline_hit?: false, timed_out: []}

  defp deliver_lagged_votes(%State{lm_to_lm_vote: vote_matrix} = state, epoch, reports) do
    votes =
      for {id, report} <- reports, Map.has_key?(vote_matrix, id), into: %{}, do: {id, report.vote}

    Enum.each(state.combine_votes.(votes, state), fn {receiver, payload} ->
      LearningModuleServer.deliver_votes(
        Registry.via({:learning_module, state.model_id, receiver}),
        epoch,
        payload
      )
    end)

    %{sent: map_size(vote_matrix), used: map_size(votes), deadline_hit?: false, timed_out: []}
  end

  defp deliver_votes(%State{model_id: model_id} = state, combined) do
    requests =
      Enum.map(combined, fn {receiver, payload} ->
        server = Registry.via({:learning_module, model_id, receiver})
        {receiver, fn -> LearningModuleServer.receive_votes(server, payload) end}
      end)

    Barrier.run(requests, state.call_timeout)

    # Then every module is asked what the round left it believing — not only the
    # ones that heard something: a module that heard nothing is exactly the one
    # that can have nothing possible, and Monty's `update_stats_after_vote`
    # concludes `:no_match` for it, or lets it back out of `:no_match` when the
    # votes brought possibilities.
    settle =
      Enum.map(state.learning_modules, fn %{id: id} ->
        server = Registry.via({:learning_module, model_id, id})
        {id, fn -> LearningModuleServer.update_stats_after_vote(server) end}
      end)

    Barrier.run(settle, state.call_timeout)
  end

  defp propose_goals(%State{model_id: model_id} = state) do
    learning = Enum.map(learning_servers(state, model_id), &LearningModuleServer.propose_goals/1)
    Enum.concat(learning ++ sensor_goals(state))
  end

  # The sensors are not lagged: they are asked per step in every mode, because
  # their goals are a read of what they just measured and they answer without a
  # queue behind them.
  defp sensor_goals(%State{model_id: model_id} = state) do
    Enum.map(sensor_servers(state, model_id), &SensorModuleServer.propose_goals/1)
  end

  defp sensor_regions(%State{model_id: model_id} = state) do
    Enum.map(sensor_servers(state, model_id), &SensorModuleServer.propose_region/1)
  end

  defp propose_regions(%State{model_id: model_id} = state) do
    learning = Enum.map(learning_servers(state, model_id), &LearningModuleServer.propose_region/1)

    # Sensors first, then learning modules — Monty's `_pass_goals` order, which
    # is the other way round from its goals. Nothing reads the order today
    # (attention pools every weight about a voxel with `min`/`max`, and groups by
    # voxel before answering), but a difference that nothing reads is still a
    # difference a later change would inherit.
    sensor_regions(state) ++ learning
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

  # Monty's model, as the recognition policies read it: `is_done` and the fields
  # `MontyIsDone` and its siblings read, plus the terminal states and the match
  # criterion that `MatchCriteria` asks the model for. Built here, from the state
  # that holds the memory, so that the readings travel and not the graphs behind
  # them.
  defp describe_status(%State{} = state) do
    %{
      is_done: state.done?,
      is_exploring: state.step_type == :exploratory,
      matching_steps: state.matching_steps,
      conclusions: Enum.map(state.learning_modules, &Map.get(state.terminal_states, &1.id)),
      terminal_states: state.terminal_states,
      still_believing: state.still_believing,
      settle_steps: state.settle_steps,
      settle_left: state.settle_left,
      match_criterion: state.match_criterion
    }
  end

  # -- the model's own decisions --------------------------------------------
  #
  # Monty's `MontyForGraphMatching._set_step_type_and_check_if_done`, which runs
  # at the end of every step: count the step, ask the modules whether they are
  # done, and decide whether the episode switches to exploring or stops.

  # Answers the state and whether the step was one a module processed, which the
  # experiment counts its own steps in — so the question is asked once here
  # rather than once more from the caller.
  defp advance(%State{} = state) do
    state = count_step(state)
    processed? = any_module_processed?(state)

    state =
      case state.step_type do
        :matching -> after_matching_step(state, processed?)
        :exploratory -> after_exploratory_step(state, processed?)
      end

    {state, processed?}
  end

  defp count_step(%State{step_type: :matching} = state),
    do: %{state | matching_steps: state.matching_steps + 1}

  defp count_step(%State{step_type: :exploratory} = state),
    do: %{state | exploratory_steps: state.exploratory_steps + 1}

  defp after_matching_step(%State{} = state, processed?) do
    if processed? do
      state = read_conclusions(state)
      {state, matched?} = check_terminal_conditions(state)

      if matched?, do: settle(state), else: state
    else
      # A step that reached no module is not evidence of anything, so it does
      # not count towards the steps an episode's limits are measured in.
      %{state | matching_steps: state.matching_steps - 1}
    end
  end

  defp after_exploratory_step(%State{} = state, processed?) do
    cond do
      not processed? ->
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

  # Monty's `check_terminal_conditions` starts from `lm.terminal_state`, the
  # attribute a module's own step has just written — a module that found nothing
  # possible has concluded `no_match` already. A module here is a process, so the
  # model asks for that one value; `update_terminal_conditions/1` is the other
  # question, and Monty asks it only past an episode's minimum number of steps.
  #
  # The request is a closure, and a closure sent to another process is copied
  # into it: this one therefore closes over the module's *name*, never over the
  # module's spec. A spec carries the module's state, which for a module reading
  # a pretrained memory is tens of megabytes, so closing over it copied that
  # memory into the module's own process on every processed step — measured at
  # **209 ms of a 285 ms step**, for a projection that answers an atom.
  defp read_conclusions(%State{model_id: model_id} = state) do
    requests =
      Enum.map(state.learning_modules, fn %{id: id, module: module} ->
        server = Registry.via({:learning_module, model_id, id})
        {id, fn -> LearningModuleServer.query(server, &module.conclusion(&1)) end}
      end)

    %{replies: conclusions} = Barrier.run(requests, state.call_timeout)
    %{state | terminal_states: Map.merge(state.terminal_states, conclusions)}
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

  # A module that has delivered its conclusion has delivered a prediction; the
  # ones still stepping are computing on time they no longer have. Monty closes
  # the episode at this point and tells every straggler it is out of time, which
  # throws away whatever it was about to conclude. `settle_steps` is the grace a
  # run gives them instead: the episode keeps stepping for that many steps after
  # the first conclusion — or until every module has a terminal state, whichever
  # comes first — and a straggler that concludes inside the window is counted as
  # a module that matched rather than as one that timed out. Zero is Monty's own
  # rule, and the default.
  defp settle(%State{settle_steps: 0} = state), do: close(state)

  defp settle(%State{} = state) do
    cond do
      all_modules_concluded?(state) -> close(state)
      state.settle_left == nil -> %{state | settle_left: state.settle_steps - 1}
      state.settle_left > 0 -> %{state | settle_left: state.settle_left - 1}
      true -> close(state)
    end
  end

  defp all_modules_concluded?(%State{} = state) do
    Enum.all?(state.learning_modules, fn lm ->
      not is_nil(Map.get(state.terminal_states, lm.id))
    end)
  end

  # The end of the settling: whoever is still stepping is out of time, and a run
  # that trains turns to exploring.
  defp close(%State{} = state) do
    state = time_out_undecided(state)

    cond do
      state.experiment_mode == :train ->
        switch_to(state, :exploratory)

      state.experiment_mode == :eval and state.matching_steps > state.min_eval_steps ->
        %{state | done?: true}

      true ->
        state
    end
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
      for lm <- state.learning_modules, is_nil(Map.get(state.terminal_states, lm.id)), do: lm

    bets = ask_for_bets(state, undecided)

    Enum.reduce(undecided, state, fn %{id: lm_id}, state ->
      server = Registry.via({:learning_module, model_id, lm_id})
      :ok = LearningModuleServer.set_terminal_state(server, :time_out)

      state
      |> put_in([Access.key(:terminal_states), lm_id], :time_out)
      |> put_in(
        [Access.key(:still_believing), lm_id],
        Map.get(bets, lm_id, believed(state, lm_id))
      )
    end)
  end

  # The episode is over, and a module still stepping is asked what it believed
  # when it was stopped: a prediction that arrives late is still a prediction,
  # and dropping it is the computation wasted rather than delivered. Asked in one
  # round, because they are independent of one another.
  defp ask_for_bets(%State{model_id: model_id} = state, modules) do
    requests =
      Enum.map(modules, fn %{id: lm_id, module: module} ->
        server = Registry.via({:learning_module, model_id, lm_id})

        {lm_id,
         fn ->
           LearningModuleServer.query(server, fn module_state ->
             module.send_out_vote(module_state) |> elem(0)
           end)
         end}
      end)

    %{replies: bets} = Barrier.run(requests, state.call_timeout)
    bets
  end

  # What a module that ran out of time was still voting for: the last report it
  # handed the coordinator, which is the same shape `send_out_vote/1` answers.
  # A module that never reported believed nothing this model can name.
  defp believed(%State{reports: reports}, lm_id) do
    case Map.get(reports, lm_id) do
      {_epoch, %{vote: vote}} -> vote
      _never_reported -> nil
    end
  end

  defp switch_to(%State{} = state, step_type) do
    Monty.Trace.trace("switching to #{step_type} after #{state.matching_steps} matching steps")
    %{state | step_type: step_type}
  end

  # -- the episode boundary -------------------------------------------------
  #
  # A reset is two halves, and a model class may want only one of them:
  # `NoResetEvidenceGraphMatching` restarts the counters and clears the buffers
  # between objects while keeping the hypotheses, because a run without episode
  # boundaries has to notice an object change from its own evidence. So the
  # halves are public and named, and a model class composes them.

  @doc """
  Monty's `MontyBase.reset`: the modules forget the episode they just had, the
  motor system forgets where it was in its policy, attention forgets the grid it
  built, and the counters and the terminal states start again.

  Long-term memory is untouched, which is why an episode can end mid-object and
  the next one still knows what a mug looks like.
  """
  @spec reset_episode_state(State.t()) :: State.t()
  def reset_episode_state(%State{} = state) do
    state
    |> exec_learning_modules(&LearningModuleServer.reset_stm/1)
    |> exec_sensor_modules(&SensorModuleServer.reset/1)
    |> restart_counters()
    |> reset_motor()
    |> State.reset_attention()
  end

  @doc """
  One episode's numbers start again, and nothing else does.

  Monty's `reset_episode_steps/0`, `switch_to_matching_step/0` and
  `_is_done = False` — what makes the next stretch of steps an episode, which is
  the half of a reset a run without boundaries still performs.
  """
  @spec restart_counters(State.t()) :: State.t()
  def restart_counters(%State{} = state) do
    %{
      state
      | step_type: :matching,
        matching_steps: 0,
        exploratory_steps: 0,
        terminal_states: %{},
        still_believing: %{},
        settle_left: nil,
        done?: false,
        step: 0
    }
  end

  @doc "Runs `fun` against every learning module's server, for its side effect."
  @spec exec_learning_modules(State.t(), (GenServer.server() -> any())) :: State.t()
  def exec_learning_modules(%State{model_id: model_id, learning_modules: modules} = state, fun) do
    Enum.each(modules, fn lm -> fun.(Registry.via({:learning_module, model_id, lm.id})) end)
    state
  end

  @doc "Runs `fun` against every sensor module's server, for its side effect."
  @spec exec_sensor_modules(State.t(), (GenServer.server() -> any())) :: State.t()
  def exec_sensor_modules(%State{model_id: model_id, sensor_modules: modules} = state, fun) do
    Enum.each(modules, fn sm -> fun.(Registry.via({:sensor_module, model_id, sm.id})) end)
    state
  end

  defp reset_motor(%State{motor: nil} = state), do: state

  # The flag comes from the motor system, not from the previous episode's last
  # step: a policy whose first step reads nothing says so in its own state, and
  # that is where Monty reads it (`is_motor_only_step`).
  defp reset_motor(%State{motor: {module, motor_state}} = state) do
    motor_state = module.reset(motor_state)
    %{state | motor_state: motor_state, motor_only?: module.motor_only_step(motor_state)}
  end

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

  # Monty's `_pass_target_info_to_model`: one decision per module, from whether
  # the experiment names it. It is taken here rather than by the experiment so
  # that the modules stay processes and the coordinator stays the only one that
  # talks to them.
  defp supervise_state(
         %State{model_id: model_id} = state,
         target,
         location_on_model,
         supervised_ids
       ) do
    Enum.each(state.learning_modules, fn lm ->
      server = Registry.via({:learning_module, model_id, lm.id})

      if lm.id in supervised_ids,
        do: LearningModuleServer.supervise(server, target, location_on_model),
        else: LearningModuleServer.clear_hypotheses(server)
    end)

    state
  end

  # A module's own state, asked of the process that owns it. The coordinator's
  # copy of a module is its wiring, not its memory: a training episode's buffer is
  # tens of megabytes, and copying it into the coordinator on every step would be
  # the cost of a log nobody has asked for yet.
  defp live_learning_module(spec, model_id, projection) do
    %{
      spec
      | state:
          LearningModuleServer.query(
            Registry.via({:learning_module, model_id, spec.id}),
            projection
          )
    }
  end

  defp live_sensor_module(spec, model_id) do
    %{spec | state: SensorModuleServer.state(Registry.via({:sensor_module, model_id, spec.id}))}
  end

  @doc """
  Monty's `fixme_set_ground_truth`: the object this episode is about, told to
  every module, and the world's names for its semantic ids.

  Monty's own comment: the modules cannot work this out, and without it nothing
  the episode does can be scored.
  """
  @spec set_ground_truth_state(State.t(), map() | nil, keyword()) :: State.t()
  def set_ground_truth_state(%State{} = state, primary_target, opts) do
    state
    |> exec_learning_modules(&LearningModuleServer.set_target(&1, primary_target))
    |> put_semantic_id_to_label(opts)
  end

  @doc """
  The world's map from a percept's semantic id to the object's name.

  Only the experiment knows it, and it is what lets a step say *which* object was
  under the patch rather than only that one was.
  """
  @spec put_semantic_id_to_label(State.t(), keyword()) :: State.t()
  def put_semantic_id_to_label(%State{} = state, opts),
    do: %{state | semantic_id_to_label: Keyword.get(opts, :semantic_id_to_label, %{})}

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
end
