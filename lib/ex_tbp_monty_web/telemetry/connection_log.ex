defmodule ExTbpMontyWeb.Telemetry.ConnectionLog do
  @moduledoc """
  One line when a live connection opens, and one when it closes with its reason.

  A page that reconnects leaves a trace somewhere, or it does not: without one,
  "it reconnected again" is a report with no timestamp, no transport and no
  reason, and whatever is guessed next is a guess. Phoenix emits
  `[:phoenix, :socket_connected]` and `[:phoenix, :socket_disconnected]`, and
  its own logger — which `config :phoenix, :logger, false` turns off so that the
  request log can be one line — was the only thing that printed them. This is
  that part, in the shape `RequestLog` writes:

      connection: websocket phx-Fq3xKb2p connected
      connection: websocket phx-Fq3xKb2p closed after 3m18s

  The lifetime on the closing line is the point of it: a page that dies in three
  seconds and one that dies after three minutes have different causes, and the
  number says which kind of trouble it is before anybody reads a stack trace.
  """

  require Logger

  @connected [:phoenix, :socket_connected]
  @disconnected [:phoenix, :socket_disconnected]

  @doc "Attaches the handler once; a second call is a no-op."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(
           {__MODULE__, :connections},
           [@connected, @disconnected],
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    kind = if event == @connected, do: "connected", else: "closed"
    Logger.info(line(kind, measurements, metadata))
  end

  @doc """
  The line a connection is logged as.

  Public so a test can specify the shape without capturing a log.
  """
  @spec line(String.t(), map(), map()) :: String.t()
  def line(kind, measurements, metadata) do
    "connection: #{transport(metadata)} #{socket_id(metadata)} #{kind}" <>
      tail(kind, measurements, metadata)
  end

  defp tail("connected", _measurements, metadata) do
    case Map.get(metadata, :result) do
      {:ok, _pid} -> ""
      {:ok, _socket, _pid} -> ""
      nil -> ""
      refused -> " (#{inspect(refused)})"
    end
  end

  defp tail(_closed, %{duration: native}, _metadata), do: " after #{duration(native)}"
  defp tail(_closed, _measurements, _metadata), do: ""

  defp transport(metadata) do
    metadata
    |> Map.get(:transport, socket_field(metadata, :transport))
    |> to_string()
  end

  defp socket_id(metadata) do
    case socket_field(metadata, :id) do
      id when is_binary(id) -> id
      _none -> "-"
    end
  end

  defp socket_field(metadata, field) do
    case Map.get(metadata, :socket) do
      %{} = socket -> Map.get(socket, field)
      _none -> nil
    end
  end

  defp duration(native) do
    case System.convert_time_unit(native, :native, :millisecond) do
      millis when millis >= 60_000 ->
        "#{div(millis, 60_000)}m#{rem(div(millis, 1_000), 60)}s"

      millis when millis >= 1_000 ->
        "#{Float.round(millis / 1_000, 1)}s"

      millis ->
        "#{millis}ms"
    end
  end
end
