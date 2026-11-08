defmodule Monty.Frameworks.Models.Salience.Telemetry.NoopSalienceSMTelemetry do
  @moduledoc """
  A recorder that records nothing, and says so with an empty schema.

  Mirrors
  `tbp/monty/frameworks/models/salience/telemetry.py::NoopSalienceSMTelemetry`,
  which is Monty's default: a config that does not ask for salience telemetry
  pays nothing for it. `state_dict/1` still answers every key, empty, so a
  consumer indexing the dict works the same either way.
  """

  @behaviour Monty.Frameworks.Models.Salience.Telemetry.SalienceSMTelemetry

  defstruct []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def reset(%__MODULE__{} = telemetry), do: telemetry

  @impl true
  def raw_observation(%__MODULE__{} = telemetry, _observation, _rotation, _position),
    do: telemetry

  @impl true
  def salience_map(%__MODULE__{} = telemetry, _salience_map), do: telemetry

  @impl true
  def segmentation_map(%__MODULE__{} = telemetry, _segmentation_map), do: telemetry

  @impl true
  def goals(%__MODULE__{} = telemetry, _goals), do: telemetry

  @impl true
  def attention_region(%__MODULE__{} = telemetry, _region), do: telemetry

  @impl true
  def state_dict(%__MODULE__{}) do
    %{
      raw_observations: [],
      sm_properties: [],
      salience_maps: [],
      segmentation_maps: [],
      goals: [],
      attention_regions: []
    }
  end
end
