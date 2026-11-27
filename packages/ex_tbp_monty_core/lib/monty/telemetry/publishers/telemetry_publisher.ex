defmodule Monty.Telemetry.Publishers.TelemetryPublisher do
  @moduledoc """
  A publisher for one module's telemetry.

  Mirrors `tbp/monty/telemetry/publishers.py::TelemetryPublisher`, which is a
  `logging.Logger` whose name starts `telemetry.` and whose events do not
  propagate to the root logger: a telemetry stream is something a run's handlers
  subscribe to, not something that should turn up in an application's log.

  A publisher here is a value — its name, its level, and where its records go —
  and `emit/3` builds the record and offers it to
  `Monty.Telemetry.Collector.record/1` when a collector is running. `propagate?/1`
  is Monty's `propagate = False`, kept as a field so that a reader of the
  publisher can be told the same thing.

  ## What a record is

  Monty's handlers receive a `logging.LogRecord` whose `msg` is the event and
  whose `getMessage()` is the event's kind. There is no such thing here, so a
  record is a map with the four facts a formatter reads plus the event:
  `%{level:, name:, func_name:, lineno:, msg:}`.
  """

  alias Monty.Telemetry.Schemas.TelemetryEvent

  @prefix "telemetry."

  @enforce_keys [:name]
  defstruct name: nil, level: :info, propagate: false

  @type t :: %__MODULE__{name: String.t(), level: atom(), propagate: boolean()}

  @doc """
  The publisher named `name`, prefixed with `telemetry.` once.

  Monty's `getTelemeter` prefixes a name that does not start with `telemetry.`
  and leaves one that does, which is what keeps `getTelemeter("telemetry.x")`
  and `getTelemeter("x")` the same publisher.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, options \\ []) do
    %__MODULE__{
      name: prefix(name),
      level: Keyword.get(options, :level, :info)
    }
  end

  @doc "The `telemetry.` prefix Monty routes telemetry names through."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Emits `event` at `level` through this publisher.

  A collector that is running is given the record; a run without one still
  answers the record, so a caller can format it or write it where it likes.
  """
  @spec emit(t(), atom(), TelemetryEvent.t()) :: map()
  def emit(%__MODULE__{} = publisher, level, %TelemetryEvent{} = event) do
    record = record(publisher, level, event)
    Monty.Telemetry.Collector.record(record)
    record
  end

  @doc "The record Monty's handlers would have received."
  @spec record(t(), atom(), TelemetryEvent.t()) :: map()
  def record(%__MODULE__{} = publisher, level, %TelemetryEvent{} = event) do
    %{
      level: level,
      name: publisher.name,
      func_name: "emit/3",
      lineno: 0,
      msg: event
    }
  end

  @doc "Monty's `propagate = False`: events stay on this publisher's stream."
  @spec propagate?(t()) :: boolean()
  def propagate?(%__MODULE__{propagate: propagate}), do: propagate

  defp prefix(@prefix <> _rest = name), do: name
  defp prefix(""), do: @prefix
  defp prefix(name), do: @prefix <> name
end
