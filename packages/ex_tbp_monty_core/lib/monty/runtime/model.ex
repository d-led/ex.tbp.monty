defmodule Monty.Runtime.Model do
  @moduledoc """
  One running Monty model: its modules as supervised processes, and the step
  coordinator.

  The supervision tree is the wiring. Sensor and learning modules are children
  with `restart: :permanent`, the coordinator is last, and the strategy is
  `:one_for_one` — a module that dies is replaced while the coordinator keeps
  its step count, because it addresses modules by registered name rather than
  by pid. The episode's random stream (`Monty.Random.Stream`) is a child too:
  it outlives a step and a module, and dies with the model.

  `start_link/1` takes the model id plus the module specs:

      Monty.Runtime.Model.start_link(%{
        model_id: :demo,
        sensor_modules: [%{id: :patch, agent_id: "agent_id_0", module: SomeSM, state: SomeSM.new()}],
        learning_modules: [%{id: :lm_0, module: SomeLM, state: SomeLM.new()}],
        sm_to_lm: %{lm_0: [:patch]},
        motor: {SomeMotor, SomeMotor.new()}
      })

  Steps are driven from outside (`step/4`) because the environment owns the
  clock; a LiveView, an Oban job or a test decides when the next step happens.
  """

  use Supervisor

  alias Monty.Runtime.{Registry, Step}

  @type options :: map()

  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(%{model_id: model_id} = options) do
    Supervisor.start_link(__MODULE__, options, name: via(model_id))
  end

  @doc """
  Runs one step of a model by id.

  A coordinator that dies takes the step with it, and `GenServer.call` hands the
  caller an exit whose reason is the exception the step was running. That exit is
  unwrapped here, so the caller sees the exception the step died of — with the
  step's own traceback, where the failing module's frame is — rather than "a
  process exited", which is all a page could say about it otherwise
  (`Monty.Studio.Failure`).

  Anything else a call can be handed stays an exit: a model that is not running
  is nobody's exception.
  """
  @spec step(atom() | String.t(), map(), map(), Monty.Context.t()) :: {:ok, [map()], map()}
  def step(model_id, observations, proprioceptive_state, ctx) do
    Step.step(Registry.via({:step, model_id}), observations, proprioceptive_state, ctx)
  catch
    :exit, {{%{__exception__: true} = exception, stacktrace}, {GenServer, :call, _args}} ->
      reraise exception, stacktrace
  end

  @doc "Whether the model has concluded this episode."
  @spec done?(atom() | String.t()) :: boolean()
  def done?(model_id), do: Step.done?(Registry.via({:step, model_id}))

  @doc "The coordinator's state, for tests and the run inspector."
  @spec state(atom() | String.t()) :: Monty.Runtime.Step.State.t()
  def state(model_id), do: Step.state(Registry.via({:step, model_id}))

  @doc """
  The modules' own states as they stand, for a logger writing an episode in full.

  Monty's loggers read their modules straight off the model; here the modules are
  processes, so this is the model being asked for all of them at once. See
  `Monty.Runtime.Step.detailed/2` for why the caller brings a projection.
  """
  @spec detailed(atom() | String.t(), (term() -> term())) :: Monty.Runtime.Step.detailed()
  def detailed(model_id, projection \\ & &1),
    do: Step.detailed(Registry.via({:step, model_id}), projection)

  @doc "The four things a recognition policy may read off the model."
  @spec status(atom() | String.t()) :: Monty.Experiment.RecognitionStrategy.model()
  def status(model_id), do: Step.status(Registry.via({:step, model_id}))

  @doc "Clears short-term memory for a new episode, keeping long-term memory."
  @spec reset_episode(atom() | String.t()) :: :ok
  def reset_episode(model_id), do: Step.reset_episode(Registry.via({:step, model_id}))

  @doc "Tells the model and its modules whether this episode trains or evaluates."
  @spec set_experiment_mode(
          atom() | String.t(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
        ) :: :ok
  def set_experiment_mode(model_id, mode) do
    Step.set_experiment_mode(Registry.via({:step, model_id}), mode)
  end

  @doc "Tells every module which object this episode is about."
  @spec fixme_set_ground_truth(atom() | String.t(), map() | nil, keyword()) :: :ok
  def fixme_set_ground_truth(model_id, primary_target, opts \\ []) do
    Step.fixme_set_ground_truth(Registry.via({:step, model_id}), primary_target, opts)
  end

  @doc "Hands what the episode saw to long-term memory."
  @spec update_ltm(atom() | String.t()) :: :ok
  def update_ltm(model_id), do: Step.update_ltm(Registry.via({:step, model_id}))

  @doc """
  Tells the modules the episode's answer, as a supervised experiment knows it.

  Monty's `_pass_target_info_to_model`: the modules the experiment names are
  given the object, its pose and where it stood; every other module's hypotheses
  are dropped, because what it guessed is not something to learn from.
  """
  @spec supervise(atom() | String.t(), map(), [number()], [String.t()]) :: :ok
  def supervise(model_id, target, location_on_model, supervised_ids) do
    Step.supervise(Registry.via({:step, model_id}), target, location_on_model, supervised_ids)
  end

  @doc "Ends the episode without a conclusion."
  @spec time_out(atom() | String.t()) :: :ok
  def time_out(model_id), do: Step.time_out(Registry.via({:step, model_id}))

  @doc "Switches the model into exploratory mode."
  @spec switch_to_exploratory_step(atom() | String.t()) :: :ok
  def switch_to_exploratory_step(model_id),
    do: Step.switch_to_exploratory_step(Registry.via({:step, model_id}))

  @doc "A `:via` name for a model's supervisor."
  @spec via(atom() | String.t()) :: {:via, module(), {atom(), term()}}
  def via(model_id), do: Registry.via({:model, model_id})

  @doc """
  Stops a model started under a model supervisor.

  A model is stopped by terminating its supervisor; the children go with it, so
  no module process outlives the run it belonged to. `supervisor` is
  `ExTbpMonty.Core.Supervisor.model_supervisor/0` — the name the tree this
  package starts uses — unless the host named its own.
  """
  @spec stop(atom() | String.t(), atom()) :: :ok | {:error, :not_found}
  def stop(model_id, supervisor \\ ExTbpMonty.Core.Supervisor.model_supervisor()) do
    case Registry.lookup({:model, model_id}) do
      [{pid, _value}] ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(options) do
    model_id = options.model_id

    children =
      [{Monty.Random.Stream, %{model_id: model_id}}] ++
        Enum.map(options.sensor_modules, fn spec ->
          {Monty.Runtime.SensorModuleServer, Map.put(spec, :model_id, model_id)}
        end) ++
        Enum.map(options.learning_modules, fn spec ->
          {Monty.Runtime.LearningModuleServer, Map.put(spec, :model_id, model_id)}
        end) ++
        [{Step, Map.put(options, :model_id, model_id)}]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
