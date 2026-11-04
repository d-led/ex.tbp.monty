defmodule Mix.Tasks.Monty.BenchTest do
  use ExTbpMonty.DataCase, async: false

  alias Monty.Studio.RunHistory

  setup do
    Mix.shell(Mix.Shell.Process)

    # A benchmark records nothing, which is a claim about an empty table.
    ExTbpMonty.Repo.delete_all(RunHistory.Run)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Monty.Test.PrerequisiteDownloads.stop_all()
    end)

    :ok
  end

  describe "a benchmark" do
    test "reports a row per experiment shape" do
      output = capture(["base_config_10distinctobj_dist_agent", "--steps", "2", "--repeat", "1"])

      assert output =~ "base_config_10distinctobj_dist_agent"
      assert output =~ "µs/step"
    end

    test "leaves no processes and no history behind" do
      capture(["base_config_10distinctobj_dist_agent", "--steps", "2", "--repeat", "2"])

      assert DynamicSupervisor.which_children(ExTbpMonty.ModelSupervisor) == []
      assert RunHistory.list() == []
    end

    test "can be read by a machine" do
      output =
        capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "2",
          "--repeat",
          "1",
          "--json"
        ])

      assert [
               %{
                 "experiment" => "base_config_10distinctobj_dist_agent",
                 "steps" => 2,
                 "runnable?" => true
               }
             ] = Jason.decode!(output)
    end

    test "a refused experiment is a row, not a crash" do
      assert_raise Mix.Error, ~r/cannot run here/, fn ->
        Mix.Tasks.Monty.Bench.run([
          "tutorial/first_experiment",
          "--steps",
          "2",
          "--repeat",
          "1",
          "--json"
        ])
      end

      # The row is written before the task gives up: a caller scripting the
      # benchmark reads the same answer the table has.
      assert [%{"experiment" => "tutorial/first_experiment", "runnable?" => false}] =
               collect([]) |> Jason.decode!()
    end
  end

  describe "what it refuses" do
    test "no experiment at all" do
      assert_raise Mix.Error, ~r/which experiment/, fn -> Mix.Tasks.Monty.Bench.run([]) end
    end

    # `for _ <- 1..0` counts down and yields two, so a zero used to measure
    # twice rather than not at all.
    test "zero steps, because that would have measured two" do
      assert_raise Mix.Error, ~r/--steps must be at least 1/, fn ->
        Mix.Tasks.Monty.Bench.run(["tutorial/first_experiment", "--steps", "0"])
      end
    end

    test "zero repetitions, for the same reason" do
      assert_raise Mix.Error, ~r/--repeat must be at least 1/, fn ->
        Mix.Tasks.Monty.Bench.run(["tutorial/first_experiment", "--repeat", "0"])
      end
    end
  end

  defp capture(args) do
    Mix.Tasks.Monty.Bench.run(args)
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
