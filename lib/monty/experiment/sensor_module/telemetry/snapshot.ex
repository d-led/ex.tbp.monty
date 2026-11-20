defmodule Monty.Experiment.SensorModules.Telemetry.Snapshot do
  @moduledoc """
  Records what the sensor saw and where it stood, in the payload's telemetry.

  Mirrors `tbp/monty/experiment/sensor_modules/telemetry.py::Snapshot`, an
  `ExperimentTransform` — so it is the shape of transform a surf experiment's view
  finder names. It changes no percept: it appends the raw observation to
  `telemetry["raw_observations"]` and the sensor's pose to
  `telemetry["sm_properties"]`, which is what a logger reads afterwards.

  Monty keys the pose `sm_rotation` and `sm_location`, and stores the rotation as
  numpy-quaternion's float array. Here it is this port's quaternion list
  (`wxyz`, §2.4) and the position list, which is the same pose written the way
  every other value in the port is.

  A reset marks the transform, and the next step clears both lists before
  appending — Monty's `_reset` flag, so an episode's telemetry starts empty
  without the sensor forgetting anything between the reset and the next step.
  """

  @behaviour Monty.Experiment.SensorModule.ExperimentTransform

  alias Monty.SensorModules.SensorModule.{Payload, TransformContext}

  @raw_observations "raw_observations"
  @properties "sm_properties"

  defstruct clear?: false

  @type t :: %__MODULE__{clear?: boolean()}

  @doc "A transform that starts recording at the next step."
  @spec new(map() | keyword()) :: t()
  def new(_config \\ %{}), do: %__MODULE__{}

  @impl true
  def call(%__MODULE__{} = transform, %TransformContext{} = ctx, %Payload{} = payload) do
    telemetry = payload.telemetry |> cleared(transform) |> recorded(ctx, payload)

    {%Payload{payload | telemetry: telemetry}, %__MODULE__{transform | clear?: false}}
  end

  @impl true
  def reset(%__MODULE__{} = transform), do: %__MODULE__{transform | clear?: true}

  defp cleared(telemetry, %__MODULE__{clear?: false}), do: telemetry

  defp cleared(telemetry, %__MODULE__{clear?: true}),
    do: Map.drop(telemetry, [@raw_observations, @properties])

  defp recorded(telemetry, ctx, payload) do
    telemetry
    |> Map.update(@raw_observations, [payload.observation], &(&1 ++ [payload.observation]))
    |> Map.update(@properties, [properties(ctx)], &(&1 ++ [properties(ctx)]))
  end

  defp properties(%TransformContext{sensor_state: state}) do
    %{
      "sm_rotation" => state.rotation.wxyz |> Tuple.to_list(),
      "sm_location" => state.position
    }
  end
end
