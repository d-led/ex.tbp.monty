defmodule ExTbpMontyWeb.McpLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "the page that points an editor at the server" do
    test "names the endpoint this instance answers on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/mcp/config")

      assert has_element?(view, "#mcp-endpoint")
      # The test's own origin, not a port borrowed from somebody's document.
      assert view |> element("#mcp-url") |> render() =~ "www.example.com/mcp"
    end

    test "hands over the configuration in the shape an editor reads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/mcp/config")

      config =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#mcp-config-text")
        |> LazyHTML.text()
        |> Jason.decode!()

      assert %{"servers" => %{"monty-studio" => server}} = config
      assert server["type"] == "http"
      assert server["url"] == "http://www.example.com/mcp"
    end

    test "offers to copy the endpoint and the configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/mcp/config")

      assert has_element?(view, "#copy-mcp-url[phx-hook]")
      assert has_element?(view, "#copy-mcp-config[phx-hook]")
    end

    test "says which tools it answers, and where the contract is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/mcp/config")

      assert has_element?(view, "#mcp-tools-documentation")
      assert render(view) =~ "monty_search_docs"
      assert has_element?(view, "#mcp-tools-experiments")
    end
  end
end
