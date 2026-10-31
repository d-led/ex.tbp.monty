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
  alias Monty.Frameworks.Actions.ActionJSONEncoder
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.{GazeDirection, OrientationMatrix, Rotation, SurfacePoseVectors}

  @registry_key :buffer_encoders_extra

  # The types Monty's own registry covers, and how each becomes JSON data. Monty
  # registers them one at a time (`np.ndarray` as a list, scipy's `Rotation` as
  # Euler angles in degrees, `Goal` as its wire form); the table is the same
  # information in the one shape an Elixir struct can be looked up in, and
  # `default_encoding/3` is what each entry means.
  @default_encoders %{
    Message => :wire,
    Goal => :wire,
    AttentionRegion => :wire,
    # A pose is a matrix of vectors, which is what a reader expects back.
    SurfacePoseVectors => :value,
    OrientationMatrix => :value,
    GazeDirection => :value,
    # Monty registers `Rotation` as scipy's `as_euler("xyz", degrees=True)` and
    # keeps the numbers scipy produced: a log is compared, not rounded.
    Rotation => :euler_degrees,
    # Monty's proprioceptive state is a `TypedDict`, which JSON writes as an
    # object; the struct is the same value with names on it.
    AgentState => :struct,
    SensorState => :struct,
    DateTime => :iso8601,
    NaiveDateTime => :iso8601,
    Date => :iso8601,
    Time => :iso8601
  }

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

  # What JSON already has, and how a value is walked: no default encoder needed.
  defp encode_default(value) when is_number(value) or is_binary(value) or is_boolean(value),
    do: value

  defp encode_default(nil), do: nil
  defp encode_default(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_default(values) when is_list(values), do: Enum.map(values, &encode/1)

  # JSON has tuples: it writes them as arrays. Monty's `action_sequence` is a list
  # of `(actions, proprioceptive_state)` pairs, and this is what writes them.
  defp encode_default(pair) when is_tuple(pair), do: pair |> Tuple.to_list() |> encode()

  # Every type with a default encoding, in one table rather than one clause each:
  # it is the same information Monty's registry holds, and a reader can see what
  # is covered at a glance. Each entry answers JSON-safe data, which is then walked
  # like anything else — a message's pose vectors still meet their own encoder.
  defp encode_default(%module{} = value) do
    case Map.fetch(@default_encoders, module) do
      {:ok, encoding} -> module |> default_encoding(value, encoding) |> encode()
      :error -> encode_struct(module, value)
    end
  end

  defp encode_default(%{} = map), do: Map.new(map, fn {key, value} -> {key, encode(value)} end)

  defp encode_default(otherpiece) do
    raise ArgumentError, "cannot encode #{inspect(otherpiece)} as JSON-compatible data"
  end

  defp default_encoding(_module, value, :wire), do: Cmp.encode(value)
  defp default_encoding(_module, %{value: value}, :value), do: value

  defp default_encoding(_module, rotation, :euler_degrees),
    do: Rotation.to_euler_degrees(rotation, nil)

  defp default_encoding(_module, state, :struct), do: Map.from_struct(state)
  defp default_encoding(module, value, :iso8601), do: module.to_iso8601(value)

  # Monty registers one encoder for the whole `Action` family
  # (`BufferEncoder.register(Action, ActionJSONEncoder)`), and its own lookup walks
  # the class hierarchy to find it. An Elixir struct knows only its own module, so
  # the family is recognised by what every member has and nothing else does: the
  # `to_map/1` that makes an action a map with its name under `"action"`. A struct
  # that is not one stays an error, which is what makes a missing encoder visible.
  #
  # The module is loaded first: `function_exported?/3` answers about a loaded
  # module, and whether an action has been touched in this node yet is not the
  # question being asked.
  defp encode_struct(module, value) do
    if action?(module) do
      value |> ActionJSONEncoder.encode() |> encode()
    else
      raise ArgumentError,
            "no encoder for #{inspect(module)}: register one with " <>
              "#{inspect(__MODULE__)}.register/2"
    end
  end

  defp action?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :to_map, 1)

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
