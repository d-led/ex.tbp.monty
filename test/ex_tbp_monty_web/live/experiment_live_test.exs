defmodule ExTbpMontyWeb.ExperimentLiveTest do
  use ExTbpMontyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Monty.Studio.RunHistory

  setup do
    tmp = Path.join(System.tmp_dir!(), "studio-experiment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    previous_dir = Application.get_env(:ex_tbp_monty, :experiments_dir)
    previous_tick = Application.get_env(:ex_tbp_monty, :studio_tick_ms)
    previous_throttle = Application.get_env(:ex_tbp_monty, :studio_frame_throttle_ms)
    Application.put_env(:ex_tbp_monty, :experiments_dir, tmp)
    Application.put_env(:ex_tbp_monty, :studio_tick_ms, 1)
    Application.put_env(:ex_tbp_monty, :studio_frame_throttle_ms, 0)
    Application.put_env(:ex_tbp_monty, :studio_artifacts_dir, Path.join(tmp, "runs"))
    Application.put_env(:ex_tbp_monty, :studio_poll_ms, 60_000)

    on_exit(fn ->
      Application.put_env(:ex_tbp_monty, :experiments_dir, previous_dir || "priv/experiments")
      if previous_tick, do: Application.put_env(:ex_tbp_monty, :studio_tick_ms, previous_tick)

      if previous_throttle,
        do: Application.put_env(:ex_tbp_monty, :studio_frame_throttle_ms, previous_throttle),
        else: Application.delete_env(:ex_tbp_monty, :studio_frame_throttle_ms)

      Monty.Test.PrerequisiteDownloads.stop_all()
      Application.delete_env(:ex_tbp_monty, :studio_artifacts_dir)
      Application.delete_env(:ex_tbp_monty, :studio_poll_ms)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
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

  describe "during the run" do
    test "each step is streamed into the log as it happens", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=3")

      view |> element("#run") |> render_click()
      perform_run(view)

      assert [%{step: 0}, %{step: 1}, %{step: 2}] = logged_steps(view)
      assert [first_id | _rest] = logged_ids(view)
      assert view |> element("#log-#{first_id}") |> render() =~ "queued: 3 step(s)"
    end

    test "each sensor has its own view, updated as the run steps", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

      view |> element("#run") |> render_click()
      perform_run(view)

      # One panel per sensor, side by side, and the picture follows the percept.
      assert has_element?(view, "#frame-patch")
      assert has_element?(view, "#frame-view_finder")

      patch = view |> element("#frame-patch") |> render()
      assert patch =~ "<svg"
      assert patch =~ "step 1"
    end

    test "what the learning module believes is drawn while the run steps", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

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

    test "the log filter keeps a line only if every word matches", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

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
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

      view |> element("#run") |> render_click()
      perform_run(view)
      view |> element("#log-filter") |> render_change(%{"filter" => "nothingmatchesthis"})

      assert has_element?(view, "#run-log-empty")
      assert view |> element("#run-log-empty") |> render() =~ "no line matches"
    end

    test "a log with no filter says nothing about matching", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

      view |> element("#run") |> render_click()
      perform_run(view)

      # Every line matches an empty filter, so there is no empty state to show.
      refute has_element?(view, "#run-log-empty")
      assert visible_lines(view) |> length() > 1
    end

    test "opening the page again finds the run that is still going", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

      # A run that is queued but not performed: the page that was closed while
      # it waited, and a page opened while it waits, show the same run.
      view |> element("#run") |> render_click()
      run_id = current_run_id(view)

      {:ok, reopened, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

      assert current_run_id(reopened) == run_id
      assert has_element?(reopened, "#open-history")
    end
  end

  describe "after the run" do
    test "the summary reports what happened, including silence", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

      view |> element("#run") |> render_click()
      perform_run(view)

      assert render(view) =~ "After the run"
      assert has_element?(view, "#run-summary")

      # The run is history now: its record, its steps, its summary, what each
      # step saw, and the log file it wrote are all off the page.
      assert [run] = RunHistory.list()
      assert run.status == "finished"
      assert run.experiment == "base_config_10distinctobj_dist_agent"
      assert length(run.log) == 2
      assert length(run.timeline) == 2
      assert run.summary["steps"] == 2
      assert is_map(run.config)
      assert File.exists?(run.log_path)
      assert has_element?(view, "#open-history")
    end

    test "a run that is not there any more is recorded as failed, not left running" do
      {:ok, record} =
        RunHistory.start(%{
          experiment: "base_config_10distinctobj_dist_agent",
          source: "monty",
          steps: 2,
          config: %{},
          inputs: %{}
        })

      conn = Phoenix.ConnTest.build_conn()

      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

      # The page followed the row, but no worker holds it: waiting for news that
      # cannot come is the worst state a page can be in.
      assert current_run_id(view) == record.id
      view |> element("#stop") |> render_click()

      assert RunHistory.get(record.id).status == "failed"
    end
  end

  describe "a run reported from elsewhere" do
    test "the page catches up from the record", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/experiments/base_config_10distinctobj_dist_agent?steps=2")

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
  defp perform_run(view) do
    job = %Oban.Job{args: %{"run_id" => current_run_id(view)}, attempt: 1}
    assert {:ok, _record} = Monty.Studio.Jobs.Run.perform(job)

    # The page learns about the run by message; let it drain them.
    _ = :sys.get_state(view.pid)
    :ok
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
  defp rendered_lines(view) do
    ~r/<li id="log-(\d+)"[^>]*>([^<]*)<\/li>/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, id, text] -> %{id: id, text: text} end)
  end

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
end
