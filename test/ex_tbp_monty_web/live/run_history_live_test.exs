defmodule ExTbpMontyWeb.RunHistoryLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Monty.Studio.RunHistory

  # A run as a finished experiment leaves it, in whatever state a test needs.
  defp insert_run(%{experiment: experiment, status: status}) do
    {:ok, run} =
      RunHistory.start(%{experiment: experiment, source: "monty", steps: 0, config: %{}})

    if status == "running" do
      run
    else
      {:ok, closed} = RunHistory.finish(run, %{"reason" => "as the test asked"}, status)
      closed
    end
  end

  # A job Oban has started: `executing` from `attempted_at` until an outcome.
  defp running(job) do
    {1, nil} =
      ExTbpMonty.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempted_at: DateTime.utc_now()]
      )

    :ok
  end

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

  # A step's moment, recorded the way a run records one: the arrays a camera
  # answers with go in, and the pictures a page draws them into come out. The
  # depth grows with the step, so a step is visibly a different step.
  defp moment(step) do
    near = 0.02 + step * 0.01

    Monty.Studio.RunLog.moment(%{step: step}, %{
      Monty.Simulators.Synthetic.Environment.agent_id() => %{
        "patch" => %{
          "location" => [step * 0.01, 0.0, 0.1],
          "value" => 0.0,
          "depth" => [[near, near + 0.02], [near, near + 0.02]],
          "rgba" => [[[0.2, 0.7, 0.2, 1.0]], [[0.2, 0.7, 0.2, 1.0]]]
        }
      }
    })
  end

  describe "the list of runs" do
    test "shows every run with how it ended", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#run-#{run.id}")
      assert render(view) =~ "tutorial/first_experiment"
      assert render(view) =~ "finished"
    end

    test "a run that has not started says queued, not running", %{conn: conn} do
      # A record is written the moment a run is queued, so its own status says
      # `running` before anything is running. The list says what is true.
      {:ok, queued} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, _job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert view |> element("#run-#{queued.id}") |> render() =~ "queued"
      refute view |> element("#run-#{queued.id}") |> render() =~ "running"
    end

    test "says so when nothing has run", %{conn: conn} do
      # Empty is the state a fresh database is in, and it has to be a page.
      ExTbpMonty.Repo.delete_all(Monty.Studio.RunHistory.Run)

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#runs")
    end
  end

  describe "narrowing the list" do
    test "a state pill filters the list, and the address carries it", %{conn: conn, run: run} do
      failed =
        insert_run(%{experiment: "base_config_10distinctobj_dist_agent", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#run-#{run.id}")
      assert has_element?(view, "#run-#{failed.id}")

      view |> element("#filter-failed") |> render_click()

      assert_patch(view, ~p"/runs?#{[state: "failed", q: ""]}")
      assert has_element?(view, "#run-#{failed.id}")
      refute has_element?(view, "#run-#{run.id}")
    end

    test "every word of the filter must match", %{conn: conn, run: run} do
      _base =
        insert_run(%{experiment: "base_config_10distinctobj_dist_agent", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      # One word narrows to the two names that carry it.
      view |> element("#run-search") |> render_change(%{"q" => "base"})
      assert_patch(view, ~p"/runs?#{[state: "all", q: "base"]}")
      refute has_element?(view, "#run-#{run.id}")

      # A second word narrows further: both have to appear, not either.
      view |> element("#run-search") |> render_change(%{"q" => "base dist"})
      assert_patch(view, ~p"/runs?#{[state: "all", q: "base dist"]}")

      view |> element("#run-search") |> render_change(%{"q" => "base nothing"})
      assert view |> render() =~ "No run matches"
    end

    test "the list is paged when there are more runs than a page", %{conn: conn} do
      for _ <- 1..26,
          do: insert_run(%{experiment: "tutorial/first_experiment", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      # The setup's own run makes twenty-seven.
      assert view |> element("#run-count") |> render() =~ "1–25 of 27"
      refute has_element?(view, "#page-previous")

      view |> element("#page-next") |> render_click()

      assert_patch(view, ~p"/runs?#{[state: "all", q: "", page: 2]}")
      assert view |> element("#run-count") |> render() =~ "26–27 of 27"
      assert view |> element("#page-number") |> render() =~ "page 2 of 2"
    end
  end

  describe "stopping a run from the list" do
    test "a run that is waiting can be stopped", %{conn: conn} do
      {:ok, queued} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, _job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#stop-#{queued.id}") |> render_click()

      assert render(view) =~ "Stopped: the run never started."
      assert RunHistory.get(queued.id).status == "failed"

      # Nothing is left to stop.
      refute has_element?(view, "#stop-#{queued.id}")
    end

    test "ending is offered only for a run that is going", %{conn: conn} do
      {:ok, queued} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#end-#{queued.id}")

      :ok = running(job)

      {:ok, view, _html} = live(conn, ~p"/runs")

      assert has_element?(view, "#end-#{queued.id}")
    end

    test "a run that finished offers nothing to stop", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#stop-#{run.id}")
      refute has_element?(view, "#end-#{run.id}")
      assert has_element?(view, "#delete-#{run.id}")
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

    test "offers the files the run wrote, with their sizes", %{conn: conn, run: run} do
      Monty.Test.Tmp.env_dir("studio-runs", :studio_artifacts_dir)
      :ok = Monty.Studio.Artifacts.start(run.id)

      File.write!(
        Path.join(Monty.Studio.Artifacts.dir(run.id), "eval_stats.csv"),
        "episode,performance\n"
      )

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-file-eval_stats-csv")
      assert has_element?(view, "a[href='/runs/#{run.id}/files/eval_stats.csv']")
    end

    test "says so when a run wrote nothing", %{conn: conn, run: run} do
      # A run whose config asks for a logger this port does not have writes no
      # files at all, and the page says where to look rather than staying silent.
      Monty.Test.Tmp.env_dir("studio-runs", :studio_artifacts_dir)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-files-empty")
    end
  end

  describe "a run that did not finish" do
    test "says what stopped it, above everything else", %{conn: conn, run: run} do
      {:ok, failed} =
        RunHistory.finish(run, %{"reason" => "the world would not start"}, "failed")

      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      assert view |> element("#run-failure") |> render() =~ "the world would not start"
    end

    test "a run whose process is gone is closed when its page is opened", %{conn: conn} do
      # The row a restart leaves behind: `running`, with no job and no process.
      # Opening the page is the first thing that could notice, so it notices.
      {:ok, abandoned} =
        RunHistory.start(%{experiment: "tutorial/first_experiment", source: "monty", steps: 2})

      {:ok, view, _html} = live(conn, ~p"/runs/#{abandoned.id}")

      assert RunHistory.get(abandoned.id).status == "failed"
      assert view |> element("#run-failure") |> render() =~ "stopped before it finished"
    end

    test "a run that finished says nothing about how it ended", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#run-failure")
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

      # Step 0 saw the surface 2 cm away, step 1 further back: the frame says
      # which, in the same words the run's own log used.
      assert view |> element("#replay-frame-patch") |> render() =~ "depth 0.020–0.040 m"

      view |> element("#replay-seek") |> render_change(%{"step" => "1"})

      assert view |> element("#replay-frame-patch") |> render() =~ "depth 0.030–0.050 m"
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
