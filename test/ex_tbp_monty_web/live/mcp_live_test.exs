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

    test "lists every tool a client is offered, with what it does", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/mcp/config")

      # The section is rendered from `tools/list`, so the page cannot list a tool
      # that does not exist, or miss one that does.
      for name <- ExTbpMonty.Mcp.Tools.names() do
        assert html =~ name, "the page does not list #{name}"
      end

      assert html =~ "#{ExTbpMonty.Mcp.Tools.count()} tools"
      assert has_element?(view, "#mcp-tools-documentation")
      assert has_element?(view, "#mcp-tools-experiments")
      assert has_element?(view, "#mcp-tools-runs")
    end

    test "says which of them change something", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/mcp/config")

      writers = length(ExTbpMonty.Mcp.Tools.writers())
      assert html =~ "#{writers} of them change something"

      # The one that deletes says so, in the list, from its own annotation.
      runs = view |> element("#mcp-tools-runs") |> render()
      assert runs =~ "monty_delete_runs"
      assert runs =~ "deletes"
    end
  end
end
