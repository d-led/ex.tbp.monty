defmodule ExTbpMontyWeb.SettingsLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.Settings

  describe "the settings page" do
    test "shows each setting against what it already is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#setting-run_refresh_ms")
      assert view |> element("#settings_run_refresh_ms") |> render() =~ ~s(value="250")
    end

    test "saves what a reader types, and says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#settings-form", settings: %{run_refresh_ms: "600"})
        |> render_submit()

      assert html =~ "Saved"
      assert Settings.get("run_refresh_ms") == 600
    end

    test "refuses a value outside the range, and keeps the old one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#settings-form", settings: %{run_refresh_ms: "1"})
        |> render_submit()

      assert html =~ "has to be between"
      assert Settings.get("run_refresh_ms") == 250
    end
  end

  # The difference the page exists to draw: a boot value is shown, because a
  # page that offered to change it would be lying.
  describe "this instance" do
    test "names the database write timeout, and says it needs a restart", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      _ = view

      assert has_element?(view, "#system-Database-write-timeout")
      assert render(view) =~ "a change needs a restart"
    end
  end
end
