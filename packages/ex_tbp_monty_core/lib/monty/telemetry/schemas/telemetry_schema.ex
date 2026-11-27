defmodule Monty.Telemetry.Schemas.TelemetrySchema do
  @moduledoc """
  The base every telemetry event is one of.

  Mirrors `tbp/monty/telemetry/schemas.py::TelemetrySchema`: a `kind` that names
  the event, the schema `VERSION`, and the rule Monty's field validator applies —
  an empty kind is the schema's own name, so a call site that says nothing still
  emits something a handler can filter on.

  `str(event)` in Monty is its kind; here it is `to_string/1`, so a template that
  interpolates an event says the same thing.
  """

  import Kernel, except: [to_string: 1]

  @version 1

  @enforce_keys []
  defstruct kind: ""

  @typedoc "Any schema: the base, or an event that is one."
  @type any_schema :: %{:__struct__ => module(), optional(atom()) => term()}

  @doc "The schema version these fields are read with."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  The event's kind, which is its schema's own name when the call site said
  nothing.

  Monty's `validate_kind` is a field validator, so the fallback happens where the
  value arrives rather than where it is read.
  """
  @spec kind(any_schema()) :: String.t()
  def kind(%{kind: ""} = schema), do: schema |> Map.fetch!(:__struct__) |> name()
  def kind(%{kind: kind}), do: kind

  @doc """
  The schema as the map it crosses a boundary as — pydantic's
  `model_dump(mode: "json")`.

  The base schema is its kind, and an event is that plus whatever fields it
  carries.
  """
  @spec to_map(any_schema()) :: map()
  def to_map(%{kind: _} = schema) do
    schema
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), plain(value)} end)
    |> Map.put("kind", kind(schema))
  end

  @doc "Monty's `TelemetrySchema.__str__`: the event is its kind."
  @spec to_string(any_schema()) :: String.t()
  def to_string(%{kind: _} = schema), do: kind(schema)

  # Monty's `cls.__name__`: the class the event is an instance of, which for a
  # struct is the last part of its module's name.
  defp name(module), do: module |> Module.split() |> List.last()

  defp plain(%{__struct__: _} = nested), do: to_map(nested)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, plain(value)} end)
  defp plain(value), do: value
end
