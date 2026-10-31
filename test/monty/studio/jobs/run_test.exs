defmodule Monty.Studio.Jobs.RunTest do
  use ExTbpMontyWeb.ConnCase, async: false

  alias Monty.Studio.{Artifacts, Jobs, RunHistory, RunLog}
  alias Monty.Test.Tmp

  # The queue runs jobs by hand here: what is under test is the run, not Oban's
  # scheduler.
  setup do
    root = Tmp.env_dir("studio-runs", :studio_artifacts_dir)

    {:ok, root: root}
  end

  defp start_run(steps), do: start_run("tutorial/first_experiment", steps)

  defp start_run(experiment, steps) do
    {:ok, opened} = Monty.Studio.open(experiment)
    RunHistory.start(RunLog.attributes(opened, steps))
  end

  defp perform(%RunHistory.Run{id: id}), do: perform_id(id)

  defp perform_id(id), do: Jobs.Run.perform(%Oban.Job{args: %{"run_id" => id}, attempt: 1})

  describe "a run that is performed" do
    test "closes its record with the summary of what it did, and what it concluded" do
      {:ok, record} = start_run(3)

      assert {:ok, closed} = perform(record)

      assert closed.status == "finished"
      assert closed.summary["steps"] == 1
      assert [0] = Enum.map(closed.timeline, & &1["step"])

      # This experiment's own policy allows exactly one matching step
      # (`StepLimit(max_eval_steps: 1)`), so the episode ends there — and the
      # learning module, which never answered, is timed out. That is the ending
      # Monty's config asks for, and it is what the record says instead of a
      # run that quietly used three steps.
      assert closed.summary["outcome"] == %{"learning_module_0" => "time_out"}
    end

    test "keeps what each step saw, so the run can be replayed" do
      # A configuration whose learning module is a stand-in, so the episode runs
      # for the steps it is given rather than concluding at once: what is under
      # test here is the recording, not the conclusion.
      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)
      {:ok, closed} = perform(record)

      [first, second] = closed.timeline

      # A step is recorded with the sensors' places in Monty's units: metres,
      # three of them, on every step.
      assert first["step"] == 0
      assert second["step"] == 1
      assert %{"patch" => %{"location" => [_, _, _]}} = first["sensors"]
      assert %{"patch" => %{"location" => [_, _, _]}} = second["sensors"]
    end

    test "writes a log file beside the record, and points at it" do
      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)

      assert {:ok, closed} = perform(record)
      assert closed.log_path == Artifacts.log_path(closed.id)

      file = File.read!(closed.log_path)
      assert file =~ "run started: base_config_10distinctobj_dist_agent"
      assert file =~ "step 0 · percepts"
      assert file =~ "run finished: 2 steps"
    end

    test "tells anyone watching what it is doing, step by step", %{root: _root} do
      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)
      Phoenix.PubSub.subscribe(ExTbpMonty.PubSub, Jobs.Run.topic(record.id))

      {:ok, _closed} = perform(record)

      assert_received {:studio, _run_id, {:started, 2}}
      assert_received {:studio, _run_id, {:step, %{step: 0, line: line, frames: frames}}}
      assert line =~ "step 0 · percepts"
      assert Enum.map(frames, & &1.sensor_id) |> Enum.sort() == ["patch", "view_finder"]
      assert_received {:studio, _run_id, {:step, %{step: 1}}}
      assert_received {:studio, _run_id, {:finished, %{status: "finished"}}}
    end
  end

  describe "the statistics a run leaves" do
    # This experiment's logging group names the CSV handler and wandb — the one
    # every benchmark config in Monty uses — so it is the run that leaves a file
    # here and a note about the handler this port does not have.
    test "writes the episode where the config's handler puts it, beside the run" do
      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)

      assert {:ok, closed} = perform(record)

      assert [header, episode] = stats_rows(closed)
      assert header =~ "primary_performance"
      assert header =~ "lm_id"

      # This world puts no object under the patch, so the module's performance is
      # Monty's word for that (`patch_off_object`) rather than a recognition, and
      # the row names the module it is about.
      assert episode =~ "patch_off_object"
      assert episode =~ "LM_0"
    end

    test "says what it logs with, and which classes it skipped, before stepping" do
      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)

      assert {:ok, closed} = perform(record)

      log = File.read!(closed.log_path)

      assert log =~
               "the episode is reported to Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandler"

      assert log =~ "wandb_handlers.py::WandbWrapper is not ported yet"
      assert log =~ Artifacts.dir(closed.id)
    end

    test "a config that asks for silent logging writes no statistics, and says so" do
      {:ok, record} = start_run(2)

      assert {:ok, closed} = perform(record)

      refute File.exists?(Path.join(Artifacts.dir(closed.id), "eval_stats.csv"))
      assert File.read!(closed.log_path) =~ "keeps no handlers, so this run writes no statistics"
    end

    test "a config that asks for the detailed logger writes the episode in full" do
      # Monty's detailed logging group pairs `DetailedGraphMatchingLogger` with
      # `DetailedJSONHandler`: the BASIC stats and, in the same file, each module's
      # buffer as the episode left it.
      {:ok, record} = start_run("test/hierarchy/two_lms_eval", 2)

      assert {:ok, closed} = perform(record)

      path = Path.join(Artifacts.dir(closed.id), "detailed_run_stats.json")
      assert File.exists?(path), File.read!(closed.log_path)

      episode =
        path |> File.read!() |> String.split("\n", trim: true) |> List.first() |> Jason.decode!()

      [entry] = Map.values(episode)
      assert %{"LM_0" => lm} = entry
      assert is_list(lm["locations"])
      assert is_list(lm["stepwise_targets_list"])
      assert is_list(entry["motor_system"]["action_sequence"])
    end
  end

  defp stats_rows(closed) do
    File.read!(Path.join(Artifacts.dir(closed.id), "eval_stats.csv"))
    |> String.split("\n", trim: true)
  end

  describe "a run that is stopped" do
    test "stops at its next step and says how far it got" do
      {:ok, record} = start_run(5)

      # A stop that is already waiting is a stop that arrived before the first
      # step: the worker checks its mailbox between timesteps, so it lands at a
      # boundary rather than in the middle of one.
      send(self(), :stop)

      assert {:ok, closed} = perform(record)
      assert closed.status == "stopped"
      assert closed.summary["steps"] == 0
    end

    test "asking a run that is not running to stop is not an error" do
      assert Jobs.Run.stop("00000000-0000-4000-8000-000000000000") == {:error, :not_found}
    end

    test "a stop is a message to the worker that holds the run" do
      run_id = "some-run-id"

      # The worker registers itself under its run; `stop/1` is the message that
      # reaches it. Nothing else is needed to stop a run.
      Registry.register(Monty.Runtime.Registry, {:studio_run, run_id}, "model-1")

      assert Jobs.Run.stop(run_id) == :ok
      assert_received :stop
    end
  end

  describe "a run that cannot happen" do
    test "says which run is missing instead of failing silently" do
      # An id that could never be a run, and one that could be but is not.
      assert {:cancel, {:not_a_run_id, "nope"}} = perform_id("nope")

      missing = Ecto.UUID.generate()
      assert {:cancel, {:no_such_run, ^missing}} = perform_id(missing)
    end

    test "records that the experiment no longer opens, and why" do
      {:ok, record} =
        RunHistory.start(%{
          experiment: "no/such/experiment",
          source: "monty",
          steps: 2,
          config: %{},
          inputs: %{}
        })

      # The reason names the experiment whose config could not be read, so the
      # row says what a person would need to fix.
      assert {:cancel, {:cannot_read, path, :enoent}} = perform(record)
      assert path =~ "no/such/experiment"

      closed = RunHistory.get(record.id)
      assert closed.status == "failed"
      assert closed.timeline == []
    end
  end

  describe "the files a run leaves" do
    test "are forgotten with the run" do
      {:ok, record} = start_run(1)
      {:ok, closed} = perform(record)
      assert File.dir?(Artifacts.dir(closed.id))

      {:ok, _deleted} = RunHistory.delete(closed)

      refute File.dir?(Artifacts.dir(closed.id))
      assert RunHistory.get(closed.id) == nil
    end
  end
end
