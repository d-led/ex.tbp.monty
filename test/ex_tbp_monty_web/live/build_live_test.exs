defmodule ExTbpMontyWeb.BuildLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.Drafts
  alias Monty.Test.Tmp

  setup do
    tmp = Tmp.env_dir("studio-build", :experiments_dir)

    {:ok, tmp: tmp}
  end

  describe "the form you land on" do
    test "it is already complete: a name and a starting point, everything else chosen", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/build")

      assert has_element?(view, "#blueprint-form")
      assert has_element?(view, "#blueprint-diagram")

      # The starting point is a template, so the diagram and the config already
      # describe an experiment a run accepts, rather than `tutorial/first_experiment`
      # and its `DisplacementGraphLM`.
      assert render(view) =~ "base_config_10distinctobj_dist_agent"
      assert render(view) =~ "EvidenceGraphLM"
    end

    test "the choices are the components Monty ships", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      assert has_element?(
               view,
               "#blueprint_monty_learning_module option[value='evidence_1lm_nn5_dod003']"
             )
    end

    # A person who has never seen Monty's conf should still know which field
    # decides what. The group's own name stays on the page, because it is the
    # name an expert will look for in the config.
    test "each choice says what it chooses, and names Monty's group", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")
      html = render(view)

      assert html =~ "Recognising"
      assert html =~ "How what it sees is matched to what it remembers"
      assert html =~ "Monty&#39;s group: monty/learning_module"
    end
  end

  describe "adjusting an experiment" do
    test "a draft opens in the builder with its own choices, ready to change", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/build")
      view |> element("#blueprint-form") |> render_change(%{"blueprint" => %{"name" => "mine"}})
      view |> element("#blueprint-form") |> render_submit()

      {:ok, view, _html} = live(conn, ~p"/build?base=mine")

      assert view
             |> element("#blueprint-form input[name='blueprint[name]']")
             |> render() =~ "mine"

      assert has_element?(
               view,
               "#blueprint-form select[name='blueprint[base]'] option[value='mine'][selected]"
             )

      refute has_element?(view, "[id^=finding-unknown_base]")
    end
  end

  describe "importing a file" do
    test "the page offers an upload, with the name it will be saved as", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      assert has_element?(view, "#import-form")
      assert has_element?(view, "#import-form input[name='import[name]']")
      assert has_element?(view, "#import-form input[type=file]")
    end
  end

  describe "changing a component" do
    # The written file is the output of this page, not its subject: what a
    # reader builds with is the diagram and the facts. So the file is drawn
    # closed — the browser's `details`, which keeps whatever state a reader left
    # it in while the preview patches itself.
    test "the config is a closed box until a reader opens it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      box = view |> element("#blueprint-config-box") |> render()

      assert box =~ "<details"
      refute box =~ ~r/<details[^>]*\sopen/
      assert box =~ "The config"
      assert has_element?(view, "#blueprint-config")
    end

    test "a different learning module is shown in the diagram and in the config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      view
      |> element("#blueprint-form")
      |> render_change(%{"blueprint" => %{"monty_learning_module" => "evidence_1lm_nn5_dod003"}})

      assert render(view) =~ "EvidenceGraphLM"

      # The written config names the group rather than the module it resolves
      # to: it is an experiment file, and the group is the choice.
      config = view |> element("#blueprint-config") |> render()
      assert config =~ "/monty/learning_module"
      assert config =~ "evidence_1lm_nn5_dod003"
    end

    test "an option Monty does not have is refused before anything is written", %{
      conn: conn,
      tmp: tmp
    } do
      {:ok, view, _html} = live(conn, ~p"/build")

      view
      |> element("#blueprint-form")
      |> render_change(%{
        "blueprint" => %{"name" => "typo", "monty_learning_module" => "not_a_learning_module"}
      })

      assert has_element?(view, "[id^=finding-unknown_group_option]")
      assert view |> element("#save-blueprint") |> render() =~ "disabled"
      refute File.exists?(Path.join(tmp, "typo.yaml"))
    end
  end

  describe "saving" do
    test "what is saved is an experiment file, and it opens", %{conn: conn, tmp: tmp} do
      {:ok, view, _html} = live(conn, ~p"/build")

      view |> element("#blueprint-form") |> render_change(%{"blueprint" => %{"name" => "mine"}})

      assert {:error, {:live_redirect, %{to: "/experiments/mine"}}} =
               view |> element("#blueprint-form") |> render_submit()

      assert File.exists?(Path.join(tmp, "mine.yaml"))
      assert "mine" in Drafts.names()

      {:ok, written} = Drafts.read("mine")
      assert written =~ "# @package _global_"
      assert written =~ "defaults:"
    end

    # A draft that cannot be written is not a crash: the form is what the page is
    # for. `{:ok, _} = Drafts.save(...)` took the LiveView down and lost it
    # (soundcheck SC603). The folder is made unwritable rather than mocked, so the
    # path exercised is the real `File.write/2`.
    test "a draft that cannot be written keeps the form, and says why", %{conn: conn, tmp: tmp} do
      File.chmod!(tmp, 0o500)
      on_exit(fn -> File.chmod!(tmp, 0o700) end)

      {:ok, view, _html} = live(conn, ~p"/build")

      view |> element("#blueprint-form") |> render_change(%{"blueprint" => %{"name" => "mine"}})

      html = view |> element("#blueprint-form") |> render_submit()

      assert html =~ "Could not save the draft"
      refute File.exists?(Path.join(tmp, "mine.yaml"))
      assert has_element?(view, "#blueprint-form")
    end
  end
end
