defmodule Monty.Frameworks.Models.Salience.Telemetry.SalienceSMTelemetry do
  @moduledoc """
  Where a salience module records what it judged, and why.

  Mirrors
  `tbp/monty/frameworks/models/salience/telemetry.py::SalienceSMTelemetry`, a
  `Protocol` in Monty. Here it is a behaviour, and — because a struct is a value
  — every callback answers the telemetry it leaves behind, so a module can
  record a step without mutating anything a reader might be holding.

  The three implementations are: this interface, a recorder that keeps nothing
  (`...Telemetry.NoopSalienceSMTelemetry`, Monty's default) and one that keeps
  everything (`...Telemetry.DetailedSalienceSMTelemetry`).
  """

  alias Monty.Cmp.{AttentionRegion, Goal}

  @type t :: struct()

  @doc "Forgets every episode's records."
  @callback reset(t()) :: t()

  @doc "Records an observation and the sensor's pose when it was taken."
  @callback raw_observation(t(), map(), Monty.Geometry.Rotation.t(), [float()]) :: t()

  @doc "Records one step's salience map."
  @callback salience_map(t(), [[float()]]) :: t()

  @doc "Records one step's segmentation mask."
  @callback segmentation_map(t(), [[number()]]) :: t()

  @doc "Records the goals this step proposed."
  @callback goals(t(), [Goal.t()]) :: t()

  @doc "Records the region this step proposed."
  @callback attention_region(t(), AttentionRegion.t()) :: t()

  @doc "Everything recorded, as Monty's `state_dict` reports it."
  @callback state_dict(t()) :: map()
end
