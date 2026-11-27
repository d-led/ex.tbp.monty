defmodule Monty.Telemetry.Formatters.JsonFormatter do
  @moduledoc """
  A telemetry record as one JSON object.

  Mirrors `tbp/monty/telemetry/formatters.py::JsonFormatter`, which refuses a
  record whose message is not a telemetry schema and otherwise answers

      {"level": "INFO", "name": "...", "funcName": "...", "lineno": 12, ...event}

  The event's own fields are spread beside the four a record adds, which is
  Monty's `**schema.model_dump(mode="json")`. A record here is a map — the shape
  `Monty.Telemetry.Publishers.TelemetryPublisher.record/3` answers — because
  there is no `logging.LogRecord` to be one.
  """

  alias Monty.Telemetry.Schemas.TelemetryEvent
  alias Monty.Telemetry.Schemas.TelemetrySchema

  @typedoc """
  A record: where it came from, at which level, and the event it carries.

  `msg` is anything, because refusing a message that is not a schema is half of
  what a formatter does — a record whose message is a string is a record this
  module answers with an error rather than with JSON.
  """
  @type t :: %{
          required(:level) => atom(),
          required(:name) => String.t(),
          required(:func_name) => String.t(),
          required(:lineno) => non_neg_integer(),
          required(:msg) => term()
        }

  @doc """
  The record as JSON.

  A message that is not a telemetry schema is refused: a formatter that guessed
  at `inspect/1` would put a string where a reader expects an event's fields.
  """
  @spec format(map()) :: String.t()
  def format(%{msg: msg} = record) do
    unless schema?(msg), do: raise(ArgumentError, "This formatter only accepts telemetry schemas")

    %{
      "level" => level_name(record.level),
      "name" => record.name,
      "funcName" => record.func_name,
      "lineno" => record.lineno
    }
    |> Map.merge(to_map(msg))
    |> Jason.encode!()
  end

  defp schema?(%TelemetryEvent{}), do: true
  defp schema?(%{__struct__: _} = schema), do: is_map_key(schema, :kind)
  defp schema?(_other), do: false

  defp to_map(%TelemetryEvent{} = event), do: TelemetryEvent.to_map(event)
  defp to_map(schema), do: TelemetrySchema.to_map(schema)

  # `logging.getLevelName`: the level's own name, which is what a reader of the
  # JSON filters on.
  defp level_name(:debug), do: "DEBUG"
  defp level_name(:info), do: "INFO"
  defp level_name(:warning), do: "WARNING"
  defp level_name(:error), do: "ERROR"
  defp level_name(:critical), do: "CRITICAL"
  defp level_name(:notice), do: "NOTICE"
  defp level_name(other) when is_atom(other), do: other |> Atom.to_string() |> String.upcase()
end
