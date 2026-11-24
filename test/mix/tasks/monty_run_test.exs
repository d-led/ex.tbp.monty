defmodule Mix.Tasks.Monty.RunTest do
  use ExTbpMonty.DataCase, async: false

  alias Monty.Studio.Artifacts
  alias Monty.Studio.RunHistory
  alias Monty.Test.Tmp

  setup do
    Mix.shell(Mix.Shell.Process)

    # `monty.run` keeps the memory a training run learned, and keeping it means
    # the library tree too — writable and temporary here, holding what the
    # application ships, so a run of a config with a pretrained model still has
    # its graphs.
    _libraries = Tmp.libraries("run-task-libraries")

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
      # Both halves a run spends, because the model's clock does not measure the
      # world that moved the agent before it.
      assert output =~ "2 steps:"
      assert output =~ "µs in the model"
      assert output =~ "µs in the world"
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

    # The record's own log, at the path a page-started run writes it to: the
    # folder, the file in it, and the row pointing at both — one boundary
    # sequence for the two ways a run starts (`Monty.Studio.Jobs.Run.begin/1`).
    test "writes the run's log file, and the record points at it" do
      output =
        run_and_capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "2",
          "--episodes",
          "1"
        ])

      run = recorded_run()

      assert run.log_path == Artifacts.log_path(run.id)
      assert File.read!(run.log_path) =~ "step 0 ·"
      # The printed line and the logged line are one sentence, not two.
      assert output =~ "step 0 ·"
    end

    # The config names `BasicCSVStatsHandler`, and that file is what a run's
    # judgement is read from afterwards — the page's "Judged — …" line, `mix
    # monty.compare`, the summary sentence. A run started from the page leaves it,
    # so the command line must not be a second kind of run that keeps the steps and
    # loses the numbers.
    test "writes the statistics its config asks for into the run's own folder" do
      run_and_capture(["base_config_10distinctobj_dist_agent", "--steps", "2", "--episodes", "1"])

      run = recorded_run()

      stats =
        Path.join(Artifacts.dir(run.id), "eval_stats.csv")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert [header | rows] = stats
      assert header =~ "primary_performance"
      assert length(rows) == 1
    end

    # Monty's `run_parallel.py` from the command line: the episodes are divided
    # into parts and the queue's own runner performs them, so what comes out is
    # one record holding every episode of the slice, each step saying which part
    # took it — the same division a page starts, reached without a browser.
    test "--parallel divides the episodes into parts of one record" do
      output =
        run_and_capture([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "1",
          "--episodes",
          "2",
          "--parallel",
          "2"
        ])

      run = recorded_run()

      assert run.inputs["parallel"] == 2
      assert run.inputs["parts"] |> Enum.map(& &1["index"]) == [0, 1]
      assert run.log |> Enum.map(& &1["episode"]) |> Enum.sort() == [0, 1]
      assert run.log |> Enum.map(& &1["part"]) |> Enum.uniq() |> Enum.sort() == [0, 1]
      assert output =~ "recorded as run #{run.id}"
    end

    # A part is a piece of a run's record, so asking for a divided run with
    # nothing to record is refused by name: the alternative is an undivided run
    # printed under a name that promised otherwise.
    test "--parallel refuses --no-record, and says why" do
      assert_raise Mix.Error, ~r/needs a record/, fn ->
        Mix.Tasks.Monty.Run.run([
          "base_config_10distinctobj_dist_agent",
          "--episodes",
          "1",
          "--parallel",
          "2",
          "--no-record"
        ])
      end
    end

    test "leaves nothing running" do
      run_and_capture(["base_config_10distinctobj_dist_agent", "--steps", "1", "--episodes", "1"])

      assert DynamicSupervisor.which_children(ExTbpMonty.Core.ModelSupervisor) == []
    end

    # The levers a page offers, and the reason to have them here too: two runs of
    # one seed compared by a script, with the choice in the record rather than in
    # whatever the shell happened to export.
    test "--sensors and --scheduling are recorded with the run" do
      run_and_capture([
        "base_config_10distinctobj_dist_agent",
        "--steps",
        "1",
        "--episodes",
        "1",
        "--sensors",
        "concurrent",
        "--scheduling",
        "one_step_behind",
        "--settle",
        "4"
      ])

      run = recorded_run()
      assert run.inputs["sensors_step"] == "concurrent"
      assert run.inputs["scheduling"] == "one_step_behind"
      assert run.inputs["settle"] == 4
    end

    test "and a run that names none records none" do
      run_and_capture(["base_config_10distinctobj_dist_agent", "--steps", "1", "--episodes", "1"])

      run = recorded_run()
      refute Map.has_key?(run.inputs, "sensors_step")
      refute Map.has_key?(run.inputs, "settle")
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
      assert output =~ "2 steps:"
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

      assert output =~
               "the memory learning_module_0 learned is the library surf_agent_2obj_unsupervised " <>
                 "(trained), in #{directory}"

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

    # A value the task cannot read is refused, not quietly run as the default: a
    # run that says `concurrent` in its record and served its sensors one after
    # another is worse than a run that did not start.
    test "a sensors mode this port does not have" do
      assert_raise Mix.Error, ~r/sensors is `auto`/, fn ->
        Mix.Tasks.Monty.Run.run([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "1",
          "--sensors",
          "parallel"
        ])
      end
    end

    test "a scheduling mode this port does not have" do
      assert_raise Mix.Error, ~r/scheduling is `barrier`/, fn ->
        Mix.Tasks.Monty.Run.run([
          "base_config_10distinctobj_dist_agent",
          "--steps",
          "1",
          "--scheduling",
          "eager"
        ])
      end
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
