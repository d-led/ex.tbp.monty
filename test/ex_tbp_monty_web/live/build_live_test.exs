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
      assert render(view) =~ "displacement_1lm"
    end

    test "the choices are the components Monty ships", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      assert has_element?(
               view,
               "#blueprint_monty_learning_module option[value='evidence_1lm_nn5_dod003']"
             )
    end
  end

  describe "changing a component" do
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
  end
end
