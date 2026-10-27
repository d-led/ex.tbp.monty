defmodule ExTbpMontyWeb.Telemetry.RequestLog do
  @moduledoc """
  One readable line per request, and nothing for the ones nobody reads.

  Taken from `confluence_phx_mirror`, where the same problem was solved the same
  way: Phoenix's own request logger logs every request and offers no way to skip
  one path, and a probe that runs every few seconds is most of the log. The
  probe already reports trouble in a way a monitor can act on — it answers 503 —
  so it stays out, and its absence from the log is itself the signal that the
  application is up.

  This replaces `Phoenix.Logger` (`config :phoenix, :logger, false`), and the
  line is one line rather than two:

      GET /experiments/tutorial/first_experiment 200 in 12.4ms
  """

  require Logger

  @event [:phoenix, :endpoint, :stop]
  @handler {__MODULE__, :request}

  # Anything a load balancer or a container runtime polls rather than a reader
  # opens.
  @quiet ~w(/health /health/ready)

  @doc "Attaches the handler once; a second call is a no-op."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(_event, measurements, %{conn: conn}, _config) do
    path = conn.request_path

    if path in @quiet do
      :ok
    else
      Logger.info(
        mfa_line(conn, measurements),
        request_id: Logger.metadata()[:request_id]
      )
    end
  end

  @doc """
  The line a request is logged as.

  Public so a test can specify the shape without capturing the log, and so the
  duration formatting has one home.
  """
  @spec mfa_line(Plug.Conn.t(), map()) :: String.t()
  def mfa_line(%Plug.Conn{} = conn, measurements) do
    "#{conn.method} #{conn.request_path} #{conn.status || 500} in #{duration(measurements)}"
  end

  defp duration(%{duration: native}) do
    case System.convert_time_unit(native, :native, :microsecond) do
      micros when micros >= 1_000 -> "#{Float.round(micros / 1_000, 1)}ms"
      micros -> "#{micros}µs"
    end
  end
end
