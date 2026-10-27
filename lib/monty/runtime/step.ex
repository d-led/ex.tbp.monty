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
    * the action chosen at step *t* belongs to step *t+1*.
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
          votes: map(),
          goals: non_neg_integer(),
          actions: [map()],
          sensor_timeouts: [atom()],
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

  # -- callbacks ------------------------------------------------------------

  @impl true
  def init(options), do: {:ok, State.new(options)}

  @impl true
  def handle_call({:step, observations, proprioceptive_state, ctx}, _from, %State{} = state) do
    ctx = %{ctx | step: state.step}
    started_at = System.monotonic_time()

    {percepts, sensor_timeouts} = step_sensor_modules(state, observations, proprioceptive_state)
    {outputs, _output_timeouts} = gather_outputs(state)
    {inputs, input_counts} = route_inputs(state, percepts, outputs)

    step_learning_modules(state, inputs, ctx)
    {vote_info, goals} = vote_and_pass_goals(state)

    {actions, state} =
      step_motor_system(state, observations, proprioceptive_state, percepts, goals, ctx)

    info = %{
      step: state.step,
      percept_ids: percepts |> Map.keys() |> Enum.sort(),
      inputs: input_counts,
      votes: vote_info,
      goals: length(goals),
      actions: actions,
      sensor_timeouts: sensor_timeouts,
      duration_us: elapsed_us(started_at)
    }

    emit(info)
    {:reply, {:ok, actions, info}, %{state | step: state.step + 1}}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  # -- phases ---------------------------------------------------------------

  defp step_sensor_modules(%State{model_id: model_id} = state, observations, proprioceptive_state) do
    requests =
      Enum.map(state.sensor_modules, fn sm ->
        request = fn ->
          SensorModuleServer.step(
            Registry.via({:sensor_module, model_id, sm.id}),
            observation_for(observations, sm),
            Map.get(proprioceptive_state, sm.agent_id, %{}),
            state.motor_only?
          )
        end

        {sm.id, request}
      end)

    %{replies: percepts, timed_out: timed_out} = Barrier.run(requests, state.call_timeout)
    {percepts, timed_out}
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

  defp step_learning_modules(%State{model_id: model_id, call_timeout: timeout}, inputs, ctx) do
    requests =
      Enum.map(inputs, fn {lm_id, percepts} ->
        server = Registry.via({:learning_module, model_id, lm_id})
        {lm_id, fn -> run_learning_step(server, percepts, ctx) end}
      end)

    Barrier.run(requests, timeout)
    :ok
  end

  defp run_learning_step(server, percepts, %{mode: :exploratory} = ctx) do
    LearningModuleServer.exploratory_step(server, percepts, ctx)
  end

  defp run_learning_step(server, percepts, ctx) do
    LearningModuleServer.matching_step(server, percepts, ctx)
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
    {module, motor_state} = state.motor

    request = %{
      ctx: ctx,
      observations: observations,
      proprioceptive_state: proprioceptive_state,
      percept: first_percept(state, percepts),
      goals: goals
    }

    {actions, motor_state, motor_only?} = module.act(request, motor_state)
    {actions, %{state | motor_state: motor_state, motor_only?: motor_only?}}
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
