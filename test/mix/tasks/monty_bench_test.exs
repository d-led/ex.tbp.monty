defmodule Mix.Tasks.Monty.BenchTest do
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

  describe "a benchmark" do
    test "reports a row per experiment shape" do
      output = capture(["tutorial/first_experiment", "--steps", "2", "--repeat", "1"])

      assert output =~ "tutorial/first_experiment"
      assert output =~ "µs/step"
    end

    test "leaves no processes and no history behind" do
      capture(["tutorial/first_experiment", "--steps", "2", "--repeat", "2"])

      assert DynamicSupervisor.which_children(ExTbpMonty.ModelSupervisor) == []
      assert RunHistory.list() == []
    end

    test "can be read by a machine" do
      output = capture(["tutorial/first_experiment", "--steps", "2", "--repeat", "1", "--json"])

      assert [%{"experiment" => "tutorial/first_experiment", "steps" => 2, "runnable?" => true}] =
               Jason.decode!(output)
    end
  end

  describe "what it refuses" do
    test "no experiment at all" do
      assert_raise Mix.Error, ~r/which experiment/, fn -> Mix.Tasks.Monty.Bench.run([]) end
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
