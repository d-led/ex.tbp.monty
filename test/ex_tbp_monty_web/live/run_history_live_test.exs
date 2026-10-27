defmodule ExTbpMontyWeb.RunHistoryLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.RunHistory

  setup do
    {:ok, run} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: 2,
        seed: 42,
        config: %{"experiment" => %{"config" => %{"seed" => 42}}},
        inputs: %{"groups" => %{"monty/learning_module" => "displacement_1lm"}, "seed" => 42}
      })

    {:ok, run} =
      RunHistory.record_step(run, %{
        "step" => 0,
        "goals" => 1,
        "votes" => %{"sent" => 1, "used" => 1},
        "percepts" => ["patch"],
        "inputs" => %{"learning_module_0" => 1}
      })

    {:ok, run} =
      RunHistory.record_step(run, %{
        "step" => 1,
        "goals" => 0,
        "votes" => %{"sent" => 1, "used" => 1},
        "percepts" => ["patch"],
        "inputs" => %{"learning_module_0" => 1}
      })

    {:ok, run} = RunHistory.finish(run, %{"steps" => 2, "votes_used" => 2})

    {:ok, run: run}
  end

  describe "the list of runs" do
    test "shows every run with how it ended", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#run-#{run.id}")
      assert render(view) =~ "tutorial/first_experiment"
      assert render(view) =~ "finished"
    end

    test "says so when nothing has run", %{conn: conn} do
      # Empty is the state a fresh database is in, and it has to be a page.
      ExTbpMonty.Repo.delete_all(Monty.Studio.RunHistory.Run)

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#runs")
    end
  end

  describe "one run" do
    test "keeps its config snapshot, its inputs and its log", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-config")
      assert render(view) =~ "monty/learning_module"
      assert has_element?(view, "#log-0")
      assert has_element?(view, "#log-1")
    end

    test "a run id that does not exist is a page, not a crash", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/runs/00000000-0000-4000-8000-000000000000")

      assert html =~ "gone"
    end
  end

  describe "deleting a run" do
    test "asks before it forgets anything", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#confirm-delete")

      view |> element("#delete-#{run.id}") |> render_click()

      assert has_element?(view, "#confirm-delete")
      assert RunHistory.get(run.id) != nil
    end

    test "keeping it leaves the record alone", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#delete-#{run.id}") |> render_click()
      view |> element("#cancel-delete") |> render_click()

      refute has_element?(view, "#confirm-delete")
      assert RunHistory.get(run.id) != nil
    end

    test "confirming forgets it", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#delete-#{run.id}") |> render_click()
      view |> element("#confirm-delete-button") |> render_click()

      assert RunHistory.get(run.id) == nil
      refute has_element?(view, "#run-#{run.id}")
    end
  end
end
