defmodule Monty.Runtime.Step do
  @moduledoc """
  The timestep coordinator: Monty's `MontyBase.step` as a sequence of barriers.

  Everything that defines *when* a module is asked something lives here, in the
  order Monty defines (`aggregate_sensory_inputs` → `_step_learning_modules` →
  `_vote` → `_pass_goals` → `_step_motor_system`). The modules themselves are
  processes (`Monty.Runtime.SensorModuleServer`,
  `Monty.Runtime.LearningModuleServer`) with pure callbacks, so this module
  reads as the algorithm and the modules stay testable on their own.

  Rules inherited from Monty, and tested here rather than assumed:

    * a learning module gets sensor percepts whose `pass_message` is true;
    * it gets another learning module's output only if it also got a sensor
      percept that step;
    * every module sends a vote before any module receives one;
    * the action chosen at step *t* belongs to step *t+1*.
  """

  use GenServer

  alias Monty.Cmp.Message
  alias Monty.Runtime.{Barrier, Registry}

  @default_timeout 5_000

  @type model_id :: atom() | String.t()

  @type options :: map()

  @spec start_link(options()) :: GenServer.on_start()
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
  @spec step(GenServer.server(), map(), map(), Monty.Context.t()) :: {:ok, [map()], map()}
  def step(server, observations, proprioceptive_state, ctx) do
    GenServer.call(server, {:step, observations, proprioceptive_state, ctx}, :infinity)
  end

  @doc "The coordinator's state, for tests and the run inspector."
  @spec state(GenServer.server()) :: map()
  def state(server), do: GenServer.call(server, :state)

  @impl true
  def init(options) do
    {:ok,
     Map.merge(
       %{
         sensor_modules: [],
         learning_modules: [],
         sm_to_lm: %{},
         lm_to_lm: %{},
         lm_to_lm_vote: nil,
         motor: nil,
         motor_state: nil,
         motor_only?: false,
         combine_votes: &default_combine_votes/2,
         attention: fn goals, _regions -> goals end,
         vote_timeout: @default_timeout,
         call_timeout: @default_timeout,
         step: 0
       },
       options
     )}
  end

  @impl true
  def handle_call({:step, observations, proprioceptive_state, ctx}, _from, state) do
    ctx = %{ctx | step: state.step}
    started_at = System.monotonic_time()

    {percepts, sensor_timeouts} = step_sensor_modules(state, observations, proprioceptive_state)
    {outputs, _output_timeouts} = gather_outputs(state)
    {inputs, input_counts} = route_inputs(state, percepts, outputs)

    step_learning_modules(state, inputs, ctx)
    {vote_info, goals} = vote_and_pass_goals(state, ctx)

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

  def handle_call(:state, _from, state) do
    {:reply, Map.drop(state, [:combine_votes, :attention]), state}
  end

  # -- phases ---------------------------------------------------------------

  defp step_sensor_modules(state, observations, proprioceptive_state) do
    requests =
      Enum.map(state.sensor_modules, fn sensor_module ->
        request =
          {:step, observation_for(observations, sensor_module),
           Map.get(proprioceptive_state, sensor_module.agent_id, %{}), state.motor_only?}

        {sensor_module.id, sensor_server(state, sensor_module.id), request}
      end)

    %{replies: percepts, timed_out: timed_out} = Barrier.call_each(requests, state.call_timeout)
    {percepts, timed_out}
  end

  defp gather_outputs(state) do
    requests =
      Enum.map(state.learning_modules, fn lm ->
        {lm.id, learning_server(state, lm.id), :get_output}
      end)

    %{replies: outputs, timed_out: timed_out} = Barrier.call_each(requests, state.call_timeout)
    {outputs, timed_out}
  end

  defp route_inputs(state, percepts, outputs) do
    inputs =
      Map.new(state.learning_modules, fn lm ->
        sensor_percepts = passing_percepts(state.sm_to_lm, lm.id, percepts)

        {lm.id,
         sensor_percepts ++ hierarchy_inputs(state.lm_to_lm, lm.id, sensor_percepts, outputs)}
      end)

    {inputs, Map.new(inputs, fn {id, percepts} -> {id, length(percepts)} end)}
  end

  # Monty's `_combine_inputs`: only percepts that passed, and a hierarchy input
  # only reaches a module that saw a sensor percept itself.
  defp passing_percepts(sm_to_lm, lm_id, percepts) do
    for sm_id <- Map.get(sm_to_lm, lm_id, []),
        %Message{pass_message: true} = percept <- [Map.get(percepts, sm_id)],
        do: percept
  end

  defp hierarchy_inputs(_lm_to_lm, _lm_id, [], _outputs), do: []

  defp hierarchy_inputs(lm_to_lm, lm_id, _sensor_percepts, outputs) do
    for source <- Map.get(lm_to_lm, lm_id, []),
        %Message{pass_message: true} = message <- [Map.get(outputs, source)],
        do: message
  end

  defp step_learning_modules(state, inputs, ctx) do
    request = step_request(ctx)

    requests =
      Enum.map(state.learning_modules, fn lm ->
        {lm.id, learning_server(state, lm.id), request.(Map.get(inputs, lm.id, []))}
      end)

    Barrier.call_each(requests, state.call_timeout)
    :ok
  end

  defp step_request(%{mode: :exploratory} = ctx),
    do: fn percepts -> {:exploratory_step, percepts, ctx} end

  defp step_request(ctx), do: fn percepts -> {:matching_step, percepts, ctx} end

  # A finite vote deadline closes the round with the votes that arrived; the
  # default `:infinity` reproduces Monty's synchronous round.
  defp vote_and_pass_goals(state, _ctx) do
    {vote_info, state} = vote_round(state)
    goals = propose_goals_list(state)
    {vote_info, state.attention.(goals, propose_regions(state))}
  end

  defp vote_round(%{lm_to_lm_vote: nil} = state) do
    {%{sent: 0, used: 0, deadline_hit?: false, timed_out: []}, state}
  end

  defp vote_round(state) do
    receivers = Map.keys(state.lm_to_lm_vote)
    servers = Enum.map(receivers, fn id -> {id, learning_server(state, id)} end)

    %{replies: votes, timed_out: timed_out} =
      Barrier.call(servers, :send_out_vote, state.vote_timeout)

    info = %{
      sent: length(receivers),
      used: map_size(votes),
      deadline_hit?: timed_out != [],
      timed_out: timed_out
    }

    deliver_votes(state, state.combine_votes.(votes, state))
    {info, state}
  end

  defp deliver_votes(state, combined) do
    requests =
      Enum.map(combined, fn {receiver, payload} ->
        {receiver, learning_server(state, receiver), {:receive_votes, payload}}
      end)

    Barrier.call_each(requests, state.call_timeout)
  end

  defp default_combine_votes(votes, state) do
    Map.new(state.lm_to_lm_vote, fn {receiver, sources} ->
      {receiver, Enum.map(sources, &Map.get(votes, &1))}
    end)
  end

  defp propose_goals_list(state) do
    (learning_servers(state) ++ sensor_servers(state))
    |> Enum.flat_map(fn server -> GenServer.call(server, :propose_goals) end)
  end

  defp propose_regions(state) do
    (learning_servers(state) ++ sensor_servers(state))
    |> Enum.map(fn server -> GenServer.call(server, :propose_region) end)
  end

  defp step_motor_system(%{motor: nil} = state, _observations, _proprio, _percepts, _goals, _ctx),
    do: {[], state}

  defp step_motor_system(state, observations, proprioceptive_state, percepts, goals, ctx) do
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

  defp observation_for(observations, sensor_module) do
    observations
    |> Map.get(sensor_module.agent_id, %{})
    |> Map.get(sensor_module.id, %{})
  end

  # Monty hands the motor system the first sensor module's percept, not a merge.
  defp first_percept(%{sensor_modules: [first | _]}, percepts), do: Map.get(percepts, first.id)
  defp first_percept(_state, _percepts), do: nil

  defp learning_servers(state),
    do: Enum.map(state.learning_modules, &learning_server(state, &1.id))

  defp sensor_servers(state), do: Enum.map(state.sensor_modules, &sensor_server(state, &1.id))

  defp learning_server(state, id), do: Registry.via({:learning_module, state.model_id, id})
  defp sensor_server(state, id), do: Registry.via({:sensor_module, state.model_id, id})

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
