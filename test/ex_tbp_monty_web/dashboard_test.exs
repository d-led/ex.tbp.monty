defmodule ExTbpMontyWeb.DashboardTest do
  @moduledoc """
  The dashboard is the one page of this application a dependency draws, and the
  one page that is not reached by a live navigation. Both are asserted here
  because both are what a reader is left without: an entry that leads nowhere,
  and a screen with no way back to the studio — which, in the window, is a screen
  with no exit at all (`docs/desktop.md`).
  """

  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "the dashboard" do
    test "is the last place in the sidebar, after the settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      assert view |> sidebar_entries() |> Enum.take(-2) == ~w(nav-settings nav-dashboard)
    end

    test "is a page of its own, so the entry is a navigation and not a patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, ~s(#nav-dashboard[href="/dev/dashboard"]))
    end

    test "says how to get back to the studio", %{conn: conn} do
      # `/dev/dashboard` is a redirect to the dashboard's home page, which is the
      # page a reader lands on.
      document =
        conn
        |> get("/dev/dashboard/home")
        |> html_response(200)
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(document, "#dashboard-way-back") |> LazyHTML.attribute("href") == [
               "/"
             ]
    end

    # Development is where a reader meets the dashboard, and it is where Phoenix
    # annotates every tag it renders: the page's body tag is `<body phx-r="1">`
    # and not `<body>`. A link added only to an unannotated page is a link nobody
    # sees, which is how this one first went missing.
    test "puts the link inside the body tag even when Phoenix annotated it", %{conn: conn} do
      plug = ExTbpMontyWeb.DashboardWayBack.init(back: "/", label: "Monty on the BEAM")

      body =
        conn
        |> put_resp_content_type("text/html")
        |> resp(200, ~s(<html><body phx-r="1"><main>the dashboard</main></body></html>))
        |> ExTbpMontyWeb.DashboardWayBack.call(plug)
        |> send_resp()
        |> Map.fetch!(:resp_body)

      assert body =~ ~s(<body phx-r="1"><a id="dashboard-way-back")
    end
  end

  defp sidebar_entries(view) do
    view
    |> element("#app-sidebar")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-nav]")
    |> LazyHTML.attribute("id")
  end
end
