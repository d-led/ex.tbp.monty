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

  # A finished run that kept what its modules believed: one graph per object,
  # with the strongest evidence the module held for it. This is the shape the
  # chart of every object is drawn from. One map is one step; a list of maps is
  # one step each, which is what a run that changed its mind looks like.
  defp run_believing(steps) when is_map(steps), do: run_believing([steps])

  defp run_believing(steps) do
    {:ok, run} =
      RunHistory.start(%{
        experiment: "tutorial/first_experiment",
        source: "monty",
        steps: length(steps),
        config: %{}
      })

    run =
      steps
      |> Enum.with_index()
      |> Enum.reduce(run, fn {evidence, step}, run ->
        beliefs = %{
          "learning_module_0" => %{
            "graphs" =>
              Map.new(evidence, fn {object, value} -> {object, %{"max_evidence" => value}} end)
          }
        }

        entry = %{
          "step" => step,
          "percepts" => ["patch"],
          "inputs" => %{"learning_module_0" => 1},
          "votes" => %{"sent" => 1, "used" => 1},
          "goals" => 1,
          "actions" => 1,
          "duration_us" => 120,
          "beliefs" => beliefs
        }

        {:ok, run} = RunHistory.record_step(run, entry, moment(step))
        run
      end)

    {:ok, run} = RunHistory.finish(run, %{"steps" => length(steps)})
    run
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

    test "says which episode it is", %{conn: conn} do
      # After a parallel start the name alone does not say which row this is.
      {:ok, run} =
        RunHistory.start(%{
          experiment: "base_10simobj_surf_agent",
          source: "monty",
          steps: 0,
          episode: 3,
          config: %{}
        })

      {:ok, run} = RunHistory.finish(run, %{})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#run-episode") |> render() =~ "episode 3"
    end

    test "a run id that does not exist is a page, not a crash", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/runs/00000000-0000-4000-8000-000000000000")

      assert html =~ "gone"
    end

    test "an address that is not a run id at all is that same page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/runs/not-a-run")

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

    test "a crash is said in a sentence, with the trace folded away", %{conn: conn, run: run} do
      crash = """
      ** (ArgumentError) Monty.Frameworks.Actions.SetAgentPose sets a pose outright, which the stand-in world does not do; use a simulator behind Monty.Simulators.Port.Environment instead
          (ex_tbp_monty 0.1.0) lib/monty/simulators/synthetic/kinematics.ex:118: Monty.Simulators.Synthetic.Kinematics.act/2
          (elixir 1.20.4) lib/enum.ex:2622: Enum."-reduce/3-lists^foldl/2-0-"/3
      """

      {:ok, failed} = RunHistory.finish(run, %{"reason" => crash}, "failed")

      {:ok, view, _html} = live(conn, ~p"/runs/#{failed.id}")

      assert view |> element("#run-failure-what") |> render() =~
               "cannot be posed directly"

      assert has_element?(view, "#run-failure-hint")

      # The trace is there for whoever wants it, and costs nobody else a glance.
      assert has_element?(view, "#run-failure-technical pre")
      refute has_element?(view, "details#run-failure-technical[open]")
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

    test "hovering the line names the step and the value it was", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The readout is made on the server, so it is worded like the rest of the
      # page; the hover itself only picks the nearest one and draws the line.
      assert view |> element("#replay-chart-hover") |> render() =~ "step 1 · "
    end

    test "a series measured in metres says so", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      view |> element("#replay-series") |> render_change(%{"series" => "sensor:patch"})

      assert view |> element("#replay-chart-hover") |> render() =~ " m"
    end

    test "a run that built graphs opens on every object at once", %{conn: conn} do
      run = run_believing(%{"mug" => 1.0, "bowl" => 4.0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The picker offers it, and it is where the page opened.
      assert has_element?(view, "#replay-series option[value='objects'][selected]")

      # One line per object, each with its own colour.
      assert has_element?(view, "#replay-line-0")
      assert has_element?(view, "#replay-line-1")

      # Named, because a colour nobody can name is a puzzle.
      legend = view |> element("#replay-chart-legend") |> render()
      assert legend =~ "bowl"
      assert legend =~ "mug"

      # And one number says what the episode came to.
      assert view |> element("#replay-best") |> render() =~ "bowl"
    end

    test "a hover over those lines names the object it is on", %{conn: conn} do
      run = run_believing(%{"mug" => 1.0, "bowl" => 4.0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#replay-chart-hover") |> render() =~ "bowl · step 0 · "
    end

    test "the two strongest theories change as the slider moves", %{conn: conn} do
      run = run_believing([%{"mug" => 1.0, "bowl" => 4.0}, %{"mug" => 9.0, "bowl" => 2.0}])

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      # The page opens where the run ended: mug is the guess by then.
      assert view |> element("#replay-theories") |> render() =~ "mug"
      assert view |> element("#replay-theories") |> render() =~ "9.00"

      view |> element("#replay-seek") |> render_change(%{"step" => "0"})

      theories = view |> element("#replay-theories") |> render()
      assert theories =~ "bowl"
      assert theories =~ "4.00"
    end

    test "a step that weighed nothing says nothing", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#replay-theories")
    end

    test "a run with nothing to compare gets one line and no legend", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#replay-line-0")
      refute has_element?(view, "#replay-line-1")
      refute has_element?(view, "#replay-chart-legend")
      refute has_element?(view, "#replay-best")
    end

    test "a run that kept no graphs says why its evidence line is flat", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert view |> element("#replay-chart-no-graphs") |> render() =~ "No graphs were kept"
    end

    test "a run with graphs does not need the explanation", %{conn: conn} do
      run = run_believing(%{"mug" => 1.0})

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#replay-chart-no-graphs")
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

  describe "deleting many runs" do
    test "one filter and one confirmation forget every run it shows", %{conn: conn, run: run} do
      first = insert_run(%{experiment: "base_a", status: "failed"})
      second = insert_run(%{experiment: "base_b", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs?#{[state: "failed", q: ""]}")

      view |> element("#delete-matching") |> render_click()

      dialog = view |> element("#confirm-bulk-delete") |> render()
      assert dialog =~ "Delete every run shown?"
      assert dialog =~ "2 run(s)"

      view |> element("#confirm-bulk-delete-button") |> render_click()

      assert RunHistory.get(first.id) == nil
      assert RunHistory.get(second.id) == nil
      assert render(view) =~ "Forgot 2 runs."

      # The runs that were not shown are still there, and so is the filter.
      assert RunHistory.get(run.id) != nil
      assert render(view) =~ "No run matches"
    end

    test "keeping them leaves every one of them alone", %{conn: conn} do
      failed = insert_run(%{experiment: "base_a", status: "failed"})

      {:ok, view, _html} = live(conn, ~p"/runs?#{[state: "failed", q: ""]}")

      view |> element("#delete-matching") |> render_click()
      view |> element("#cancel-bulk-delete") |> render_click()

      refute has_element?(view, "#confirm-bulk-delete")
      assert RunHistory.get(failed.id) != nil
    end

    test "picking rows forgets just the rows picked", %{conn: conn, run: run} do
      first = insert_run(%{experiment: "base_a", status: "failed"})
      second = insert_run(%{experiment: "base_b", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      refute has_element?(view, "#delete-selected")

      view |> element("#pick-#{first.id}") |> render_click()
      view |> element("#pick-#{second.id}") |> render_click()

      assert view |> element("#selected-count") |> render() =~ "2 selected"

      view |> element("#delete-selected") |> render_click()

      assert view |> element("#confirm-bulk-delete") |> render() =~ "Delete the selected runs?"

      view |> element("#confirm-bulk-delete-button") |> render_click()

      assert RunHistory.get(first.id) == nil
      assert RunHistory.get(second.id) == nil
      assert RunHistory.get(run.id) != nil

      # Nothing is left picked, so the question cannot be asked twice.
      refute has_element?(view, "#selected-count")
      refute has_element?(view, "#confirm-bulk-delete")
    end

    test "picking all takes the page, and clearing lets it go again", %{conn: conn, run: run} do
      other = insert_run(%{experiment: "base_a", status: "finished"})

      {:ok, view, _html} = live(conn, ~p"/runs")

      view |> element("#pick-all") |> render_click()

      assert view |> element("#selected-count") |> render() =~ "2 selected"

      view |> element("#clear-selection") |> render_click()

      refute has_element?(view, "#selected-count")
      assert RunHistory.get(run.id) != nil
      assert RunHistory.get(other.id) != nil
    end
  end
end
