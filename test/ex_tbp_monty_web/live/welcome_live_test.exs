defmodule ExTbpMontyWeb.WelcomeLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ExTbpMontyWeb.Tour
  alias Monty.ModuleMap
  alias Monty.Test.Tmp

  setup do
    Tmp.env_dir("studio-welcome", :experiments_dir)

    :ok
  end

  describe "the front door" do
    test "it says what Monty is before it offers a list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#welcome-hero h1")
      assert view |> element("#welcome-hero") |> render() =~ "Thousand Brains Project"
    end

    test "the list of experiments and the tutorial are each one click away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#welcome-browse[href='/experiments']")

      assert has_element?(
               view,
               "#welcome-first[href='/experiments/tutorial/first_experiment']"
             )
    end

    test "the three ways in are read, build and watch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for {id, href} <- [
            {"welcome-way-experiments", "/experiments"},
            {"welcome-way-build", "/build"},
            {"welcome-way-runs", "/runs"}
          ] do
        assert has_element?(view, "##{id}[href='#{href}']"), "#{id} does not lead to #{href}"
      end
    end

    test "the shelves a run reads from are here too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#welcome-prerequisites[href='/prerequisites']")
      assert has_element?(view, "#welcome-mcp[href='/mcp/config']")
    end

    test "how much of Monty is ported is asked of the module map, not typed here", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      %{implemented: implemented, classes: classes} = ModuleMap.load() |> ModuleMap.summary()

      assert view |> element("#welcome-port") |> render() =~ "#{implemented} of #{classes}"
    end
  end

  describe "the walkthrough a first-time visitor is offered" do
    test "every step for this page and for the shell points at something it shows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for %{element: selector} <- Tour.steps(:shell) ++ Tour.steps(:welcome) do
        assert has_element?(view, selector), "the tour points at #{selector}, which is not here"
      end
    end

    test "the steps of the list are not shown here: this page has no list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for %{element: selector} <- Tour.steps(:index) do
        refute has_element?(view, selector), "#{selector} belongs to the list, not here"
      end
    end

    test "the button that starts it is in the header, where a closed column cannot hide it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "header #tour-start[phx-hook=StudioTour]")
      refute has_element?(view, "#app-sidebar #tour-start")
    end
  end

  describe "an address from before this page existed" do
    test "a bookmark of a filtered list lands on the list, filters and all", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/?agent=surf")

      assert to == ~p"/experiments?agent=surf"
    end

    test "the page itself has no filters, so it is served as it is", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#welcome-hero")
    end
  end
end
