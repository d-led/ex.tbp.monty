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

    on_exit(fn ->
      Application.put_env(:ex_tbp_monty, :experiments_dir, previous_dir || "priv/experiments")
      if previous_tick, do: Application.put_env(:ex_tbp_monty, :studio_tick_ms, previous_tick)

      if previous_throttle,
        do: Application.put_env(:ex_tbp_monty, :studio_frame_throttle_ms, previous_throttle),
        else: Application.delete_env(:ex_tbp_monty, :studio_frame_throttle_ms)

      Monty.Test.PrerequisiteDownloads.stop_all()
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "before the run" do
    test "the experiment is shown as a diagram of what it wires together", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/experiments/tutorial/first_experiment")

      assert html =~ "tutorial/first_experiment"
      assert has_element?(view, "#setup-diagram")
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
    test "each timestep is streamed as its own row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment?steps=3")

      view |> element("#run") |> render_click()

      # The page runs on its own clock; wait for the last step rather than
      # sleeping for a guessed amount of time.
      assert_streamed_steps(view, 3)
      assert has_element?(view, "#steps-step-0")
      assert has_element?(view, "#steps-step-2")
    end

    test "each sensor has its own view, updated as the run steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment?steps=2")

      view |> element("#run") |> render_click()
      wait_for(view, "#frame-patch")

      # One panel per sensor, side by side, and the picture follows the percept.
      assert has_element?(view, "#frame-view_finder")

      patch = view |> element("#frame-patch") |> render()
      assert patch =~ "<svg"
      assert patch =~ "step 1"
    end

    test "the log is streamed as it happens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment?steps=2")

      view |> element("#run") |> render_click()
      wait_for(view, "#log-1")

      assert has_element?(view, "#run-log")
      assert view |> element("#log-0") |> render() =~ "step 0"
    end
  end

  describe "after the run" do
    test "the summary reports what happened, including silence", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/experiments/tutorial/first_experiment?steps=2")

      view |> element("#run") |> render_click()
      wait_for(view, "#run-summary")

      assert render(view) =~ "After the run"
      assert has_element?(view, "#run-summary")

      # The run is history now: its record, its steps and its summary are in
      # the database, not only on the page.
      assert [run] = RunHistory.list()
      assert run.status == "finished"
      assert run.experiment == "tutorial/first_experiment"
      assert length(run.log) == 2
      assert run.summary["steps"] == 2
      assert is_map(run.config)
      assert has_element?(view, "#open-history")
    end
  end

  defp assert_streamed_steps(view, count, attempts \\ 200) do
    cond do
      has_element?(view, "#steps-step-#{count - 1}") ->
        :ok

      attempts == 0 ->
        flunk(
          "expected #{count} streamed steps, got: #{inspect(LazyHTML.from_fragment(render(view)) |> LazyHTML.filter("#steps") |> LazyHTML.text())}"
        )

      true ->
        render(view)
        assert_streamed_steps(view, count, attempts - 1)
    end
  end

  defp wait_for(view, selector, attempts \\ 200) do
    cond do
      has_element?(view, selector) ->
        :ok

      attempts == 0 ->
        flunk("expected #{selector} to appear")

      true ->
        render(view)
        wait_for(view, selector, attempts - 1)
    end
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
