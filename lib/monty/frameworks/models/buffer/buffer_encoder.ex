defmodule Monty.Frameworks.Models.Buffer.BufferEncoder do
  @moduledoc """
  Turns a buffer's contents into data a JSON encoder accepts.

  Mirrors `tbp/monty/frameworks/models/buffer.py::BufferEncoder`: a registry of
  encoders by type, and a default encoding for the shapes Monty stores — so that
  a learning module's state can be written to a log or an episode file without
  every caller knowing what a pose vector is.

  Python resolves an encoder through the type hierarchy (`isinstance` would let
  a parent's encoder shadow a child's, so it walks the MRO instead). Elixir has
  no inheritance: a struct knows only its own module, so the lookup is exact and
  the fallback is the default encoding. That is a difference in mechanism with
  the same guarantee — a type that has its own encoder always uses it.

  An unknown struct is an error, not a string: silently logging `#Inspect<...>`
  makes a missing encoder look like data.
  """

  alias Monty.Cmp
  alias Monty.Cmp.{AttentionRegion, Goal, Message}
  alias Monty.Geometry.{GazeDirection, OrientationMatrix, SurfacePoseVectors}

  @registry_key :buffer_encoders_extra

  @doc """
  Registers an encoder for a type.

  `encoder` is a function of one argument, or a module exporting `encode/1`.
  """
  @spec register(module(), (term() -> term()) | module()) :: :ok
  def register(type, encoder) when is_atom(type) do
    unless fun?(encoder) or encoder_module?(encoder) do
      raise ArgumentError,
            "invalid encoder for #{inspect(type)}: expected a function of one argument " <>
              "or a module exporting encode/1, got #{inspect(encoder)}"
    end

    put(Map.put(lookup(), type, encoder))
  end

  @doc "Forgets the encoder registered for a type."
  @spec unregister(module()) :: :ok
  def unregister(type) when is_atom(type), do: put(Map.delete(lookup(), type))

  @doc """
  Encodes one value.

  A registered encoder wins over the defaults and is applied once: what it
  returns is expected to be JSON-safe data, the same contract `Jason.Encoder`
  has. Lists and maps below it are walked, so a registered type nested inside a
  default-shaped value is still encoded by its own encoder.
  """
  @spec encode(term()) :: term()
  def encode(value) do
    case Map.fetch(lookup(), type_of(value)) do
      {:ok, encoder} -> apply_encoder(encoder, value)
      :error -> encode_default(value)
    end
  end

  defp apply_encoder(encoder, value) when is_function(encoder, 1), do: encoder.(value)
  defp apply_encoder(module, value), do: module.encode(value)

  defp encode_default(%Message{} = message), do: Cmp.encode(message) |> encode()
  defp encode_default(%Goal{} = goal), do: Cmp.encode(goal) |> encode()
  defp encode_default(%AttentionRegion{} = region), do: Cmp.encode(region) |> encode()

  defp encode_default(%SurfacePoseVectors{value: value}), do: encode(value)
  defp encode_default(%OrientationMatrix{value: value}), do: encode(value)
  defp encode_default(%GazeDirection{value: value}), do: encode(value)

  defp encode_default(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_default(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp encode_default(%Date{} = date), do: Date.to_iso8601(date)
  defp encode_default(%Time{} = time), do: Time.to_iso8601(time)

  defp encode_default(value) when is_number(value) or is_binary(value) or is_boolean(value),
    do: value

  defp encode_default(nil), do: nil
  defp encode_default(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_default(values) when is_list(values), do: Enum.map(values, &encode/1)

  defp encode_default(%_{} = unknown) do
    raise ArgumentError,
          "no encoder for #{inspect(type_of(unknown))}: register one with " <>
            "#{inspect(__MODULE__)}.register/2"
  end

  defp encode_default(%{} = map), do: Map.new(map, fn {key, value} -> {key, encode(value)} end)

  defp encode_default(otherpiece) do
    raise ArgumentError, "cannot encode #{inspect(otherpiece)} as JSON-compatible data"
  end

  defp type_of(%module{}), do: module
  defp type_of(_plain), do: :plain

  defp fun?(encoder), do: is_function(encoder, 1)
  defp encoder_module?(module), do: is_atom(module) and function_exported?(module, :encode, 1)

  defp lookup, do: Application.get_env(:ex_tbp_monty, @registry_key, %{})

  defp put(registry) do
    Application.put_env(:ex_tbp_monty, @registry_key, registry)
    :ok
  end
end
