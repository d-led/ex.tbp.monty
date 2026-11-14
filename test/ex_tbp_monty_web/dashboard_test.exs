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
