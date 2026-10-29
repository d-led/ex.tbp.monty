defmodule Monty.Frameworks.Models.SensorModules.CameraSM do
  @moduledoc """
  A sensor module: one camera observation in, one percept out.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::CameraSM`, which is
  what every config in this revision of Monty targets for its patch sensor. It
  is four things in a row, and each of them is a module of its own here:

    * `ObservationProcessor` — turns the pixels into a location, a surface and
      the features the config asked for;
    * the noise layer — `DefaultMessageNoise` when the config gives
      `noise_params`, `NoMessageNoise` when it does not;
    * the percept filter — `FeatureChangeFilter` when the config gives
      `delta_thresholds`, `PassthroughPerceptFilter` when it does not;
    * `SnapshotTelemetry` — the raw observations, kept only when the config asks
      with `save_raw_obs: true`.

  ## The random stream

  Monty's `step` draws from `ctx.rng`, one stream per runtime that every module
  and every step shares. Here the sensor derives its stream from the context and
  its own id for the step (`Monty.Context.rng_for/2`), so the same episode seed
  replays the same noise whatever order the modules were stepped in — the same
  deviation the learning modules and the policies make (`docs/monty-bugs.md`
  §2.1). A sensor with no `noise_params` draws nothing and is unaffected.

  ## When there is no percept

  Monty's processor raises if the observation never went through the
  depth-to-points transform. Here `step/4` answers `nil` — no point cloud, no
  percept — and the runtime treats a silent sensor as it treats a silent step,
  which is what a view that sees nothing is (`docs/monty-bugs.md` §2.11).
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}

  alias Monty.Frameworks.Models.SensorModules.{
    DefaultMessageNoise,
    FeatureChangeFilter,
    NoMessageNoise,
    ObservationProcessor,
    PassthroughPerceptFilter,
    SnapshotTelemetry
  }

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  @target "tbp.monty.frameworks.models.sensor_modules.CameraSM"

  @enforce_keys [:sensor_module_id, :features]
  defstruct sensor_module_id: nil,
            features: [],
            save_raw_obs: false,
            pose: nil,
            processor: nil,
            noise: nil,
            filter: nil,
            filter_memory: nil,
            telemetry: nil,
            processed_observations: []

  @type t :: %__MODULE__{
          sensor_module_id: atom() | String.t(),
          features: [String.t()],
          save_raw_obs: boolean(),
          pose: SensorState.t() | nil,
          processor: ObservationProcessor.t(),
          noise: {module(), struct()},
          filter: {module(), struct()},
          filter_memory: term(),
          telemetry: SnapshotTelemetry.t(),
          processed_observations: [Message.t()]
        }

  @doc """
  The sensor a config entry describes, or why it is not this class's.

  Options are Monty's: `features`, then `save_raw_obs`, `noise_params`,
  `delta_thresholds`, `is_surface_sm` and `pc1_is_pc2_threshold` when the config
  gives them. `sensor_module_id` falls back to the config's `sensor_id`, which is
  how a patch sensor is named in the configs that carry both.
  """
  @spec from_config(map()) :: {:ok, t()} | {:error, term()}
  def from_config(%{} = config) do
    with :ok <- check_target(Map.get(config, "_target_", @target)),
         {:ok, features} <- features(config) do
      {:ok,
       new(
         Map.get(config, "sensor_module_id", Map.get(config, "sensor_id")),
         features: features,
         save_raw_obs: Map.get(config, "save_raw_obs", false),
         noise_params: Map.get(config, "noise_params"),
         delta_thresholds: Map.get(config, "delta_thresholds"),
         is_surface_sm: Map.get(config, "is_surface_sm", false),
         pc1_is_pc2_threshold: Map.get(config, "pc1_is_pc2_threshold", 10.0)
       )}
    end
  end

  defp check_target(@target), do: :ok
  defp check_target(target), do: {:error, {:unsupported_sensor_module, target}}

  # A `features` list written as `${constants.default_sensor_features}` is
  # resolved by Monty at run time; until then it is not a list of features, and
  # guessing would produce a sensor reporting features its config never named.
  defp features(%{"features" => features}) when is_list(features), do: {:ok, features}
  defp features(config), do: {:error, {:unresolved_features, Map.get(config, "features")}}

  @doc """
  A sensor module for one sensor.

  Options: `:features` (required) and `:save_raw_obs`, `:noise_params`,
  `:delta_thresholds`, `:is_surface_sm`, `:pc1_is_pc2_threshold`.
  """
  @spec new(atom() | String.t(), keyword()) :: t()
  def new(sensor_module_id, options) do
    {filter_module, filter, filter_memory} = filter(Keyword.get(options, :delta_thresholds))

    %__MODULE__{
      sensor_module_id: sensor_module_id,
      features: Keyword.fetch!(options, :features),
      save_raw_obs: Keyword.get(options, :save_raw_obs, false),
      processor:
        ObservationProcessor.new(
          features: Keyword.fetch!(options, :features),
          sensor_module_id: sensor_module_id,
          is_surface_sm: Keyword.get(options, :is_surface_sm, false),
          pc1_is_pc2_threshold: Keyword.get(options, :pc1_is_pc2_threshold, 10.0)
        ),
      noise: noise(Keyword.get(options, :noise_params)),
      filter: {filter_module, filter},
      filter_memory: filter_memory,
      telemetry: SnapshotTelemetry.new()
    }
  end

  # Monty's configs spell "no noise" by leaving `noise_params` out, and "every
  # point" by leaving `delta_thresholds` out. An empty map is the same as
  # absent, because a config that writes `{}` there asks for nothing either.
  defp noise(nil), do: {NoMessageNoise, NoMessageNoise.new()}
  defp noise(params) when map_size(params) == 0, do: noise(nil)
  defp noise(params), do: {DefaultMessageNoise, DefaultMessageNoise.new(params)}

  defp filter(nil),
    do:
      {PassthroughPerceptFilter, PassthroughPerceptFilter.new(),
       PassthroughPerceptFilter.reset(nil)}

  defp filter(thresholds) when map_size(thresholds) == 0, do: filter(nil)

  defp filter(thresholds) do
    {filter, memory} = FeatureChangeFilter.new(thresholds)
    {FeatureChangeFilter, filter, memory}
  end

  @impl true
  def update_state(%AgentState{} = agent, %__MODULE__{} = sm) do
    sensor = sensor_state(agent, sm.sensor_module_id)

    %__MODULE__{
      sm
      | pose: %SensorState{
          position:
            SpatialArithmetics.add(
              agent.position,
              Rotation.apply(agent.rotation, sensor.position)
            ),
          rotation: Rotation.multiply(agent.rotation, sensor.rotation)
        }
    }
  end

  defp sensor_state(%AgentState{sensors: sensors}, sensor_module_id) do
    case Map.fetch(sensors, sensor_module_id) do
      {:ok, sensor} ->
        sensor

      :error ->
        raise ArgumentError,
              "the agent has no sensor #{inspect(sensor_module_id)}; it has " <>
                Enum.map_join(Map.keys(sensors), ", ", &inspect/1)
    end
  end

  @impl true
  def step(observation, motor_only?, ctx, %__MODULE__{} = sm) do
    sm = if sm.save_raw_obs, do: record_snapshot(sm, observation), else: sm

    case ObservationProcessor.process(sm.processor, observation) do
      {:ok, percept} ->
        percept =
          percept
          |> add_noise(sm, ctx)
          |> silence_if_motor_only(motor_only?)

        {percept, sm} = apply_filter(sm, percept)

        {percept, %{sm | processed_observations: [percept | sm.processed_observations]}}

      {:error, _no_point_cloud} ->
        {nil, sm}
    end
  end

  @doc """
  Everything recorded so far: the raw observations, and every percept this
  sensor made, as Monty's `state_dict` reports it.
  """
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = sm) do
    sm.telemetry
    |> SnapshotTelemetry.state_dict()
    |> Map.put(:processed_observations, Enum.reverse(sm.processed_observations))
  end

  @impl true
  def reset(%__MODULE__{} = sm) do
    {module, _filter} = sm.filter

    %__MODULE__{
      sm
      | telemetry: SnapshotTelemetry.reset(sm.telemetry),
        filter_memory: module.reset(sm.filter_memory),
        processed_observations: []
    }
  end

  defp record_snapshot(%__MODULE__{pose: %SensorState{} = pose} = sm, observation) do
    %__MODULE__{
      sm
      | telemetry:
          SnapshotTelemetry.raw_observation(
            sm.telemetry,
            observation,
            pose.rotation,
            pose.position
          )
    }
  end

  defp record_snapshot(%__MODULE__{pose: nil} = sm, _observation) do
    raise ArgumentError,
          "#{inspect(sm.sensor_module_id)} was asked to save its raw observations but has "

    "never been told where it is; call update_state/2 with the agent's state first"
  end

  defp add_noise(percept, %__MODULE__{noise: {module, noise}, sensor_module_id: id}, ctx) do
    module.call(noise, percept, Monty.Context.rng_for(ctx, id))
  end

  # A step the motor system took on its own is not a step to learn from: the
  # agent moved without looking, and the percept is only still sent so a
  # downstream module can see that time passed.
  defp silence_if_motor_only(percept, true), do: %{percept | pass_message: false}
  defp silence_if_motor_only(percept, false), do: percept

  defp apply_filter(%__MODULE__{filter: {module, filter}} = sm, percept) do
    {percept, filter_memory} = module.call(filter, percept, sm.filter_memory)
    {percept, %{sm | filter_memory: filter_memory}}
  end
end
