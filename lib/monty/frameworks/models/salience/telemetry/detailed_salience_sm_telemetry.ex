defmodule Monty.Frameworks.Models.Salience.Telemetry.DetailedSalienceSMTelemetry do
  @moduledoc """
  A recorder that keeps every step of a salience module's reasoning.

  Mirrors
  `tbp/monty/frameworks/models/salience/telemetry.py::DetailedSalienceSMTelemetry`:
  the raw observation and the sensor's pose, the salience map the strategy
  scored, the segmentation mask and the region it proposed, and the goals.

  Monty appends to lists; this holds them newest first, which is how a list is
  cheapest to grow, and `state_dict/1` hands them back in the order they were
  taken.
  """

  @behaviour Monty.Frameworks.Models.Salience.Telemetry.SalienceSMTelemetry

  defstruct raw_observations: [],
            poses: [],
            salience_maps: [],
            segmentation_maps: [],
            goals: [],
            attention_regions: []

  @type pose :: %{sm_rotation: [float()], sm_location: [float()]}

  @type t :: %__MODULE__{
          raw_observations: [map()],
          poses: [pose()],
          salience_maps: [[[float()]]],
          segmentation_maps: [[[number()]]],
          goals: [[Monty.Cmp.Goal.t()]],
          attention_regions: [Monty.Cmp.AttentionRegion.t()]
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def reset(%__MODULE__{}), do: new()

  @impl true
  def raw_observation(
        %__MODULE__{} = telemetry,
        observation,
        %Monty.Geometry.Rotation{wxyz: wxyz},
        position
      ) do
    %__MODULE__{
      telemetry
      | raw_observations: [observation | telemetry.raw_observations],
        poses: [%{sm_rotation: Tuple.to_list(wxyz), sm_location: position} | telemetry.poses]
    }
  end

  @impl true
  def salience_map(%__MODULE__{} = telemetry, salience_map) do
    %__MODULE__{telemetry | salience_maps: [salience_map | telemetry.salience_maps]}
  end

  @impl true
  def segmentation_map(%__MODULE__{} = telemetry, segmentation_map) do
    %__MODULE__{telemetry | segmentation_maps: [segmentation_map | telemetry.segmentation_maps]}
  end

  @impl true
  def goals(%__MODULE__{} = telemetry, goals) do
    %__MODULE__{telemetry | goals: [goals | telemetry.goals]}
  end

  @impl true
  def attention_region(%__MODULE__{} = telemetry, region) do
    %__MODULE__{telemetry | attention_regions: [region | telemetry.attention_regions]}
  end

  @impl true
  def state_dict(%__MODULE__{} = telemetry) do
    %{
      raw_observations: Enum.reverse(telemetry.raw_observations),
      sm_properties: Enum.reverse(telemetry.poses),
      salience_maps: Enum.reverse(telemetry.salience_maps),
      segmentation_maps: Enum.reverse(telemetry.segmentation_maps),
      goals: Enum.reverse(telemetry.goals),
      attention_regions: Enum.reverse(telemetry.attention_regions)
    }
  end
end
