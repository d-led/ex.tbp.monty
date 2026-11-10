defmodule ExTbpMontyWeb.ExperimentsLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ExTbpMontyWeb.Tour
  alias Monty.Studio.Drafts
  alias Monty.Test.Tmp

  setup do
    tmp = Tmp.env_dir("studio-index", :experiments_dir)

    {:ok, tmp: tmp}
  end

  describe "the list of experiments" do
    test "every experiment Monty ships is listed, with what it is made of", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/experiments")

      assert html =~ "Monty experiments"
      assert has_element?(view, "#facet-agent")
      assert has_element?(view, "#experiments")
      # One of the experiments the studio suggests, and one that runs here.
      assert render(view) =~ "base_config_10distinctobj_dist_agent"
    end

    test "the count says how many there are", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#result-count")
      assert render(view) =~ "experiments"
    end

    test "the footer says which build is running, and where the source is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#build-info")
      assert has_element?(view, "#source-repo")
    end
  end

  describe "the walkthrough a first-time visitor is offered" do
    test "every step for this page and for the shell points at something it shows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      for %{element: selector} <- Tour.steps(:shell) ++ Tour.steps(:index) do
        assert has_element?(view, selector), "the tour points at #{selector}, which is not here"
      end
    end

    test "the page offers a button that starts it, carrying the steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "button#tour-start[phx-hook=StudioTour]")

      [payload] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#tour-start")
        |> LazyHTML.attribute("data-steps")

      assert [%{"element" => _} | _] = Jason.decode!(payload)
    end

    test "the button is in the header, where a closed column cannot hide it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prerequisites")

      assert has_element?(view, "header #tour-start")
      refute has_element?(view, "#app-sidebar #tour-start")
    end

    test "the way around is a sidebar, with a toggle and every section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#app-sidebar[aria-label=Main]")
      assert has_element?(view, "#sidebar-toggle[data-sidebar-toggle]")

      for id <- ~w(nav-experiments nav-build nav-prerequisites nav-runs nav-mcp) do
        assert has_element?(view, "##{id}[data-nav]"), "#{id} is not in the sidebar"
      end
    end

    test "the button is outside LiveView's patching, so the hook keeps its element", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#tour-start[phx-update=ignore]")
    end
  end

  describe "the filters, as tags" do
    test "a tag says which value it stands for, under a name the client keeps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      # `phx-value-value` collides with the element's own value and arrives
      # empty, which is exactly how these tags were dead buttons once.
      assert has_element?(view, "#facet-agent-surf[phx-value-option=surf]")
      refute has_element?(view, "#facet-agent-surf[phx-value-value]")
    end

    test "choosing one narrows the list in place, without a navigation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")
      all = row_names(view)

      view |> element("#facet-agent-surf") |> render_click()

      assert has_element?(view, "#chip-agent-surf")
      assert has_element?(view, "#facet-agent-surf[data-active='true']")
      assert row_names(view) != all
      assert Enum.all?(row_names(view), &(&1 =~ "surf"))
    end

    test "a value in force is marked, and the others are not", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?agent=surf")

      assert has_element?(view, "#facet-agent-surf[data-active='true']")
      refute has_element?(view, "#facet-agent-dist[data-active]")
    end

    test "choosing a second value of a facet keeps the first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      view |> element("#facet-agent-surf") |> render_click()
      view |> element("#facet-agent-dist") |> render_click()

      assert has_element?(view, "#chip-agent-surf")
      assert has_element?(view, "#chip-agent-dist")
    end

    test "a starting point is another page, not a filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#templates a[data-phx-link=redirect]")
    end
  end

  describe "where the filters sit" do
    test "the tags, the values in force and the search box are all on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?agent=surf")

      ids = blocks_in_order(view)

      assert ids == ["facets", "active-filters", "experiment-search", "experiments"]
    end

    test "with nothing chosen, the box is still the last thing before the rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert blocks_in_order(view) == ["facets", "experiment-search", "experiments"]
    end
  end

  describe "narrowing the list" do
    test "a tag narrows the list and shows up as a chip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      view |> element("#facet-agent-surf") |> render_click()

      assert has_element?(view, "#chip-agent-surf")
      assert view |> element("#result-count") |> render() =~ "of"
    end

    test "a link that carries filters still opens narrowed, so a view can be shared",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?agent=surf&modules=5")

      assert has_element?(view, "#chip-agent-surf")
      assert has_element?(view, "#chip-modules-5")
    end

    # Arriving through a link used to render a page of unfiltered rows and the
    # filtered ones on top of them: the mount streamed the first page before
    # `handle_params/3` had read the query, and the reset never removed it. The
    # chips were right, so nothing caught it until a row was asserted on.
    test "arriving through a link shows only what the link asked for", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?q=first_experiment")

      assert row_names(view) == ["tutorial-first_experiment"]
    end

    test "clicking a chosen value takes the filter away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?agent=surf")

      assert has_element?(view, "#chip-agent-surf")

      view |> element("#chip-agent-surf") |> render_click()

      refute has_element?(view, "#chip-agent-surf")
      refute has_element?(view, "#active-filters")
    end

    test "searching keeps only what matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      view |> element("#experiment-search") |> render_change(%{"q" => "first_experiment"})

      assert render(view) =~ "tutorial/first_experiment"
      refute render(view) =~ "base_77obj_dist_agent"
    end

    test "the word and the tag are both required of a row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      view |> element("#facet-agent-surf") |> render_click()
      surf = row_names(view)

      view |> element("#experiment-search") |> render_change(%{"q" => "randrot"})

      assert row_names(view) != []
      assert length(row_names(view)) < length(surf)

      for name <- row_names(view) do
        assert name =~ "randrot", "the tag kept a row the word excludes: #{name}"
        assert name =~ "surf", "the word kept a row the tag excludes: #{name}"
      end
    end

    # The search reads what a row prints and nothing else. `has_element?` finds
    # an element whether or not CSS hides it, so the empty row is not proof of an
    # empty list — the rows are.
    test "a word only a config file knows does not match: the row has to show it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      view |> element("#experiment-search") |> render_change(%{"q" => "env_init_args"})
      assert row_names(view) == []

      # ...and a word the row does show does match it.
      view |> element("#experiment-search") |> render_change(%{"q" => "mujoco"})
      assert row_names(view) != []
    end

    test "clearing takes every filter away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?agent=surf&modules=5")

      view |> element("#clear-filters") |> render_click()

      refute has_element?(view, "#active-filters")
      assert row_names(view) != []
    end

    test "a long list is shown in pages, and the whole of it on request", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#show-all")

      view |> element("#show-all") |> render_click()

      assert has_element?(view, "#show-fewer")
    end
  end

  describe "what this application can actually run" do
    test "the first facet asks it, with both answers on offer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#facet-ready")
      assert has_element?(view, "#facet-ready-yes")
      assert has_element?(view, "#facet-ready-no")
    end

    # `tutorial/first_experiment` is a supervised experiment, and the stand-in
    # scene cannot say what object it showed, so this world refuses it. The same
    # config runs against MuJoCo — which is why the answer belongs to the
    # application and not to the name.
    test "an experiment this world refuses is offered under \"refused\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?ready=no&q=first_experiment")

      assert row_names(view) == ["tutorial-first_experiment"]
    end

    test "...and is not offered under \"runs here\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?ready=yes&q=first_experiment")

      assert row_names(view) == []
    end

    test "an experiment whose classes are missing is on the same side of the divide",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?ready=no&q=base_config/base")

      assert "test-base_config-base" in row_names(view)
    end

    # A world this build does not carry is postponed rather than refused. Reading
    # it for MuJoCo is what a run would step; the test environment's own default
    # is the stand-in scene, which reads every config as if it could run.
    test "an experiment whose world this build does not carry is not planned", %{conn: conn} do
      Tmp.app_env(:world_simulator, :mujoco)

      {:ok, postponed, _html} =
        live(conn, ~p"/experiments?ready=not_planned&q=omniglot_training")

      {:ok, refused, _html} = live(conn, ~p"/experiments?ready=no&q=omniglot_training")

      assert row_names(postponed) == ["tutorial-omniglot_training"]
      assert row_names(refused) == []
    end

    # The second question after "does it run": which world was it written for.
    test "...and the world its config names is a filter of its own", %{conn: conn} do
      {:ok, images, _html} = live(conn, ~p"/experiments?world=other")
      {:ok, mujoco, _html} = live(conn, ~p"/experiments?world=mujoco")

      assert has_element?(images, "#chip-world-other")
      assert row_names(images) != []
      assert row_names(mujoco) != []
      assert Enum.all?(row_names(images), &(&1 not in row_names(mujoco)))
      assert "base_config_10distinctobj_dist_agent" in row_names(mujoco)
    end

    test "the column says the same thing as the pill that filters it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments?ready=yes&q=base_config_10distinctobj")

      assert view |> render() =~ "runs here"
    end
  end

  describe "what is yours" do
    test "a draft built here is offered before Monty's own", %{conn: conn, tmp: tmp} do
      File.write!(Path.join(tmp, "mine.yaml"), config_text("mine"))
      assert "mine" in Drafts.names()

      {:ok, view, _html} = live(conn, ~p"/experiments")

      assert has_element?(view, "#draft-mine")
    end
  end

  # The experiments the list is showing, read off the row ids.
  defp row_names(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#experiments tr[id]")
    |> LazyHTML.attribute("id")
    |> List.flatten()
    |> Enum.map(&String.trim_leading(&1, "experiment-"))
    |> Enum.reject(&(&1 == "experiments-empty"))
  end

  # The blocks of the results section, in the order a reader meets them: what
  # narrows the list, then the rows it narrows.
  # The blocks that narrow the list, in the order the page puts them in. The rows
  # are a table's body rather than a sibling of the filters, so the order is the
  # document's, read off the ids that are there rather than assumed.
  defp blocks_in_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#facets, #active-filters, #experiment-search, #experiments")
    |> LazyHTML.attribute("id")
    |> List.flatten()
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
