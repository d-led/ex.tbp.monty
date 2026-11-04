defmodule Monty.Studio.Jobs.RunTest do
  use ExTbpMontyWeb.ConnCase, async: false

  alias Monty.Studio.{Artifacts, Drafts, Jobs, RunHistory, RunLog}
  alias Monty.Test.Tmp

  # The experiment a run of this file steps: an evaluation config whose classes
  # this port has written, and the experiment the port is judged by.
  @experiment "base_config_10distinctobj_dist_agent"

  # The queue runs jobs by hand here: what is under test is the run, not Oban's
  # scheduler.
  setup do
    root = Tmp.env_dir("studio-runs", :studio_artifacts_dir)

    {:ok, root: root}
  end

  defp start_run(steps), do: start_run(@experiment, steps)

  # The silent and detailed logging groups belong to experiments this port
  # cannot run, because they train. The group itself is ordinary, so it is put
  # on a config that does run: a draft is that composition with one choice
  # changed, which is what the studio's builder writes.
  defp draft_with_logging(name, group) do
    yaml =
      Path.join([:code.priv_dir(:ex_tbp_monty), "monty/conf/experiment/#{@experiment}.yaml"])
      |> File.read!()
      |> String.replace("/logging: basic_warning_wandb_monty_runs", "/logging: #{group}")

    {:ok, _draft} = Drafts.import(name, yaml, overwrite: true)
    name
  end

  # One episode: what is under test is the job — its record, its log, what it
  # broadcasts — and an experiment's own run is every object in every rotation,
  # which is minutes of work this test does not need. The epoch itself is
  # `Monty.Frameworks.Experiments.MontyExperiment`'s own spec.
  defp start_run(experiment, steps) do
    {:ok, opened} = Monty.Studio.open(experiment)
    RunHistory.start(RunLog.attributes(opened, steps, 0, 1, 1))
  end

  defp perform(%RunHistory.Run{id: id}), do: perform_id(id)

  defp perform_id(id), do: Jobs.Run.perform(%Oban.Job{args: %{"run_id" => id}, attempt: 1})

  # Two fields of a record are choices the config cannot make for a particular
  # run: the world to step and the seed to step it from. Both are read back from
  # the record, so a seed a page shows is the seed the run used.
  describe "the experiment a record describes" do
    test "a run steps from the seed its record kept" do
      {:ok, record} = start_run(1)

      {:ok, opened} = Jobs.Run.opened_for(%{record | seed: 7})

      assert opened.setup.seed == 7
    end

    test "a record that kept no seed leaves the config's own" do
      {:ok, record} = start_run(1)
      {:ok, from_config} = Monty.Studio.open(record.experiment)

      {:ok, opened} = Jobs.Run.opened_for(%{record | seed: nil})

      assert opened.setup.seed == from_config.setup.seed
    end
  end

  describe "a run that is performed" do
    test "closes its record with the summary of what it did, and what it concluded" do
      {:ok, record} = start_run(3)

      assert {:ok, closed} = perform(record)

      assert closed.status == "finished"

      # An episode in evaluation ends when its module recognises the object,
      # which takes about twenty steps: three is fewer than that, so the steps
      # are the ones asked for and there is no conclusion to report — and none
      # invented.
      assert closed.summary["steps"] == 3
      assert Enum.map(closed.timeline, & &1["step"]) == [0, 1, 2]
      assert closed.summary["outcome"] == %{}
    end

    test "steps the epochs the config asks for, and only those" do
      # The config names three train epochs and switches training off, so what
      # it runs is the fourteen evaluation ones — and nothing here trains. A
      # config that asks to train is refused rather than stood in for, because a
      # training episode would explore and conclude nothing.
      {:ok, opened} = Monty.Studio.open(@experiment)
      {:ok, one_episode} = RunHistory.start(RunLog.attributes(opened, 1, 0, 1, 1))
      assert {:ok, evaluated} = perform(one_episode)

      assert File.read!(evaluated.log_path) =~ "14 eval epoch(s)"
      refute File.read!(evaluated.log_path) =~ "train epoch(s)"
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

    test "keeps the picture each step saw, not the arrays behind it" do
      # What a replay draws is the world's own rendering — a run recorded from
      # the transformed observations has poses in it and no pixels, so a finished
      # run shows blank frames. The camera arrays themselves stay out of the row.
      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)
      {:ok, closed} = perform(record)

      [first | _rest] = closed.timeline
      patch = first["sensors"]["patch"]

      assert %{"depth" => depth, "colour" => colour, "range" => [low, high]} = patch["images"]
      assert png?(depth)
      assert png?(colour)
      assert low < high

      refute Map.has_key?(patch, "depth")
      refute Map.has_key?(patch, "rgba")
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

    test "keeps which episode each step was in, so two episodes cannot be read as one" do
      # Two episodes of one object each. Every episode restarts the step counter,
      # so the steps on their own read `[0, 0]` and say nothing about which
      # episode they belong to — which is what a chart needs to keep them apart.
      {:ok, opened} = Monty.Studio.open("base_config_10distinctobj_dist_agent")
      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 1, 2))

      assert {:ok, closed} = perform(record)

      assert Enum.map(closed.log, & &1["episode"]) == [0, 1]
      assert Enum.map(closed.log, & &1["step"]) == [0, 0]
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
      # wandb is off by default, and a note about a wandb class that was skipped
      # is not said to nobody — so this run is told one is configured.
      Tmp.app_env(:wandb_mode, "online")

      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)

      assert {:ok, closed} = perform(record)

      log = File.read!(closed.log_path)

      assert log =~
               "the episode is reported to Monty.Frameworks.Loggers.MontyHandlers.BasicCSVStatsHandler"

      assert log =~ "wandb_handlers.py::WandbWrapper wraps no handler this port has"
      assert log =~ Artifacts.dir(closed.id)
    end

    test "a config that asks for silent logging writes no statistics, and says so" do
      {:ok, record} =
        start_run(draft_with_logging("silent_logging_eval", "silent_warning_monty_runs"), 2)

      assert {:ok, closed} = perform(record)

      refute File.exists?(Path.join(Artifacts.dir(closed.id), "eval_stats.csv"))
      assert File.read!(closed.log_path) =~ "keeps no handlers, so this run writes no statistics"
    end

    test "a config that asks for the detailed logger writes the episode in full" do
      # Monty's detailed logging group pairs `DetailedGraphMatchingLogger` with
      # `DetailedJSONHandler`: the BASIC stats and, in the same file, each module's
      # buffer as the episode left it.
      {:ok, record} =
        start_run(draft_with_logging("detailed_logging_eval", "detailed_info_monty_runs"), 2)

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

      # A handler that wants the DETAILED level is what makes the modules keep the
      # hypothesis space, so the evidence trace is in the file and not only the
      # buffer's pose — Monty's `init_monty_data_loggers`, end to end.
      assert is_list(lm["evidences"])
      assert is_list(lm["possible_matches"])
      assert [%{} | _] = lm["possible_locations"]
    end
  end

  defp stats_rows(closed) do
    File.read!(Path.join(Artifacts.dir(closed.id), "eval_stats.csv"))
    |> String.split("\n", trim: true)
  end

  # A picture a step kept: PNG, base64 because it travels in JSON.
  defp png?(base64) do
    match?({:ok, <<0x89, "PNG", _rest::binary>>}, Base.decode64(base64))
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

  describe "a run whose world will not start" do
    # The failure that prompted this: a record was written, the world exited,
    # `Run.start/2` raised — and the record said "running" for ever, because the
    # exception left `perform/1` before anything could close it. The page then
    # showed a run with no steps and no pictures, and the experiment refused to
    # run again because its old run was "already running".
    test "leaves its record failed, with the reason, instead of running for ever" do
      # A world this build does not carry: the config composes, the page says so,
      # and a run of it cannot start. What the record owes is the reason.
      Tmp.app_env(:world_simulator, :habitat)

      {:ok, record} = start_run(2)

      assert_raise ArgumentError, ~r/is not a world this application carries/, fn ->
        perform(record)
      end

      closed = RunHistory.get(record.id)
      assert closed.status == "failed"
      assert closed.summary["reason"] =~ "is not a world this application carries"

      # In its own log as well, because that file is what someone reads when the
      # page is not enough.
      assert File.read!(closed.log_path) =~ "the run died"

      refute Enum.any?(RunHistory.running(), &(&1.id == record.id))
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
