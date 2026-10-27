defmodule ExTbpMontyWeb.Telemetry.RequestLogTest do
  @moduledoc """
  The request log answers "what did a reader ask for" and says nothing about
  probes: a health check that runs every few seconds is most of a log, and its
  absence from the log is itself the signal that the application is up.

  Taken from `confluence_phx_mirror`, where the same trade was made.
  """

  use ExTbpMontyWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    # The suite runs at :warning; request lines are :info.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "a page request is one readable line", %{conn: conn} do
    log = capture_log(fn -> get(conn, ~p"/prerequisites") end)

    assert log =~ ~r/GET \/prerequisites 200 in \d/
  end

  test "the health probe is not logged at all", %{conn: conn} do
    log = capture_log(fn -> get(conn, ~p"/health") end)

    assert log == ""
  end

  test "the health probe answers for the database, not just for the web server", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "attaching twice is not an error, so a restart does not double the log" do
    assert :ok = ExTbpMontyWeb.Telemetry.RequestLog.attach()
  end
end
