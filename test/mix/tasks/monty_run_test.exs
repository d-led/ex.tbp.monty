defmodule Mix.Tasks.Monty.RunTest do
  use ExTbpMonty.DataCase, async: false

  alias Monty.Studio.RunHistory

  setup do
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Monty.Test.PrerequisiteDownloads.stop_all()
    end)

    :ok
  end

  describe "a headless run" do
    test "steps the experiment and prints the same log the page streams" do
      output = run_and_capture(["tutorial/first_experiment", "--steps", "2"])

      assert output =~ "tutorial/first_experiment"
      assert output =~ "sensors: patch, view_finder"
      assert output =~ "step 0 · percepts patch,view_finder"
      assert output =~ "step 1 · percepts patch,view_finder"
      assert output =~ "2 steps in"
    end

    test "records the run, so a headless run is history like any other" do
      output = run_and_capture(["tutorial/first_experiment", "--steps", "2"])

      assert [run] = RunHistory.list()
      assert run.experiment == "tutorial/first_experiment"
      assert run.status == "finished"
      assert length(run.log) == 2
      assert run.summary["steps"] == 2
      assert output =~ "recorded as run #{run.id}"
    end

    test "leaves nothing running" do
      run_and_capture(["tutorial/first_experiment", "--steps", "1"])

      assert DynamicSupervisor.which_children(ExTbpMonty.ModelSupervisor) == []
    end

    test "--no-record keeps the database out of it" do
      output = run_and_capture(["tutorial/first_experiment", "--steps", "1", "--no-record"])

      assert RunHistory.list() == []
      assert output =~ "not recorded"
    end

    test "--quiet prints the summary without the per-step lines" do
      output = run_and_capture(["tutorial/first_experiment", "--steps", "2", "--quiet"])

      refute output =~ "step 0 ·"
      assert output =~ "2 steps in"
    end
  end

  describe "what it refuses" do
    test "an experiment Monty does not have" do
      assert_raise Mix.Error, ~r/could not open/, fn ->
        Mix.Tasks.Monty.Run.run(["not/an/experiment"])
      end
    end

    test "no experiment at all" do
      assert_raise Mix.Error, ~r/which experiment/, fn -> Mix.Tasks.Monty.Run.run([]) end
    end
  end

  # The shell writes to this process; collect what the run said before
  # asserting on it, so one test can check several lines.
  defp run_and_capture(args) do
    Mix.Tasks.Monty.Run.run(args)
    collect([])
  end

  defp collect(lines) do
    receive do
      {:mix_shell, level, [line]} when level in [:info, :error] -> collect([line | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
