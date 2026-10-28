defmodule ExTbpMonty.Mcp.Args do
  @moduledoc """
  Reads a tool call's arguments into the types the studio's functions expect.

  Arguments arrive as a JSON object with whatever types the client decided to
  send — a number may be a string, a boolean may be absent. Each reader returns
  `{:ok, value}` or `{:error, message}`, and the message names the argument and
  what was expected, because it is shown to the model that made the call and is
  the best chance it has to correct itself.
  """

  @type result(t) :: {:ok, t} | {:error, String.t()}

  @doc "A required, non-blank string."
  @spec required(map(), String.t()) :: result(String.t())
  def required(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "`#{key}` is required."}
          trimmed -> {:ok, trimmed}
        end

      value when is_integer(value) ->
        {:ok, Integer.to_string(value)}

      _missing ->
        {:error, "`#{key}` is required."}
    end
  end

  @doc "An optional string; `{:ok, nil}` when absent or blank."
  @spec optional(map(), String.t()) :: result(String.t() | nil)
  def optional(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      value when is_integer(value) ->
        {:ok, Integer.to_string(value)}

      _missing ->
        {:ok, nil}
    end
  end

  @doc """
  An optional integer, clamped to `:min`..`:max`.

  A client that sends `limit: 500` gets the maximum rather than an error: the
  caller's intent is clear, and failing the call over it wastes a turn.
  """
  @spec integer(map(), String.t(), keyword()) :: result(integer())
  def integer(args, key, opts) do
    default = Keyword.fetch!(opts, :default)
    min = Keyword.get(opts, :min, 1)
    max = Keyword.get(opts, :max, 100)

    case args[key] do
      nil -> {:ok, default}
      value when is_integer(value) -> {:ok, value |> max(min) |> min(max)}
      value when is_binary(value) -> parse_integer(value, key, min, max)
      _other -> {:error, "`#{key}` must be an integer."}
    end
  end

  defp parse_integer(value, key, min, max) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number |> max(min) |> min(max)}
      _not_a_number -> {:error, "`#{key}` must be an integer."}
    end
  end

  @doc "An optional JSON object, for the arguments that describe an experiment."
  @spec object(map(), String.t()) :: result(map())
  def object(args, key) do
    case args[key] do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, "`#{key}` must be a JSON object."}
    end
  end
end
