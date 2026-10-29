defmodule Monty.Frameworks.Models.SensorModules.SnapshotTelemetry do
  @moduledoc """
  Keeps the raw observations a sensor saw, and where it was when it saw them.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::SnapshotTelemetry`.
  Only a sensor configured with `save_raw_obs: true` fills it. What it is for is
  looking back at the very pixels a percept was computed from — a graph of
  features is not enough to tell a bad estimate from a bad view — so the
  observation is kept as it arrived rather than as it was summarised.

  The observations are held newest first, which is how a list is cheapest to
  grow in; `state_dict/1` hands them back in the order they were taken, one pose
  per observation, as Monty's does.
  """

  alias Monty.Geometry.Rotation

  @typedoc "The sensor's pose when it took one observation: `wxyz`, then metres."
  @type pose :: %{sm_rotation: [float()], sm_location: [float()]}

  @type t :: %__MODULE__{raw_observations: [map()], poses: [pose()]}

  defstruct raw_observations: [], poses: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records one raw observation and the sensor's pose when it took it.

  Both lists grow together, which is the invariant `state_dict/1` relies on.
  """
  @spec raw_observation(t(), map(), Rotation.t(), [float()]) :: t()
  def raw_observation(%__MODULE__{} = telemetry, observation, %Rotation{wxyz: wxyz}, position) do
    %__MODULE__{
      telemetry
      | raw_observations: [observation | telemetry.raw_observations],
        poses: [%{sm_rotation: Tuple.to_list(wxyz), sm_location: position} | telemetry.poses]
    }
  end

  @doc "What was recorded, oldest first, as Monty's `state_dict` reports it."
  @spec state_dict(t()) :: %{raw_observations: [map()], sm_properties: [pose()]}
  def state_dict(%__MODULE__{} = telemetry) do
    %{
      raw_observations: Enum.reverse(telemetry.raw_observations),
      sm_properties: Enum.reverse(telemetry.poses)
    }
  end

  @doc "Forgets everything, for a new episode."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()
end
