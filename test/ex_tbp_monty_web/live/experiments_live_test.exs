defmodule ExTbpMontyWeb.ExperimentsLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.Drafts
  alias Monty.Test.Tmp

  setup do
    tmp = Tmp.env_dir("studio-index", :experiments_dir)

    {:ok, tmp: tmp}
  end

  describe "the list you land on" do
    test "every experiment Monty ships is listed, with what it is made of", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Monty experiments"
      assert has_element?(view, "#facet-agent")
      assert has_element?(view, "#experiments")
      assert render(view) =~ "tutorial/first_experiment"
    end

    test "the count says how many there are", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#result-count")
      assert render(view) =~ "experiments"
    end

    test "the footer says which build is running, and where the source is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#build-info")
      assert has_element?(view, "#source-repo")
    end
  end

  describe "the walkthrough a first-time visitor is offered" do
    test "every step points at something this page actually shows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for %{element: selector} <- ExTbpMontyWeb.Tour.steps() do
        assert has_element?(view, selector), "the tour points at #{selector}, which is not here"
      end
    end

    test "the page offers a button that starts it, carrying the steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "button#tour-start[phx-hook=StudioTour]")

      [payload] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#tour-start")
        |> LazyHTML.attribute("data-steps")

      assert [%{"element" => _} | _] = Jason.decode!(payload)
    end

    test "the button is in the sidebar, so a page without the list still has it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prerequisites")

      assert has_element?(view, "#app-sidebar #tour-start")
    end

    test "the way around is a sidebar, with a toggle and every section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#app-sidebar[aria-label=Main]")
      assert has_element?(view, "#sidebar-toggle[data-sidebar-toggle]")

      for id <- ~w(nav-experiments nav-build nav-prerequisites nav-runs nav-mcp) do
        assert has_element?(view, "##{id}[data-nav]"), "#{id} is not in the sidebar"
      end
    end

    test "the button is outside LiveView's patching, so the hook keeps its element", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#tour-start[phx-update=ignore]")
    end
  end

  describe "narrowing the list" do
    test "a facet pill narrows the list and shows up as a chip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#facet-agent-surf") |> render_click()

      assert has_element?(view, "#chip-agent-surf")
      assert_patch(view, ~p"/?agent=surf")

      # Everything left is a surface experiment.
      assert view |> element("#result-count") |> render() =~ "of"
    end

    test "the filters are in the URL, so a filtered view can be shared", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?agent=surf&modules=5")

      assert has_element?(view, "#chip-agent-surf")
      assert has_element?(view, "#chip-modules-5")
    end

    test "clicking a chosen value takes the filter away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?agent=surf")

      assert has_element?(view, "#chip-agent-surf")

      view |> element("#chip-agent-surf") |> render_click()

      refute has_element?(view, "#chip-agent-surf")
    end

    test "searching keeps only what matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#experiment-search") |> render_change(%{"q" => "first_experiment"})

      assert_patch(view, ~p"/?q=first_experiment")
      assert render(view) =~ "tutorial/first_experiment"
      refute render(view) =~ "base_77obj_dist_agent"
    end

    test "clearing takes every filter away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?agent=surf&modules=5")

      view |> element("#clear-filters") |> render_click()

      assert_patch(view, ~p"/")
      refute has_element?(view, "#active-filters")
    end

    test "a long list is shown in pages, and the whole of it on request", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#show-all")

      view |> element("#show-all") |> render_click()

      assert_patch(view, ~p"/?size=all")
      assert has_element?(view, "#show-fewer")
    end
  end

  describe "what is yours" do
    test "a draft built here is offered before Monty's own", %{conn: conn, tmp: tmp} do
      File.write!(Path.join(tmp, "mine.yaml"), config_text("mine"))
      assert "mine" in Drafts.names()

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#draft-mine")
    end
  end

  defp config_text(name) do
    """
    # @package _global_

    defaults:
      - /monty: graph_exp1000_e3_t3
      - /monty/learning_module: displacement_1lm
      - /monty/sensor_module: camera_dist_raw0
      - /monty/connectivity: 1lm_1sm

    experiment:
      _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
      config:
        logging:
          run_name: "#{name}"
    """
  end
end
