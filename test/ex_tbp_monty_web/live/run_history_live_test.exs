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
      RunHistory.record_step(
        run,
        %{
          "step" => 0,
          "goals" => 1,
          "votes" => %{"sent" => 1, "used" => 1},
          "percepts" => ["patch"],
          "inputs" => %{"learning_module_0" => 1},
          "actions" => 1,
          "duration_us" => 120
        },
        moment(0)
      )

    {:ok, run} =
      RunHistory.record_step(
        run,
        %{
          "step" => 1,
          "goals" => 0,
          "votes" => %{"sent" => 1, "used" => 1},
          "percepts" => ["patch"],
          "inputs" => %{"learning_module_0" => 1},
          "actions" => 1,
          "duration_us" => 140
        },
        moment(1)
      )

    {:ok, run} = RunHistory.finish(run, %{"steps" => 2, "votes_used" => 2})

    {:ok, run: run}
  end

  # A step's moment: what the sensor was looking at, so a replay has a frame.
  defp moment(step) do
    %{
      "step" => step,
      "sensors" => %{"patch" => %{"location" => [step * 0.01, 0.0, 0.1], "value" => 0.0}}
    }
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

  describe "replaying a run" do
    test "opens at the last step, with the picture that step saw", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-panel")
      assert has_element?(view, "#replay-slider")
      assert has_element?(view, "#replay-frame-patch")
      assert view |> element("#replay-step") |> render() =~ "step 1"
      assert view |> element("#replay-frame-patch") |> render() =~ "step 1"
    end

    test "moving the slider shows that step, from the record", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> element("#replay-seek") |> render_change(%{"step" => "0"})

      assert view |> element("#replay-step") |> render() =~ "step 0"
      assert view |> element("#replay-frame-patch") |> render() =~ "x 0.00 m"
    end

    test "the chart follows the step and can be zoomed", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-chart polyline")

      view |> element("#replay-zoom-in") |> render_click()
      assert has_element?(view, "#replay-chart")

      view |> element("#replay-zoom-all") |> render_click()

      # "all" is the whole run, so the window is labelled with both ends.
      assert view |> element("#replay-panel") |> render() =~ "steps 0–1"
    end

    test "a chart can show another series", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> element("#replay-series") |> render_change(%{"series" => "votes_used"})

      # Votes are counts, not metres.
      assert has_element?(view, "#replay-chart")
      refute view |> element("#replay-chart") |> render() =~ " m"
    end

    test "playing walks the steps forward on its own", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # Playing from the end starts again at the beginning, which is what a
      # person who pressed play wanted.
      view |> element("#replay-play") |> render_click()
      assert view |> element("#replay-step") |> render() =~ "step 0"
    end

    test "a run with no steps says so instead of showing an empty slider", %{conn: conn} do
      {:ok, empty} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{empty.id}")

      assert has_element?(view, "#replay-empty")
      refute has_element?(view, "#replay-slider")
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
