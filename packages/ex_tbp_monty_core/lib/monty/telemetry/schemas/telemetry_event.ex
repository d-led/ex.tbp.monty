defmodule Monty.Telemetry.Schemas.TelemetryEvent do
  @moduledoc """
  A telemetry event: a kind, and whatever else the call site has to say.

  Mirrors `tbp/monty/telemetry/schemas.py::TelemetryEvent`, which is the base
  schema with pydantic's `extra="allow"`: a call site adds its own keys beside
  `kind` and a handler reads them.

  The extra keys are `fields`, a map, and they are what `to_map/1` spreads
  beside the kind — Monty's `model_dump`, which carries `model_extra` into the
  dumped object. `kind/1` and `to_string/1` are
  `Monty.Telemetry.Schemas.TelemetrySchema`'s, which read any schema struct.
  """

  alias Monty.Telemetry.Schemas.TelemetrySchema

  @enforce_keys []
  defstruct kind: "", fields: %{}

  @type t :: %__MODULE__{kind: String.t(), fields: %{optional(String.t()) => term()}}

  @doc """
  An event of `kind`, carrying `fields`.

  An empty kind is this schema's name — `"TelemetryEvent"` — which is Monty's
  fallback and what a handler filtering on the class sees.
  """
  @spec new(String.t(), %{optional(String.t()) => term()}) :: t()
  def new(kind \\ "", fields \\ %{}) do
    %__MODULE__{
      kind: kind,
      fields: Map.new(fields, fn {key, value} -> {to_string(key), value} end)
    }
  end

  @doc """
  The event as the map it crosses a boundary as: its kind, then its fields.

  Monty's `model_dump(mode="json")`, whose `model_extra` is spread beside the
  declared fields rather than nested under a key.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event), do: Map.put(event.fields, "kind", kind(event))

  @doc "The event's kind, which is its schema's name when it was given none."
  @spec kind(t()) :: String.t()
  defdelegate kind(event), to: TelemetrySchema
end
