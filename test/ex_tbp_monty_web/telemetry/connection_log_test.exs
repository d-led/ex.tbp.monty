defmodule ExTbpMontyWeb.Telemetry.ConnectionLogTest do
  @moduledoc """
  The line a connection leaves behind.

  A page that reconnects has to be readable in the log afterwards, so these tests
  are about the shape of that line: what opened, over which transport, and — on
  the closing line — how long it had been up.
  """

  use ExUnit.Case, async: true

  alias ExTbpMontyWeb.Telemetry.ConnectionLog

  defp socket, do: %Phoenix.Socket{id: "phx-Fq3xKb2p", transport: :websocket}

  defp millis(value), do: System.convert_time_unit(value, :millisecond, :native)

  describe "the line a connection is written as" do
    test "a connection that opened says which transport and which socket" do
      line = ConnectionLog.line("connected", %{duration: millis(12)}, %{socket: socket()})

      assert line == "connection: websocket phx-Fq3xKb2p connected"
    end

    test "a connection that closed says how long it had been up" do
      line = ConnectionLog.line("closed", %{duration: millis(198_000)}, %{socket: socket()})

      assert line == "connection: websocket phx-Fq3xKb2p closed after 3m18s"
    end

    test "a short life is still a readable life" do
      seconds = ConnectionLog.line("closed", %{duration: millis(3_400)}, %{socket: socket()})
      assert seconds =~ "closed after 3.4s"

      instant = ConnectionLog.line("closed", %{duration: millis(240)}, %{socket: socket()})
      assert instant =~ "closed after 240ms"
    end

    test "a connection that was refused says what Phoenix answered" do
      line =
        ConnectionLog.line(
          "connected",
          %{duration: millis(1)},
          %{socket: socket(), result: {:error, :check_origin}}
        )

      assert line == "connection: websocket phx-Fq3xKb2p connected ({:error, :check_origin})"
    end

    test "a long poll says so, and a socket with no name is still a line" do
      line = ConnectionLog.line("closed", %{duration: millis(1_000)}, %{transport: :longpoll})

      assert line == "connection: longpoll - closed after 1.0s"
    end
  end

  describe "attaching" do
    test "attaching twice is not an error" do
      assert ConnectionLog.attach() == :ok
      assert ConnectionLog.attach() == :ok
    end
  end
end
