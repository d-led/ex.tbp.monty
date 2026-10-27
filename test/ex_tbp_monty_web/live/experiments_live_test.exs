defmodule ExTbpMontyWeb.ExperimentsLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.Drafts

  setup do
    tmp = Path.join(System.tmp_dir!(), "studio-index-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    previous = Application.get_env(:ex_tbp_monty, :experiments_dir)
    Application.put_env(:ex_tbp_monty, :experiments_dir, tmp)

    on_exit(fn ->
      Application.put_env(:ex_tbp_monty, :experiments_dir, previous || "priv/experiments")
      File.rm_rf!(tmp)
    end)

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
