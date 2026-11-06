defmodule ExTbpMontyWeb.ModulesLiveTest do
  use ExTbpMontyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Monty.ModuleMap

  defp open(conn) do
    live(conn, ~p"/modules")
  end

  test "shows every class the map names, with its module and status", %{conn: conn} do
    {:ok, view, html} = open(conn)

    assert html =~ "Monty Class"
    assert html =~ "Elixir Module"
    assert html =~ "Stand-In Elixir Module"
    assert html =~ "of #{ModuleMap.summary(ModuleMap.load()).classes} classes"

    # A class that is written, and the module the naming rule gives it.
    assert has_element?(view, "#modules tr", "CameraSM")
    assert html =~ "Monty.Frameworks.Models.SensorModules.CameraSM"
  end

  test "links the Monty class at the commit the map was read from", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    commit = ModuleMap.sources()["monty"]["commit"]

    assert has_element?(
             view,
             ~s|a[href="https://github.com/thousandbrainsproject/tbp.monty/blob/#{commit}/src/tbp/monty/frameworks/models/sensor_modules.py"]|,
             "CameraSM"
           )
  end

  test "says what stands in for a class the runtime replaces, and nothing for one it does not", %{
    conn: conn
  } do
    {:ok, view, _html} = open(conn)

    row =
      view
      |> element("#modules-table")
      |> render()

    assert row =~ "Monty.Runtime.Model"
    assert row =~ "Monty.Runtime.Step"
    assert row =~ "priv/monty_py/world.py"
  end

  test "filters by any word of a row, and says how many are left", %{conn: conn} do
    {:ok, view, _html} = open(conn)

    html =
      view
      |> element("#modules-filter")
      |> render_change(%{"q" => "graphlm planned"})

    assert html =~ "GraphLM"
    refute html =~ "CameraSM"
    assert html =~ "classes"
    assert_patch(view)
  end

  test "filters by status, and the status is in the address", %{conn: conn} do
    {:ok, view, _html} = open(conn)

    view
    |> element("#modules-status button[phx-value-status=planned]")
    |> render_click()

    assert_patch(view, ~p"/modules?status=planned")

    # Everything left is what the filter promises: a written class is gone.
    refute render(view) =~ "CameraSM"
  end

  test "opens on a filtered view somebody sent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/modules?q=graphlm&status=planned")

    html = render(view)

    assert html =~ "GraphLM"
    refute html =~ "CameraSM"
  end

  test "a status the page does not offer shows everything rather than nothing", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/modules?status=nonsense")

    assert html =~ "CameraSM"
  end
end
