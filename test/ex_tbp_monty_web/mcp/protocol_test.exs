defmodule ExTbpMontyWeb.Mcp.ProtocolTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Mcp
  alias ExTbpMontyWeb.Mcp.Protocol

  @ctx %{base_url: "http://localhost:4001"}

  defp handle(message), do: Protocol.handle(message, @ctx)

  defp reply(message) do
    assert {:reply, response} = handle(message)
    response
  end

  defp call_tool(name, arguments) do
    reply(%{
      "jsonrpc" => "2.0",
      "id" => 9,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  describe "initialize" do
    test "answers in the revision the client asked for" do
      response =
        reply(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-03-26"}
        })

      assert response["result"]["protocolVersion"] == "2025-03-26"
    end

    test "answers in the newest revision when the client asks for one we do not speak" do
      response =
        reply(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "1999-01-01"}
        })

      assert response["result"]["protocolVersion"] == Mcp.latest_protocol_version()
    end

    test "says who it is and that it has tools" do
      result = reply(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})["result"]

      assert result["serverInfo"]["name"] == "monty-studio"
      assert result["capabilities"]["tools"]
      assert result["instructions"] =~ "monty_search_docs"
    end
  end

  describe "a message that is not a request" do
    test "a notification is accepted and not answered" do
      assert :accepted = handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    end

    test "a batch is refused, because this server does not take one" do
      assert {:invalid_request, response} =
               handle([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}])

      assert response["error"]["code"] == -32_600
    end

    test "something that is not JSON-RPC 2.0 is refused" do
      assert {:invalid_request, response} =
               handle(%{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"})

      assert response["error"]["code"] == -32_600
    end

    test "an unknown method is the one error code that says so" do
      response = reply(%{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"})

      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "resources/list"
    end
  end

  describe "tools/list" do
    test "every tool says what it is for and what it takes" do
      tools = reply(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})["result"]["tools"]

      assert length(tools) >= 10
      assert Enum.any?(tools, &(&1["name"] == "monty_run_experiment"))

      for tool <- tools do
        assert is_binary(tool["name"]) and tool["name"] != ""
        assert tool["description"] =~ ~r/\w/
        assert tool["inputSchema"]["type"] == "object"
        assert is_boolean(tool["annotations"]["readOnlyHint"])
      end
    end
  end

  describe "tools/call" do
    test "an unknown tool is an invalid-params error, because there is nothing to run" do
      response = call_tool("monty_does_not_exist", %{})

      assert response["error"]["code"] == -32_602
    end

    test "a missing name is an invalid-params error" do
      response =
        reply(%{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => %{}})

      assert response["error"]["code"] == -32_602
    end

    test "a tool that fails answers with isError, so the model can read why" do
      response = call_tool("monty_read_doc", %{"path" => "../../../etc/passwd"})

      assert response["result"]["isError"] == true
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert text =~ "not a page path"
    end

    test "a tool that succeeds answers with its text and its structured form" do
      response = call_tool("monty_port_status", %{})

      assert response["result"]["isError"] == false
      assert response["result"]["structuredContent"]["summary"]["modules"] > 100
    end
  end
end
