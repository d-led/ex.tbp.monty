defmodule ExTbpMontyWeb.ModulesLiveTest do
  use ExTbpMontyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Monty.ModuleMap

  defp open(conn) do
    live(conn, ~p"/modules")
  end

  # The page opens on one page of the map. A test about what is *in* the map asks
  # for all of it, so what it asserts is the map and not the page size.
  defp open_the_whole_map(conn) do
    live(conn, ~p"/modules?size=all")
  end

  # The rows the table is showing, in order.
  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#modules tr[id]")
    |> LazyHTML.attribute("id")
  end

  # The map is hundreds of rows of markup, and rendering all of it before the page
  # can be read is a render that keeps the socket from answering while it runs.
  # So the first paint is one page of it, and the rest is one click away.
  test "opens on one page of the map, and shows the rest when asked", %{conn: conn} do
    {:ok, view, _html} = open(conn)
    total = ModuleMap.summary(ModuleMap.load()).classes

    first_page = rows(view)

    assert length(first_page) < total
    assert has_element?(view, "#show-all")
    refute has_element?(view, "#show-fewer")

    view |> element("#show-all") |> render_click()
    assert_patch(view, ~p"/modules?size=all")

    all = rows(view)

    assert length(all) == total
    # What the first paint showed is the beginning of the map, not a sample of it.
    assert Enum.take(all, length(first_page)) == first_page
    assert has_element?(view, "#show-fewer")

    view |> element("#show-fewer") |> render_click()

    assert length(rows(view)) == length(first_page)
  end

  test "shows every class the map names, with its module and status", %{conn: conn} do
    {:ok, view, html} = open_the_whole_map(conn)

    assert html =~ "Monty Class"
    assert html =~ "Elixir Module"
    assert html =~ "Stand-In Elixir Module"
    assert html =~ "of #{ModuleMap.summary(ModuleMap.load()).classes} classes"

    # A class that is written, and the module the naming rule gives it.
    assert has_element?(view, "#modules tr", "CameraSM")
    assert html =~ "Monty.Frameworks.Models.SensorModules.CameraSM"
  end

  test "links the Monty class at the commit the map was read from", %{conn: conn} do
    {:ok, view, _html} = open_the_whole_map(conn)
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
    {:ok, view, _html} = open_the_whole_map(conn)

    row =
      view
      |> element("#modules-table")
      |> render()

    assert row =~ "Monty.Runtime.Model"
    assert row =~ "Monty.Runtime.Step"
    assert row =~ "priv/monty_py/world.py"
  end

  test "filters by any word of a row, and says how many are left", %{conn: conn} do
    {:ok, view, _html} = open_the_whole_map(conn)

    html =
      view
      |> element("#modules-filter")
      |> render_change(%{"q" => "montybase planned"})

    assert html =~ "MontyBase"
    refute html =~ "CameraSM"
    assert html =~ "classes"
    assert_patch(view)
  end

  test "filters by status, and the status is in the address", %{conn: conn} do
    {:ok, view, _html} = open_the_whole_map(conn)

    view
    |> element("#modules-status button[phx-value-status=planned]")
    |> render_click()

    assert_patch(view, ~p"/modules?status=planned")

    # Everything left is what the filter promises: a written class is gone.
    refute render(view) =~ "CameraSM"
  end

  test "opens on a filtered view somebody sent", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/modules?q=montybase&status=planned&size=all")

    html = render(view)

    assert html =~ "MontyBase"
    refute html =~ "CameraSM"
  end

  test "a status the page does not offer shows everything rather than nothing", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/modules?status=nonsense&size=all")

    assert html =~ "CameraSM"
  end
end
