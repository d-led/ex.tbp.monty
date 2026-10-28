defmodule ExTbpMontyWeb.McpControllerTest do
  use ExTbpMontyWeb.ConnCase, async: true

  @initialize %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{"protocolVersion" => "2025-06-18"}
  }

  # What an MCP client actually sends: the endpoint accepts JSON, and the
  # transport's stream is offered in the same header even though this server
  # does not open one.
  defp send_message(conn, message) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/mcp", Jason.encode!(message))
  end

  defp call_tool(conn, name, arguments) do
    send_message(conn, %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  describe "the handshake" do
    test "initialize answers with the revision and the tools capability", %{conn: conn} do
      body = conn |> send_message(@initialize) |> json_response(200)

      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["capabilities"]["tools"]
      assert body["result"]["serverInfo"]["name"] == "monty-studio"
    end

    test "the initialized notification is accepted with no body", %{conn: conn} do
      conn = send_message(conn, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert response(conn, 202) == ""
    end
  end

  describe "what the transport refuses" do
    test "a GET, because this server opens no stream", %{conn: conn} do
      conn = get(conn, "/mcp")

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end

    test "a DELETE, because there are no sessions", %{conn: conn} do
      assert delete(conn, "/mcp").status == 405
    end

    test "an Origin that is not this host", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://somewhere.else")
        |> send_message(@initialize)

      assert json_response(conn, 403)["message"] =~ "Origin"
    end

    test "a protocol revision this server does not speak", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> send_message(@initialize)

      assert json_response(conn, 400)["message"] =~ "MCP-Protocol-Version"
    end

    test "an empty body, which is not a message", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", "")

      assert json_response(conn, 400)["error"]["code"] == -32_600
    end
  end

  describe "a tool call" do
    test "answers with the tool's text", %{conn: conn} do
      body = conn |> call_tool("monty_port_status", %{}) |> json_response(200)

      assert body["result"]["isError"] == false
      assert body["result"]["structuredContent"]["summary"]["implemented"] > 0
    end

    test "a run is answered with a link on the address the caller used", %{conn: conn} do
      body =
        conn
        |> call_tool("monty_run_experiment", %{
          "name" => "tutorial/first_experiment",
          "steps" => 2
        })
        |> json_response(200)

      assert %{"url" => url, "run_id" => run_id} = body["result"]["structuredContent"]
      assert url == "http://www.example.com/runs/#{run_id}"
      assert [%{"text" => text}] = body["result"]["content"]
      assert text =~ url
    end
  end
end
