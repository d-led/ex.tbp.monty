defmodule Monty.Simulators.Synthetic.SensorModule do
  @moduledoc """
  A sensor module for a sensor whose config names a class this port has not
  written.

  Monty's surf experiments name two sensor classes: their patch is a `CameraSM`
  — [`Monty.Frameworks.Models.SensorModules.CameraSM`](../monty/frameworks/models/sensor_modules/camera_sm.ex)
  here, with its noise layer and its snapshot telemetry — and their view finder is
  an `ExperimentSensorModule` of Monty's newer sensor-module API, a pipeline of
  transforms that this port has not written yet. This is what runs for the
  second: the ported observation processor and percept filter behind the sensor's
  config, so the run still reports the patch's features, and no noise, because
  this quiet stand-in has none.

  Use `CameraSM` for anything real. What this is for is running a config whose
  other sensor names a class this port does not have, without pretending that
  class ran.
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
  def step(observation, motor_only?, _ctx, state) do
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
