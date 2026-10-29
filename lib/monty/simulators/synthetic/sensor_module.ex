defmodule Monty.Simulators.Synthetic.SensorModule do
  @moduledoc """
  A sensor module: one observation in, one percept out.

  Monty's `CameraSM` is this — an `ObservationProcessor` for the percept, a
  message-noise layer, a percept filter, and snapshot telemetry. Both parts that
  decide *what a percept says* are now ported, so this module is the thin shell
  around them rather than a lookalike:

    * `Monty.Frameworks.Models.SensorModules.ObservationProcessor` — **ported**:
      the surface estimated from the patch, the features the config asked for,
      the location and the two flags;
    * `Monty.Frameworks.Models.SensorModules.FeatureChangeFilter` — **ported**:
      whether this point differs enough from the last one sent to be worth
      learning;
    * `Monty.Frameworks.Models.SensorModules.PassthroughPerceptFilter` —
      **ported**: what a sensor with no `delta_thresholds` uses instead.

  Not ported, and so not here: `MessageNoise` and `DefaultMessageNoise` — noise
  needs the runtime's random stream, which a sensor module is not given yet — and
  `SnapshotTelemetry`, the raw-observation log. A config that asks for either gets
  a finding from `Monty.Studio.Setup` rather than a module that quietly ignores
  it.

  It is a simulator-side module (Monty's `simulators/` are not part of the core),
  so it does not appear in the module map — but it is the runtime shape a ported
  `CameraSM` takes.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

  alias Monty.Frameworks.Models.SensorModules.{
    FeatureChangeFilter,
    ObservationProcessor,
    PassthroughPerceptFilter
  }

  @type state :: %{
          sensor_module_id: atom() | String.t(),
          pose: map() | nil,
          processor: ObservationProcessor.t(),
          filter: struct(),
          filter_memory: term()
        }

  @doc """
  A sensor module for one sensor.

  Options: `:features` — the features the sensor's config declares —
  `:delta_thresholds` — how much a feature has to change before a point is worth
  sending — and the processor's own settings (`:pc1_is_pc2_threshold`,
  `:is_surface_sm`, `:weight_curvature`, `:surface_normal_method`).
  """
  @spec new(atom() | String.t(), keyword()) :: state()
  def new(sensor_module_id, options \\ []) do
    processor =
      ObservationProcessor.new(
        Keyword.merge(
          [
            features: Keyword.get(options, :features, []),
            sensor_module_id: sensor_module_id
          ],
          Keyword.take(options, [
            :pc1_is_pc2_threshold,
            :is_surface_sm,
            :weight_curvature,
            :surface_normal_method
          ])
        )
      )

    {filter, filter_memory} = filter(Keyword.get(options, :delta_thresholds))

    %{
      sensor_module_id: sensor_module_id,
      pose: nil,
      processor: processor,
      filter: filter,
      filter_memory: filter_memory
    }
  end

  @impl true
  def update_state(agent_state, state), do: %{state | pose: agent_state}

  @impl true
  def step(observation, motor_only?, state) do
    case ObservationProcessor.process(state.processor, observation) do
      {:ok, percept} ->
        percept = if motor_only?, do: %{percept | pass_message: false}, else: percept

        {percept, filter_memory} =
          state.filter.__struct__.call(state.filter, percept, state.filter_memory)

        {percept, %{state | filter_memory: filter_memory}}

      {:error, _no_point_cloud} ->
        {nil, state}
    end
  end

  @impl true
  def reset(state) do
    %{state | pose: nil, filter_memory: state.filter.__struct__.reset(state.filter_memory)}
  end

  # A config with `delta_thresholds` asks to be told only about points that are
  # new; one without asks for every point.
  defp filter(nil), do: {PassthroughPerceptFilter.new(), PassthroughPerceptFilter.reset(nil)}
  defp filter(thresholds) when map_size(thresholds) == 0, do: filter(nil)
  defp filter(delta_thresholds), do: FeatureChangeFilter.new(delta_thresholds)
end
