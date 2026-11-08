defmodule Mix.Tasks.Monty.RunTest do
  use ExTbpMonty.DataCase, async: false

  alias Monty.Studio.RunHistory
  alias Monty.Test.Tmp

  setup do
    Mix.shell(Mix.Shell.Process)

    # A run history is what this module asserts about, so it starts empty: the
    # table survives between local runs, and "the database is untouched" is a
    # claim about a database nothing else has written to.
    ExTbpMonty.Repo.delete_all(RunHistory.Run)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Monty.Test.PrerequisiteDownloads.stop_all()
    end)

    :ok
  end

  describe "a headless run" do
    test "steps the experiment and prints the same log the page streams" do
      output =
        run_and_capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "2",
          "--episodes",
          "1"
        ])

      assert output =~ "base_config_10distinctobj_dist_agent"
      assert output =~ "sensors: patch, view_finder"
      # The whole experiment, in the words the studio page promises it in.
      assert output =~ "episodes, as the config runs them: 140 eval"
      # The view finder measures the scene and sends no percept, so the step log
      # names only the sensor that made one.
      assert output =~ "step 0 · percepts patch ·"
      assert output =~ "step 1 · percepts patch ·"
      assert output =~ "2 steps in"
    end

    test "covers the whole experiment by default, not one episode of it" do
      # Two objects in one evaluation epoch, which is two episodes — and both of
      # them have to happen: a single episode is a smoke test that would sit in
      # the history looking like a result. The draft is the acceptance config
      # with its object list and epochs narrowed, because ten objects in
      # fourteen rotations is two minutes of work this test does not need.
      output = run_and_capture([draft_of_two_objects(), "--steps", "1"])

      assert output =~ "episode 1/2"
      assert output =~ "episode 2/2"

      run = recorded_run()
      assert run.inputs["episodes"] == 2
      assert run.log |> Enum.map(& &1["episode"]) |> Enum.uniq() |> length() == 2
    end

    test "an evaluation experiment steps only its eval epochs" do
      # The config names three train epochs and switches training off; what it
      # runs is the fourteen evaluation ones, and nothing here trains.
      output =
        run_and_capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "1",
          "--episodes",
          "1"
        ])

      assert output =~ "epochs: train 3 · eval 14"
      refute output =~ "training · evaluation: train yes"
    end

    test "--episodes is a slice, and the record keeps the slice it ran" do
      run_and_capture(["base_config_10distinctobj_dist_agent", "--steps", "1", "--episodes", "2"])

      run = recorded_run()
      assert run.inputs["episodes"] == 2
      assert run.log |> Enum.map(& &1["episode"]) |> Enum.uniq() == [0, 1]
    end

    test "records the run, so a headless run is history like any other" do
      output =
        run_and_capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "2",
          "--episodes",
          "1"
        ])

      run = recorded_run()
      assert run.experiment == "base_config_10distinctobj_dist_agent"
      assert run.status == "finished"
      assert length(run.log) == 2
      assert run.summary["steps"] == 2
      assert output =~ "recorded as run #{run.id}"
    end

    test "leaves nothing running" do
      run_and_capture(["base_config_10distinctobj_dist_agent", "--steps", "1", "--episodes", "1"])

      assert DynamicSupervisor.which_children(ExTbpMonty.ModelSupervisor) == []
    end

    test "--no-record keeps the database out of it" do
      output =
        run_and_capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "1",
          "--episodes",
          "1",
          "--no-record"
        ])

      assert RunHistory.list() == []
      assert output =~ "not recorded"
    end

    test "--quiet prints the summary without the per-step lines" do
      output =
        run_and_capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "2",
          "--episodes",
          "1",
          "--quiet"
        ])

      refute output =~ "step 0 ·"
      assert output =~ "2 steps in"
    end

    test "keeps the memory a training run learned, as the page's worker does" do
      # The queue's worker wrote the memory at the end of a training phase and the
      # command line did not, so the same experiment trained on the page and
      # trained for nothing from a terminal: the graphs died with the process.
      output =
        run_and_capture([
          "tutorial/surf_agent_2obj_unsupervised",
          "--steps",
          "3",
          "--episodes",
          "1"
        ])

      run = recorded_run()
      directory = Monty.Studio.Learned.dir(run.id)
      assert output =~ "the memory learning_module_0 learned is in #{directory}"

      # A training episode matches nothing, so the memory it built is what it has
      # to show: the object it explored and the nodes behind it.
      assert output =~ "the memory now holds 1 object and "

      assert [file] =
               Path.wildcard(Path.join([directory, Monty.Studio.Learned.release(), "*.jsonl.gz"]))

      assert File.stat!(file).size > 0
    end
  end

  describe "what it refuses" do
    test "an experiment Monty does not have" do
      assert_raise Mix.Error, ~r/could not open/, fn ->
        Mix.Tasks.Monty.Run.run(["not/an/experiment"])
      end
    end

    test "an experiment built from classes this port has not written" do
      # Monty's first tutorial names a training experiment class — the learning
      # module it trains is written, the class that supervises it is not. A
      # stand-in would run and conclude nothing, so the run is refused and
      # nothing is recorded.
      assert_raise Mix.Error, ~r/would not start/, fn ->
        Mix.Tasks.Monty.Run.run(["tutorial/first_experiment", "--steps", "1"])
      end

      assert RunHistory.list() == []
    end

    test "no experiment at all" do
      assert_raise Mix.Error, ~r/which experiment/, fn -> Mix.Tasks.Monty.Run.run([]) end
    end
  end

  # The acceptance config, narrowed to two objects in one evaluation epoch. A
  # draft, because that is what the studio's builder writes: the same
  # composition with two choices changed.
  defp draft_of_two_objects do
    Tmp.env_dir("run-task-drafts", :experiments_dir)

    yaml =
      Path.join([
        :code.priv_dir(:ex_tbp_monty),
        "monty/conf/experiment/base_config_10distinctobj_dist_agent.yaml"
      ])
      |> File.read!()
      |> String.replace(
        "/env_interface: eval_distinctobj_predefined",
        "/env_interface: test_eval_2obj_predefined"
      )
      |> String.replace("n_eval_epochs: ${constants.rotations_all_count}", "n_eval_epochs: 1")

    {:ok, _draft} = Monty.Studio.Drafts.import("two_object_eval", yaml, overwrite: true)
    "two_object_eval"
  end

  # A list row is the table's projection and carries no steps, so what a test
  # reads the steps off is the record they were written to.
  defp recorded_run do
    assert [row] = RunHistory.list()
    RunHistory.get(row.id)
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
