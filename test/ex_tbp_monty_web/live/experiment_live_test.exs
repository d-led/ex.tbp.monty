defmodule ExTbpMontyWeb.ExperimentLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Monty.Prerequisites
  alias Monty.Studio
  alias Monty.Studio.RunHistory
  alias Monty.Test.Tmp

  setup do
    tmp = Tmp.env_dir("studio-experiment", :experiments_dir)
    Tmp.env_dir("studio-experiment-runs", :studio_artifacts_dir)

    Tmp.app_env(:studio_tick_ms, 1)
    Tmp.app_env(:studio_frame_throttle_ms, 0)
    Tmp.app_env(:studio_poll_ms, 60_000)

    on_exit(fn -> Monty.Test.PrerequisiteDownloads.stop_all() end)

    # A test that only *queues* a run leaves a record saying "running", and the
    # page of the next test then finds it and follows it instead of starting its
    # own — which is the right behaviour and the wrong run. So the file puts
    # back what it found: nothing running.
    on_exit(fn ->
      for run <- RunHistory.running() do
        RunHistory.finish(run, %{"reason" => "the test ended"}, "stopped")
      end
    end)

    {:ok, tmp: tmp}
  end

  describe "which world a run would step" do
    test "the page says so before anything runs", %{conn: conn} do
      # Tests step the stand-in (config/test.exs says so), and a stand-in is not
      # the experiment: the header says which one it is, not a footnote.
      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert view |> element("#world") |> render() =~ "stand-in scene"
      assert has_element?(view, "#world[title]")
    end

    test "the page lets the run choose it, rather than the deployment", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert has_element?(view, "#world-select")

      # Choosing the object's world changes what the page says, and what it
      # will queue: the stand-in warning is gone because the run is no longer
      # one.
      view |> element("#world-choice") |> render_change(%{"world" => "mujoco"})

      # The badge names the engine for the experiment's world — MuJoCo for this
      # experiment — and "stand-in scene" for this port's: the two answers a
      # reader has to tell apart.
      assert view |> element("#world") |> render() =~ "MuJoCo"
      refute render(view) =~ "world_is_a_stand_in"

      # Both options are named for what they are, so the world is never a
      # mystery: MuJoCo is in this application, and it says so.
      select = view |> element("#world-select") |> render()
      assert select =~ "stand-in scene (Elixir, one sphere)"
      assert select =~ "MuJoCo (in this application)"
      assert select =~ ~s(selected)
    end

    # Poka-yoke: MuJoCo reads a downloaded object set and memory. Queuing a run
    # without them answers with a run that dies at its first step, so the page
    # says so first — and says where to get them. No interpreter is on that
    # list: the world runs in the one this application carries.
    test "a run whose files are not here yet cannot be started, and says why", %{conn: conn} do
      Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
      Tmp.system_env("MONTY_MODELS", Tmp.dir("monty-models"))
      # A checkout that has exported a library for this model would otherwise
      # satisfy the need the test is about.
      Tmp.env_dir("libraries", :monty_libraries_dir)

      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      # The stand-in reads nothing, so nothing stands in its way.
      refute has_element?(view, "#need-data")
      assert has_element?(view, "#run:not([disabled])")

      view |> element("#world-choice") |> render_change(%{"world" => "mujoco"})

      assert has_element?(view, "#need-data")
      assert has_element?(view, "#need-models")
      assert has_element?(view, "#run[disabled]")

      box = view |> element("#setup-findings") |> render()
      assert box =~ "objects this environment loads"
      assert box =~ "the memory `surf_agent_1lm_10distinctobj`"
      refute box =~ "MONTY_PYTHON"

      # One line per need, and a link that starts that need's own download: a
      # person who has to find the row themselves is the round trip the finding
      # exists to remove.
      assert view
             |> element("#need-data-action")
             |> render() =~ ~s(href="/prerequisites?fetch=ycb_objects_1_0")

      # The memory this config reads is in the v14 archive, so its click starts
      # that download — the archive is the file the model arrives in.
      assert view
             |> element("#need-models-action")
             |> render() =~ ~s(href="/prerequisites?fetch=pretrained_ycb_v14")

      # The ways out are both named: the download, and the scene that reads
      # nothing.
      assert render(view) =~ "stand-in scene"

      # Clicking anyway queues nothing.
      assert view |> element("#run[disabled]") |> render() =~ "disabled"

      assert RunHistory.search(state: "all", text: "base_config_10distinctobj_dist_agent").runs ==
               []
    end

    test "the run is recorded with the world it was given", %{conn: conn} do
      download_prerequisites("base_config_10distinctobj_dist_agent")

      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      view |> element("#world-choice") |> render_change(%{"world" => "mujoco"})
      view |> element("#run") |> render_click()

      assert [%{inputs: %{"world" => "mujoco"}} = run | _] =
               RunHistory.search(state: "all", text: "base_config_10distinctobj_dist_agent").runs

      # The queue steps what the record says, not what the worker's environment
      # happens to be — the two can differ, and did.
      assert run.experiment == "base_config_10distinctobj_dist_agent"
    end
  end

  # Arriving at an experiment where something is already going should be one
  # click from watching it, not a second run started to have something to look
  # at. The table is deliberately four columns: the parameters this page sets,
  # and a way through to the run that knows the rest.
  describe "the runs this experiment already has" do
    setup do
      Tmp.system_env("MONTY_PYTHON", interpreter())

      {:ok, queued} =
        RunHistory.start(%{
          experiment: "base_config_10distinctobj_dist_agent",
          source: "monty",
          steps: 3,
          seed: 42,
          config: %{},
          inputs: %{"seed" => 42, "world" => "synthetic", "parallel" => 2}
        })

      {:ok, _job} = Monty.Studio.Jobs.Run.enqueue_run(queued)

      {:ok, finished} =
        RunHistory.start(%{
          experiment: "base_config_10distinctobj_dist_agent",
          source: "monty",
          steps: 2,
          config: %{},
          inputs: %{"seed" => 7, "world" => "synthetic"}
        })

      {:ok, finished} = RunHistory.finish(finished, %{"steps" => 2})

      {:ok, elsewhere} =
        RunHistory.start(%{
          experiment: "base_77obj_dist_agent",
          source: "monty",
          steps: 1,
          config: %{}
        })

      {:ok, finished_elsewhere} = RunHistory.finish(elsewhere, %{})

      {:ok, queued: queued, finished: finished, elsewhere: finished_elsewhere}
    end

    test "lists them with what this page can set, and links to each", %{
      conn: conn,
      queued: queued,
      finished: finished
    } do
      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert has_element?(view, "#experiment-runs")

      row = view |> element("#experiment-run-#{queued.id}") |> render()
      assert row =~ "queued"
      assert row =~ "42"
      assert row =~ "stand-in"
      # How many runs went side by side, off the record rather than the page's
      # current setting.
      assert row =~ "2"
      assert row =~ ~s(id="experiment-run-#{queued.id}")
      assert row =~ ~p"/runs/#{queued.id}"

      done = view |> element("#experiment-run-#{finished.id}") |> render()
      assert done =~ "finished"
      assert done =~ "7"
      # A finished run has a time to show, and the header says what it is.
      assert render(view) =~ "took"
      assert done =~ ~r/\d+(µs|ms|s)/
    end

    test "leaves another experiment's runs out", %{conn: conn, elsewhere: elsewhere} do
      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      refute has_element?(view, "#experiment-run-#{elsewhere.id}")
    end

    test "a run that is still going says how long it has been going", %{
      conn: conn,
      queued: queued
    } do
      # `duration_us` is written when a run closes, so the column holds the
      # schema's nought while the run steps — and the table printed it as "0µs"
      # for a run hours into its work.
      {1, _} =
        ExTbpMonty.Repo.update_all(
          from(r in Monty.Studio.RunHistory.Run, where: r.id == ^queued.id),
          set: [started_at: DateTime.add(DateTime.utc_now(), -90, :second)]
        )

      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      row = view |> element("#experiment-run-#{queued.id}") |> render()

      assert row =~ "1min 30s"
      refute row =~ "0µs"
    end

    test "says so when there is nothing yet", %{conn: conn} do
      # An experiment that exists and simply has no runs. The page reads the run
      # history, so "nothing yet" has to mean it: this file starts real runs in
      # other tests, and their records are not this test's subject.
      ExTbpMonty.Repo.delete_all(RunHistory.Run)

      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment")

      assert view |> element("#runs-empty") |> render() =~ "No run of this experiment yet"
      refute has_element?(view, "#experiment-runs table")
    end
  end

  describe "the experiment as a file" do
    test "the page offers it, and the download is the YAML Monty ships", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert has_element?(view, "#export-experiment")

      response =
        conn
        |> get("/export/experiments/base_config_10distinctobj_dist_agent")

      assert response.status == 200
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "yaml"
      assert [disposition] = get_resp_header(response, "content-disposition")
      assert disposition =~ "base_config_10distinctobj_dist_agent.yaml"
      assert response.resp_body =~ "defaults:"
    end

    test "an experiment that does not exist is a 404, not a file", %{conn: conn} do
      response = get(conn, "/export/experiments/no_such_experiment")

      assert response.status == 404
      assert response.resp_body =~ "neither a draft nor an experiment"
    end
  end

  describe "before the run" do
    test "the experiment is shown as a diagram of what it wires together", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert html =~ "base_config_10distinctobj_dist_agent"
      assert has_element?(view, "#setup-diagram")
      assert has_element?(view, "#setup-diagram polyline[points]")
      assert has_element?(view, "#setup-findings")
      assert has_element?(view, "#run")
    end

    test "the modules it names are listed with what they are", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert has_element?(view, "#setup-diagram")
      assert render(view) =~ "EvidenceGraphLM"
      assert render(view) =~ "EvidenceGoalGenerator"
    end

    test "says what the run will log with before it runs", %{conn: conn} do
      # This experiment's logging group names the CSV handler and wandb. The
      # wrapper is this port's, but nothing it would wrap is; that is said here,
      # beside the findings, rather than only in the log of a run that has already
      # happened. A note about wandb is only said to a run that reports to it,
      # and wandb is off by default.
      Tmp.app_env(:wandb_mode, "online")

      {:ok, view, _html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert has_element?(view, "#logging-notes")
      assert render(view) =~ "WandbWrapper wraps no handler this port has"
    end

    test "says nothing about logging for a config that asks for none", %{conn: conn} do
      # The tutorial's group names a logger with no handlers: nothing to skip, and
      # no note pretending otherwise.
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment")

      refute has_element?(view, "#logging-notes")
    end

    test "an experiment that would not start says so, and refuses to run", %{conn: conn, tmp: tmp} do
      File.write!(Path.join(tmp, "broken.yaml"), broken_config())

      {:ok, view, _html} = live(conn, ~p"/experiments/broken")

      assert has_element?(view, "#run-blocked")
      assert has_element?(view, "[id^=finding-learning_module_count_mismatch]")
      assert view |> element("#run") |> render() =~ "disabled"
    end

    test "a name Monty does not have is a page, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/nope")

      assert has_element?(view, "#experiment-missing")
    end
  end

  # Stepping is how a person learns what a run does: one press, one step, and the
  # page has a record to look at. It is a *run* of one step rather than a mode of
  # the run, so that what a step saw is written down like any other step — and so
  # that pressing twice is two runs to compare instead of one run that pretends to
  # have done two.
  describe "stepping a tutorial experiment one step at a time" do
    # The tutorial that trains from nothing, so it runs here without an archive on
    # the machine — and it is the tutorial a person reads first.
    @tutorial "tutorial/surf_agent_2obj_unsupervised"

    # The database outlives a test, so the runs of this experiment are forgotten
    # first: "one press, one run" is a claim about the run this test started.
    setup do
      _ = ExTbpMonty.Repo.delete_all(from r in RunHistory.Run, where: r.experiment == @tutorial)
      :ok
    end

    test "a press of Step records a run of one step, of one episode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/#{@tutorial}")

      assert has_element?(view, "#step:not([disabled])")
      view |> element("#step") |> render_click()

      assert [run] = RunHistory.list_for(@tutorial)
      assert run.steps == 1
      assert run.inputs["episodes"] == 1
    end

    test "and the step it records is one step of that experiment, not a redraw", %{conn: conn} do
      # The whole point of the button: the config runs, for one step, and what
      # that step saw is in the record.
      {:ok, view, _html} = live(conn, ~p"/experiments/#{@tutorial}")

      view |> element("#step") |> render_click()
      perform_run(view)

      [run] = RunHistory.list_for(@tutorial)
      run = RunHistory.get(run.id)

      assert run.status == "finished"
      assert run.steps_done == 1
      assert Enum.map(run.timeline, & &1["step"]) == [0]
      assert [%{step: 0}] = logged_steps(view)
    end

    test "a second press is a second run, not one run of two steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/#{@tutorial}")

      view |> element("#step") |> render_click()
      perform_run(view)

      # The page has to offer the button again once the run it started is over, or
      # a person stepping a run would step it once and be stuck.
      assert has_element?(view, "#step:not([disabled])")
      view |> element("#step") |> render_click()

      assert [second, first] = RunHistory.list_for(@tutorial)
      assert first.steps == 1
      assert second.steps == 1
      refute first.id == second.id
    end
  end

  describe "during the run" do
    # A press of Run starts a world stepping, and a second press while it steps is
    # the same world stepped twice — the queue would take it, because its refusal
    # is per episode and world. The page says so instead: neither button that
    # starts something is offered while one is going, and Stop is.
    test "the buttons that start something are disabled while a run is going", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      assert has_element?(view, "#run:not([disabled])")
      refute has_element?(view, "#stop")

      view |> element("#run") |> render_click()

      assert has_element?(view, "#run[disabled]")
      assert has_element?(view, "#step[disabled]")
      assert has_element?(view, "#stop")
    end

    # One press of Run with a parallelism of three is three runs, and stopping
    # them one at a time from another page is not what "stop" means.
    test "Stop ends every run of the experiment, not only the one on screen", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#parallelism") |> render_change(%{"parallelism" => "3"})
      view |> element("#run") |> render_click()

      assert view |> element("#stop") |> render() =~ "Stop 3 runs"

      view |> element("#stop") |> render_click()

      assert render(view) =~ "stopped: it had not started yet"

      statuses =
        RunHistory.list_for("base_config_10distinctobj_dist_agent")
        |> Enum.map(&RunHistory.get(&1.id).status)

      assert statuses == ["failed", "failed", "failed"]
    end

    test "each step is streamed into the log as it happens", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=3&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      assert [%{step: 0}, %{step: 1}, %{step: 2}] = logged_steps(view)
      assert [first_id | _rest] = logged_ids(view)
      assert view |> element("#log-#{first_id}") |> render() =~ "queued: 3 step(s)"
    end

    test "a second viewer watches the run that is going instead of starting another", %{
      conn: conn
    } do
      {:ok, one, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      {:ok, two, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      one |> element("#run") |> render_click()
      started = current_run_id(one)

      # A run belongs to the experiment, not to the page that started it, and
      # there is no second run on offer while it goes: the button that would
      # start one is disabled, and the page that did not start this one watches
      # it without being asked.
      refute has_element?(two, "#run:not([disabled])")

      assert current_run_id(two) == started
      assert RunHistory.list_for("base_config_10distinctobj_dist_agent") |> length() == 1
      assert render(two) =~ "watching it"
    end

    test "in parallel starts one run per episode, one object each", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#parallelism") |> render_change(%{"parallelism" => "3"})
      view |> element("#run") |> render_click()

      # Three runs, three episodes, and the page watches the first of them. The
      # episodes are why this is not just "three of the same": each carries its
      # own seed, and a config that names ten objects has ten of them.
      runs = RunHistory.list_for("base_config_10distinctobj_dist_agent")

      assert runs |> Enum.map(& &1.episode) |> Enum.sort() == [0, 1, 2]
      assert current_run_id(view) in Enum.map(runs, & &1.id)

      # Each is a job of its own, so the queue steps them side by side.
      assert map_size(Monty.Studio.Jobs.by_run(Enum.map(runs, & &1.id))) == 3
    end

    test "each sensor has its own view, updated as the run steps", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # One panel per sensor, side by side, and the picture follows the percept.
      assert has_element?(view, "#frame-patch")
      assert has_element?(view, "#frame-view_finder")

      # Two pictures per sensor — what the camera saw and the depth image — the
      # way the PyView dashboard this studio follows shows them.
      patch = view |> element("#frame-patch") |> render()

      assert length(String.split(patch, "data:image/png;base64,")) - 1 == 2
      assert patch =~ "step 1"
    end

    test "where the agent is relative to the object is drawn as the run steps", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # A patch view says what one camera saw; it cannot say whether the agent is
      # anywhere near the object, which is the first thing to check when a run
      # reports nothing.
      assert has_element?(view, "#centre-view svg circle")
      assert view |> element("#centre-view") |> render() =~ "m from the surface"
    end

    test "what the learning module believes is drawn while the run steps", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # A chart per learning module, with a line per object it was weighing and
      # the answer marked on it — the module's numbers, not a summary of the log.
      assert has_element?(view, "#evidence-chart")
      assert has_element?(view, "#chart-learning_module_0 svg")
      assert has_element?(view, "#chart-learning_module_0 polyline")

      chart = view |> element("#chart-learning_module_0") |> render()
      assert chart =~ "is the answer so far"
    end

    test "the whole run comes back under the all control", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # "all" is only offered once the address names a window, which is how a
      # reader gets here: they zoomed in first.
      view |> element("#zoom-in") |> render_click()
      view |> element("#zoom-all") |> render_click()

      # "All" is not a window: the address stops naming one, and the chart is
      # drawn for the whole run again.
      assert_patch(view, ~p"/experiments/base_config_10distinctobj_dist_agent")
      assert has_element?(view, "#chart-learning_module_0 svg")
    end

    test "full screen is one chart's, and Escape leaves it", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Four learning modules are four opinions: expanding the page's whole grid
      # gave a reader four small charts in a big box, when the one they clicked
      # is the one they wanted to read.
      view |> element("#chart-expand-learning_module_0") |> render_click()

      assert view |> element("#chart-card-learning_module_0") |> render() =~
               "rounded-field fixed inset-0"

      # Escape is what a full-screen anything answers to, and the control is the
      # way back for anyone without a keyboard.
      view |> element("#charts") |> render_keydown(%{"key" => "Escape"})

      refute view |> element("#chart-card-learning_module_0") |> render() =~
               "rounded-field fixed inset-0"

      assert has_element?(view, "#chart-expand-learning_module_0")
    end

    test "the chart filling the screen is drawn for the screen's own shape", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # A screen is a shape no server can guess. The page therefore asks the
      # browser how big the box is and draws the chart for it: a chart stretched
      # into a box instead squashes its own labels, which is what "full screen"
      # looked like — a 960x300 ribbon in a window-sized frame.
      view |> element("#chart-expand-learning_module_0") |> render_click()

      view
      |> element("#chart-svg-learning_module_0")
      |> render_hook("chart-size", %{
        "module" => "learning_module_0",
        "width" => 900,
        "height" => 700
      })

      assert view |> element("#chart-svg-learning_module_0") |> render() =~
               ~s(viewBox="0 0 900 700")

      # Leaving full screen returns it to the grid's own size, so the chart is
      # not left drawn for a box that is no longer there.
      view |> element("#chart-expand-learning_module_0") |> render_click()

      assert view |> element("#chart-svg-learning_module_0") |> render() =~
               ~s(viewBox="0 0 960 300")
    end

    test "a second Run it draws the second run's chart, not more of the first", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      first = chart_points(view)

      view |> element("#run") |> render_click()
      perform_run(view)

      # The chart is one run's. Two runs' steps share episode numbers and steps,
      # so a chart that kept the first one's beliefs would draw the second run's
      # points into the first one's line — a history nobody ran.
      assert chart_points(view) == first
    end

    test "counts the steps of the episode it is running, not of the whole run", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=2")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Two episodes of two steps: a page counting the run's whole log would end
      # at "step 4 / 2", which is not a thing that can happen. The badge names
      # the episode as well, because this counter restarts inside each one — the
      # "dive to zero" a reader sees is that restart, not a run going backwards.
      assert view |> element("#run-progress") |> render() =~ "episode 2 · step 2 / 2"
    end

    test "lays a run's episodes end to end, because each one starts again at zero", %{
      conn: conn
    } do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=2")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Drawn against the step alone, the second episode would sit on top of the
      # first: both start at step 0 with zero evidence. The chart is against the
      # run, so the second episode begins where the first ended — and says so.
      chart = view |> element("#chart-learning_module_0") |> render()

      assert chart =~ "ep 1"
      assert chart =~ "ep 2"
    end

    test "starts each episode's count at its own first step, however long the last one was",
         %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=3&episodes=2")

      view |> element("#run") |> render_click()
      perform_run(view)
      run_id = current_run_id(view)

      # The stream of a second episode, as the run's step process sends it: the
      # episode first, then a step numbered below the one the last episode
      # ended on. Ignoring the step would leave the badge standing at the old
      # episode's last number for the rest of the run — the counter a reader
      # reports as stuck.
      send(view.pid, {:studio, run_id, {:episode, %{episode: 1, object: "mug"}}})
      send(view.pid, {:studio, run_id, {:step, step_event(episode: 1, step: 0)}})

      assert view |> element("#run-progress") |> render() =~ "episode 2 · step 1 / 3"
    end

    # A page that falls behind does not have to draw every step it missed to be
    # right about the last one — but nothing it was told may be lost from the
    # transcript. The steps here arrive in one burst, as a backlog does.
    test "a backlog of steps is one drawing and every line", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=5&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)
      run_id = current_run_id(view)

      # A fresh episode, so the steps below are the newest the page has seen: the
      # run it watched has already taken its five.
      send(view.pid, {:studio, run_id, {:episode, %{episode: 1, object: "mug"}}})

      for step <- 0..2 do
        send(view.pid, {:studio, run_id, {:step, step_event(episode: 1, step: step)}})
      end

      assert view |> element("#run-progress") |> render() =~ "episode 2 · step 3 / 5"

      texts = view |> rendered_lines() |> Enum.map(& &1.text)

      for step <- 0..2 do
        assert Enum.any?(texts, &(&1 =~ "step #{step} ·"))
      end
    end

    test "a backlog keeps every step, so the line it draws has no gaps", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=5&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)
      run_id = current_run_id(view)

      send(view.pid, {:studio, run_id, {:episode, %{episode: 1, object: "mug"}}})

      # Three steps in one batch, which is what a page that has fallen behind
      # receives. The history has to keep all three: drawing the batch from its
      # last step alone leaves the other two out, and a line missing every other
      # point is drawn as separate dashes — what a reader sees as the run
      # stalling when it is only the page catching up.
      for step <- 0..2 do
        send(
          view.pid,
          {:studio, run_id,
           {:step,
            step_event(episode: 1, step: step, beliefs: %{"learning_module_0" => belief(step)})}}
        )
      end

      assert view |> element("#run-progress") |> render() =~ "episode 2 · step 3 / 5"

      # One contiguous run of three points for the three batched steps — and no
      # one-point dashes anywhere, because a dash is a step the chart was told
      # about while its neighbour was not.
      segments = view |> chart_segments()
      assert 3 in segments
      refute Enum.any?(segments, &(&1 == 1))
    end

    test "steps of two episodes are drawn as two runs, never as one", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=5&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)
      run_id = current_run_id(view)

      # A backlog can hold the end of one episode and the start of the next. The
      # evidence of an episode's last step and of the next episode's first are
      # not neighbours on any line — joined up, they read as the object's beliefs
      # falling off a cliff at every boundary.
      for {index, object} <- [{1, "mug"}, {2, "e_cups"}] do
        send(view.pid, {:studio, run_id, {:episode, %{episode: index, object: object}}})

        for step <- 0..2 do
          send(
            view.pid,
            {:studio, run_id,
             {:step,
              step_event(
                episode: index,
                step: step,
                beliefs: %{"learning_module_0" => belief(step)}
              )}}
          )
        end
      end

      assert view |> element("#run-progress") |> render() =~ "episode 3 · step 3 / 5"

      # Two runs of three, one per episode: a single run of six would be the two
      # episodes joined across a boundary nobody measured.
      segments = view |> chart_segments()
      assert Enum.count(segments, &(&1 == 3)) >= 2
      refute 6 in segments
    end

    test "zooming draws a stretch of the run, and the whole run is one click away", %{
      conn: conn
    } do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=2")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Unzoomed, the label names the run and there is nothing to go back to.
      assert view |> element("#chart-extent") |> render() =~ "steps 0–2"
      assert has_element?(view, "#zoom-all[disabled]")

      view |> element("#zoom-in") |> render_click()

      assert view |> element("#chart-extent") |> render() =~ "of 2"
      assert has_element?(view, "#zoom-all:not([disabled])")

      # The patch is the window and nothing else: a chart link used to carry the
      # run's budget too, so zooming a picture rewrote how many episodes the
      # experiment would run — a number nobody had asked to change.
      assert_patch(
        view,
        ~p"/experiments/base_config_10distinctobj_dist_agent?#{[x_from: 1, x_to: 2]}"
      )

      view |> element("#zoom-all") |> render_click()

      assert view |> element("#chart-extent") |> render() =~ "steps 0–2"
      refute has_element?(view, "#zoom-all:not([disabled])")
    end

    test "a wheel zooms into the stretch the pointer is over, not into the middle", %{
      conn: conn
    } do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=4&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # The chart's own listener says which steps the reader pointed at, because
      # the middle of a long run is where nothing interesting happened.
      assert view |> element("#chart-hint") |> render() =~ "wheel to zoom"

      view
      |> element("#chart-svg-learning_module_0")
      |> render_hook("zoom", %{"from" => "1", "to" => "3"})

      assert_patch(
        view,
        ~p"/experiments/base_config_10distinctobj_dist_agent?#{[x_from: 1, x_to: 3]}"
      )

      # Below a step there is nothing to read, so it is not a window.
      view
      |> element("#chart-svg-learning_module_0")
      |> render_hook("zoom", %{"from" => "2", "to" => "2"})

      assert view |> element("#chart-extent") |> render() =~ "steps 1–3"
    end

    test "a chart that follows the run slides back to the newest step, and stops when told",
         %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=2")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Following is what a page opened on a run does by default: a window that
      # has been zoomed into keeps its width and ends at the newest step, so
      # moving back by a quarter is undone rather than leaving the run behind.
      assert has_element?(view, "#follow-latest:checked")

      view |> element("#zoom-in") |> render_click()
      view |> element("#zoom-left") |> render_click()

      assert view |> element("#chart-extent") |> render() =~ "steps 1–2 of 2"

      # A reader reading an earlier stretch says so, and the window then stays
      # exactly where they put it.
      view |> element("#follow-latest") |> render_click()

      refute has_element?(view, "#follow-latest:checked")

      view |> element("#zoom-left") |> render_click()

      assert view |> element("#chart-extent") |> render() =~ "steps 0–1 of 2"
    end

    test "a run's budget is a control on the page, not something a link decides", %{
      conn: conn
    } do
      # A slice of the experiment used to arrive in the address bar and change
      # what a run was with nothing on the page saying so: a run of one episode
      # of three steps, of a config that says two, read as the experiment giving
      # up. The numbers are now where a reader can see and change them.
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=3&episodes=1")

      assert view |> element("#run-episodes") |> render() =~ ~s(value="1")
      assert view |> element("#run-steps") |> render() =~ ~s(value="3")
      assert view |> element("#run-episodes-note") |> render() =~ "in the config"

      # The way back to the whole experiment is emptying the field, not editing
      # an address bar: no slices means the config's own episodes and ceiling.
      view |> element("#run-budget") |> render_change(%{"episodes" => "", "steps" => ""})

      refute view |> element("#run-episodes") |> render() =~ ~s(value="1")
      refute view |> element("#run-steps") |> render() =~ ~s(value="3")
    end

    test "the log filter keeps a line only if every word matches", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Every word must be in the line, and the lines that were already there
      # are filtered too — not only the ones that arrive after typing.
      assert length(visible_lines(view)) > 1
      view |> element("#log-filter") |> render_change(%{"filter" => "queued"})
      assert [queued] = visible_lines(view)
      assert queued =~ "queued: 2 step(s)"

      # Two words, one of which no line has: nothing matches, rather than
      # everything that matches either word.
      view |> element("#log-filter") |> render_change(%{"filter" => "queued percepts"})
      assert visible_lines(view) == []
    end

    test "a filter that matches nothing says so instead of going blank", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)
      view |> element("#log-filter") |> render_change(%{"filter" => "nothingmatchesthis"})

      assert has_element?(view, "#run-log-empty")
      assert view |> element("#run-log-empty") |> render() =~ "no line matches"
    end

    test "a log with no filter says nothing about matching", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Every line matches an empty filter, so there is no empty state to show.
      refute has_element?(view, "#run-log-empty")
      assert visible_lines(view) |> length() > 1
    end

    test "opening the page again finds the run that is still going", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      # A run that is queued but not performed: the page that was closed while
      # it waited, and a page opened while it waits, show the same run.
      view |> element("#run") |> render_click()
      run_id = current_run_id(view)

      {:ok, reopened, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      assert current_run_id(reopened) == run_id
      assert has_element?(reopened, "#open-history")
    end

    test "a page opened on a run that has already stepped draws its replay", %{conn: conn} do
      record = running_run()

      # The record is read without its pictures (`RunHistory.head/1`) — a timeline
      # entry is 11 kB a step and this page draws one of them — so the frame on
      # screen was asked for by name, for the last step the run reached.
      {:ok, _stepped} =
        RunHistory.record_step(record, entry(0), %{
          "step" => 0,
          "sensors" => %{"patch" => %{"location" => [0.0, 0.0, 0.1], "depth" => [[1.0, 2.0]]}}
        })

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      assert current_run_id(view) == record.id

      poll(view)

      assert has_element?(view, "#frames figure")
    end

    test "opening a long run draws the window of its log, not the whole transcript", %{
      conn: conn
    } do
      record = running_run()

      # A run of this experiment leaves thirteen thousand steps behind, and the
      # page keeps the last three hundred of them — whether they arrived one at a
      # time or were already in the record when the page opened. The window is a
      # screenful and a bit: every line the page holds is a line the browser
      # keeps, and two thousand of them made the page heavy enough that its
      # socket stalled while the run carried on.
      {:ok, _stored} = RunHistory.store(record, for(step <- 1..2_050, do: entry(step)), [])

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      assert current_run_id(view) == record.id
      assert view |> element("#log-count") |> render() =~ "300 of 300 lines"

      # The window is the *tail*: the steps at the end of the run are the ones a
      # page opened on it is for.
      assert view |> visible_lines() |> hd() =~ "step 1751 "
    end
  end

  describe "after the run" do
    test "the summary reports what happened, including silence", %{conn: conn} do
      # One run, so the history is cleared first: what this test is about is what
      # the run left, not what an earlier test left lying around.
      ExTbpMonty.Repo.delete_all(RunHistory.Run)

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      perform_run(view)

      assert render(view) =~ "After the run"
      assert has_element?(view, "#run-summary")

      # The run is history now: its record, its steps, its summary, what each
      # step saw, and the log file it wrote are all off the page.
      assert [row] = RunHistory.list()
      assert row.status == "finished"
      assert row.experiment == "base_config_10distinctobj_dist_agent"
      # The list's row is the table's — no transcript. What the run said step by
      # step is read by the page that opens it, which is `head/1`.
      run = RunHistory.head(row.id)
      assert length(run.log) == 2
      # What each step saw is read a step at a time: a row of the list carries
      # no pictures, which is what makes a page of them cheap.
      assert %{"location" => _} = RunHistory.sensors_at(run.id, 0)["patch"]
      assert %{"location" => _} = RunHistory.sensors_at(run.id, 1)["patch"]
      assert run.summary["steps"] == 2
      assert is_map(run.config)
      assert File.exists?(run.log_path)
      assert has_element?(view, "#open-history")
    end

    test "a run no process holds is settled instead of watched" do
      {:ok, record} =
        RunHistory.start(%{
          experiment: "base_config_10distinctobj_dist_agent",
          source: "monty",
          steps: 2,
          config: %{},
          inputs: %{}
        })

      conn = Phoenix.ConnTest.build_conn()

      quiet_since(record, 61)

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      # The row said `running`, but no job will ever run it and no process holds
      # it. Waiting for news that cannot come is the worst state a page can be
      # in — and it would also refuse the run the reader came here to start.
      refute has_element?(view, "#open-history")
      assert has_element?(view, "#run")

      settled = RunHistory.get(record.id)
      assert settled.status == "failed"
      assert settled.summary["reason"] =~ "stopped before it finished"
    end

    test "a run waiting its turn is stopped where it waits" do
      {:ok, record} =
        RunHistory.start(%{
          experiment: "base_config_10distinctobj_dist_agent",
          source: "monty",
          steps: 2,
          config: %{},
          inputs: %{}
        })

      # Queued, so the reaper leaves it alone — and no process holds it, which is
      # exactly what stopping a waiting run has to handle: nothing to ask, so the
      # job is cancelled where it waits. Closing only the record would have left
      # a queued job that starts afterwards, stepping a run that says it stopped.
      {:ok, _job} = Monty.Studio.Jobs.Run.enqueue_run(record)

      conn = Phoenix.ConnTest.build_conn()

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      assert current_run_id(view) == record.id
      view |> element("#stop") |> render_click()

      assert render(view) =~ "stopped: it had not started yet"

      stopped = RunHistory.get(record.id)
      assert stopped.status == "failed"
      assert stopped.summary["reason"] == "it was stopped before it finished"
    end
  end

  describe "a page that was open before a run started" do
    test "picks the run up from the record instead of waiting for a click", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      refute has_element?(view, "#open-history")

      record = running_run()

      # The page asks: "is there a run of this experiment now?" A run belongs to
      # the experiment, not to the page that started it.
      poll(view)

      assert current_run_id(view) == record.id
    end

    test "keeps the run it is already watching", %{conn: conn} do
      record = running_run()

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      assert current_run_id(view) == record.id

      poll(view)

      assert current_run_id(view) == record.id
    end

    test "moves to a newer run once the one it watched has ended", %{conn: conn} do
      watched = running_run()

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      assert current_run_id(view) == watched.id

      {:ok, _closed} = RunHistory.finish(watched, %{"reason" => "as the test asked"}, "failed")
      newer = running_run()

      # The first poll hears the record it already follows has ended; the second
      # one finds the run that is going now.
      poll(view)
      poll(view)

      assert current_run_id(view) == newer.id
    end
  end

  describe "a run reported from elsewhere" do
    test "the page catches up from the record", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2&episodes=1")

      view |> element("#run") |> render_click()
      record = RunHistory.get(current_run_id(view))

      # This is another node's worker: the record moves, this page hears
      # nothing. The row is written before a line is broadcast, so the row is
      # where the page gets the truth from when a message goes missing.
      {:ok, record} = RunHistory.record_step(record, entry(0), moment(0))
      {:ok, _record} = RunHistory.finish(record, %{"steps" => 1, "votes_used" => 1})

      send(view.pid, :studio_poll)
      _ = :sys.get_state(view.pid)

      assert visible_lines(view) |> Enum.any?(&(&1 =~ "step 0"))
      assert has_element?(view, "#run-summary")
    end
  end

  # A record nobody has written to for a while: the half of "nothing is working
  # on it" that a run stepped elsewhere can still disprove, by being written.
  defp quiet_since(record, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    ExTbpMonty.Repo.update_all(
      from(r in Monty.Studio.RunHistory.Run, where: r.id == ^record.id),
      set: [updated_at: at]
    )

    record
  end

  defp entry(step) do
    %{
      "step" => step,
      "percepts" => ["patch"],
      "inputs" => %{"learning_module_0" => 1},
      "votes" => %{"sent" => 1, "used" => 1},
      "goals" => 1,
      "actions" => 1,
      "duration_us" => 100
    }
  end

  defp moment(step) do
    %{
      "step" => step,
      "sensors" => %{"patch" => %{"location" => [step * 0.01, 0.0, 0.1], "value" => 0.0}}
    }
  end

  # The queue is manual in tests, so the page test performs the run itself
  # rather than racing a queue: what is under test is the run and the page, not
  # Oban's scheduler.
  # A run that is going, as another page — or `mix monty.run` — would leave it: a
  # record, and a job in the queue behind it.
  defp running_run do
    {:ok, record} =
      RunHistory.start(%{
        experiment: "base_config_10distinctobj_dist_agent",
        source: "monty",
        steps: 2,
        config: %{}
      })

    {:ok, _job} = Monty.Studio.Jobs.Run.enqueue_run(record)
    record
  end

  defp poll(view) do
    send(view.pid, :studio_poll)
    _ = :sys.get_state(view.pid)
  end

  # How many points the module's chart draws, all lines together: two steps of a
  # run are two points, and two runs of two steps drawn as one line are four.
  defp chart_points(view) do
    chart = view |> element("#chart-learning_module_0") |> render()

    chart
    |> String.split(~r/points="/, trim: true)
    |> Enum.map(fn part ->
      part |> String.split("\"") |> hd() |> String.split(~r/\s+/, trim: true)
    end)
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp perform_run(view) do
    job = %Oban.Job{args: %{"run_id" => current_run_id(view)}, attempt: 1}
    assert {:ok, _record} = Monty.Studio.Jobs.Run.perform(job)

    # The page learns about the run by message; let it drain them.
    _ = :sys.get_state(view.pid)
    :ok
  end

  # One step, as `Monty.Studio.RunStream` announces it to a page.
  defp step_event(options) do
    episode = Keyword.fetch!(options, :episode)
    step = Keyword.fetch!(options, :step)

    %{
      line: "step #{step} · percepts patch_0 · votes 1/1",
      step: step,
      episode: episode,
      frames: [],
      beliefs: Keyword.get(options, :beliefs, %{}),
      centre: nil
    }
  end

  # One module's belief, as the chart reads it: `step` of an episode, with the
  # object's strongest hypothesis that strong.
  defp belief(step) do
    %{
      possible_matches: ["mug"],
      mlh: nil,
      graphs: %{
        "mug" => %{
          hypotheses: 3,
          max_evidence: 1.0 + step,
          within_x_percent: 1,
          top_evidence: [1.0 + step]
        }
      },
      x_percent_threshold: 0.5,
      terminal_state: nil,
      detected_object: nil
    }
  end

  # How many segments the module's chart draws, and how long each is. A line
  # with a gap in it is more than one segment: `Chart` breaks a series where the
  # steps are not contiguous rather than drawing a line nobody measured.
  defp chart_segments(view, module_id \\ "learning_module_0") do
    html = view |> element("#chart-lines-#{module_id}") |> render()

    ~r/points="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, points] -> points |> String.split() |> length() end)
  end

  defp current_run_id(view) do
    path = view |> element("#open-history") |> render() |> extract_href()
    String.replace_prefix(path, "/runs/", "")
  end

  defp extract_href(html) do
    [_, href] = Regex.run(~r/href="([^"]+)"/, html)
    href
  end

  defp logged_ids(view) do
    view |> rendered_lines() |> Enum.map(& &1.id)
  end

  defp logged_steps(view) do
    ~r/step (\d+) ·/
    |> Regex.scan(Enum.join(visible_lines(view), "\n"))
    |> Enum.map(fn [_, step] -> %{step: String.to_integer(step)} end)
  end

  defp visible_lines(view) do
    view |> rendered_lines() |> Enum.map(& &1.text)
  end

  # What the log actually renders, line by line: an id and its text. Reading the
  # page's own output is the point — a filtered log is a fact about the HTML.
  # Found through the DOM rather than a pattern over the markup: a line carries a
  # `<time>` holding the reader's clock, so its text is not one run of
  # characters.
  defp rendered_lines(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#run-log li[id^=log-]")
    |> LazyHTML.to_tree()
    |> Enum.map(fn {_tag, attributes, children} ->
      {"id", id} = List.keyfind(attributes, "id", 0)
      %{id: String.replace_prefix(id, "log-", ""), text: text_of(children)}
    end)
  end

  defp text_of(text) when is_binary(text), do: text
  defp text_of({_tag, _attributes, children}), do: text_of(children)
  defp text_of(children), do: Enum.map_join(children, &text_of/1)

  defp broken_config do
    """
    # @package _global_

    defaults:
      - /monty: graph_exp1000_e3_t3
      - /monty/learning_module: evidence_5lm_nn10_dod003
      - /monty/sensor_module: camera_dist_delta_salience
      - /monty/connectivity: 1lm_1sm

    experiment:
      _target_: "tbp.monty.frameworks.experiments.monty_experiment.MontyExperiment"
      config:
        logging:
          run_name: "broken"
    """
  end

  # Puts every file a run of this experiment reads where the page looks for it,
  # so that a test which clicks Run is testing the click and not the gate. The
  # paths come out of the composed setup, the same ones the page reads.
  defp download_prerequisites(experiment) do
    Tmp.system_env("MONTY_PYTHON", interpreter())
    Tmp.system_env("MONTY_DATA", Tmp.dir("monty-data"))
    Tmp.system_env("MONTY_MODELS", Tmp.dir("monty-models"))
    Tmp.env_dir("libraries", :monty_libraries_dir)

    {:ok, opened} = Studio.open(experiment, world_simulator: :habitat)

    # The objects are a directory to create, and a directory that holds nothing
    # is not data — the page says so, and that is the check this fixture exists
    # to satisfy. The memory is one file, the library a run reads, so it is
    # written where it is named.
    for %{kind: kind, path: path} <- Prerequisites.for_setup(opened.setup),
        kind in [:data, :models] do
      case kind do
        :data ->
          File.mkdir_p!(path)
          File.write!(Path.join(path, "downloaded-by-the-test"), "")

        :models ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, "")
      end
    end
  end

  # An interpreter that answers every import with success. These tests are about
  # which world a run records and which files it reads, not about whether MuJoCo
  # is installed on the machine running them.
  defp interpreter do
    path = Tmp.file("python")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  # Monty's own configuration panel puts the seed next to the step limits, and a
  # sweep over seeds is the simplest experiment there is: the number belongs on
  # the page, where a reader can change it, and not only in the YAML behind it.
  describe "the configuration a run starts from" do
    test "shows the seed the config names, and takes another", %{conn: conn} do
      {:ok, opened} = Monty.Studio.open("tutorial/first_experiment")
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment")

      assert view |> element("#seed-value") |> render() =~
               ~s(value="#{opened.setup.seed}")

      changed = view |> element("#seed-choice") |> render_change(%{"seed" => "7"})

      assert changed =~ ~s(value="7")
    end

    test "a seed it cannot read leaves the one it had", %{conn: conn} do
      {:ok, opened} = Monty.Studio.open("tutorial/first_experiment")
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment")

      unchanged = view |> element("#seed-choice") |> render_change(%{"seed" => "not a number"})

      assert unchanged =~ ~s(value="#{opened.setup.seed}")
    end

    # `n_train_epochs: 3` with `do_train: false` is what this config says. A page
    # that read the count announced training the experiment never does.
    test "says which phases the config runs, not how many epochs it names", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      assert html =~ "train no · eval yes"
      refute html =~ "train yes"
    end

    test "says how many episodes that is, and what ends one", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent")

      # Ten objects, fourteen rotations.
      assert html =~ "140 eval"

      # The `termination` group's ceilings, beside the allowances `/monty` names.
      assert html =~ "max eval 500"
      assert html =~ "max train 1000"
      assert html =~ "total 6000"
    end

    # The page's own cap on an episode is the config's ceiling, never a per-mode
    # limit: the tutorial allows one *matching* step and three exploring ones, so
    # a cap of `max_train_steps` would cut two steps the experiment asked for.
    test "caps an episode at the config's total ceiling", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment")

      assert view |> element("#run-steps") |> render() =~ ~s(value="5")
    end
  end
end
