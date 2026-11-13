defmodule Monty.Studio.Jobs.RunTest do
  use ExTbpMontyWeb.ConnCase, async: false

  alias ExTbpMonty.Cluster.{Nodes, Protocol}
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory

  alias Monty.Studio.{
    Artifacts,
    Drafts,
    Jobs,
    Memory,
    Partition,
    RunHistory,
    RunLog,
    RunStream,
    Summary
  }

  alias Monty.Studio.Jobs.Stops
  alias Monty.Test.Tmp

  # The experiment a run of this file steps: an evaluation config whose classes
  # this port has written, and the experiment the port is judged by.
  @experiment "base_config_10distinctobj_dist_agent"

  # An experiment that trains, from an empty memory, on two objects — the one an
  # evaluation cannot stand in for.
  @training_experiment "tutorial/surf_agent_2obj_unsupervised"

  # The same, in the family Monty's own tests assert on: one object, three train
  # epochs then three evaluation ones, and a config that names no run at all.
  @unnamed_training_experiment "test/evidence_lm/evidence"

  # The queue runs jobs by hand here: what is under test is the run, not Oban's
  # scheduler.
  setup do
    root = Tmp.env_dir("studio-runs", :studio_artifacts_dir)

    # A run that trains files its memory in the library tree as well as in its
    # own directory, and the tree is where a config looks — so it is writable and
    # temporary here, while still holding the libraries this application ships.
    libraries = Tmp.libraries("studio-runs-libraries")

    {:ok, root: root, libraries: libraries}
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
  defp start_run(experiment, steps, options \\ []) do
    {:ok, opened} = Monty.Studio.open(experiment)

    RunHistory.start(RunLog.attributes(opened, steps, 0, 1, Keyword.get(options, :episodes, 1)))
  end

  # The smallest PNG there is, base64: a picture the store can write and the route
  # can serve.
  defp base64_png do
    Base.encode64(
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
        6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0,
        1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
    )
  end

  # The cluster as `Monty.Studio.Partition` sees it: this node and a peer that
  # shares the run's folder and this build, and answers nothing. `Nodes.snapshot/0`
  # is what the division reads, so a list put there is the whole of "a cluster of
  # two" for a test — and it is put back afterwards, because it is the node's own.
  defp cluster_of_two(peer_name) do
    identity = Nodes.identity()

    here = Map.merge(identity, %{name: name_of_this_node(), self: true, alive: true})

    peer = %{
      node: :"gone@127.0.0.1",
      name: "#{peer_name}_127.0.0.1",
      address: "gone@127.0.0.1",
      self: false,
      alive: true,
      version: identity.version,
      protocol: identity.protocol,
      capabilities: identity.capabilities,
      artifacts: identity.artifacts,
      web: nil,
      plugins: []
    }

    previous = :persistent_term.get({Nodes, :snapshot}, :none)
    :persistent_term.put({Nodes, :snapshot}, [here, peer])

    on_exit(fn ->
      case previous do
        :none -> :persistent_term.erase({Nodes, :snapshot})
        entries -> :persistent_term.put({Nodes, :snapshot}, entries)
      end
    end)

    :ok
  end

  defp name_of_this_node, do: Monty.Paths.data_dir_name()

  defp perform(%RunHistory.Run{id: id}), do: perform_id(id)

  defp perform_id(id) do
    performed = Jobs.Run.perform(%Oban.Job{args: %{"run_id" => id}, attempt: 1})

    # A step's announcement comes from the process that draws its pictures, and
    # that drawing is deliberately behind the run's own barrier: the job returns
    # while pictures are still being written. Asking the stream for its count
    # settles the order — a call answers after the casts before it, and each of
    # those has handed its pictures on — and then the drawing catches up. Without
    # it a test that reads a step is racing a slower machine.
    #
    # A whole run's pictures are more than a page's, so the wait is the test's
    # own limit rather than a five-second guess: what is being waited for is work
    # that has already been queued.
    _ = RunStream.count(id)
    :ok = RunStream.Pictures.settle(:infinity)

    performed
  end

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
      # invented. The module is named with no conclusion rather than left out,
      # which is Monty's own answer for a module that never concluded.
      assert closed.summary["steps"] == 3
      assert Enum.map(closed.timeline, & &1["step"]) == [0, 1, 2]
      assert closed.summary["outcome"] == %{"learning_module_0" => nil}
    end

    # The last episode is not the run. An evaluation of several episodes has one
    # conclusion each, and whether this port recognises what Monty recognises is
    # a question about all of them — so the record keeps a tally, which is the
    # line the page shows "across the run" and what `mix monty.run` reports.
    test "keeps a tally of what each episode concluded, not only the last one" do
      {:ok, record} = start_run(@experiment, 40, episodes: 2)

      assert {:ok, closed} = perform(record)

      assert closed.summary["outcomes"] == %{"learning_module_0" => %{"match" => 2}}

      assert Summary.outcomes_line(closed.summary["outcomes"]) ==
               "learning_module_0: match 2 of 2"
    end

    # A tag is a filter on which nodes may perform a run, and a node that runs
    # alone is the only one there is: asking for something it does not offer must
    # not turn a run it always performed into a run that waits forever.
    test "is performed here when nothing in the cluster offers what it asked for" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      attributes =
        opened
        |> RunLog.attributes(1, 0, 1, 1)
        |> update_in([:inputs], &Map.put(&1, "capabilities", ["gpu"]))

      {:ok, record} = RunHistory.start(attributes)
      assert record.inputs["capabilities"] == ["gpu"]

      assert {:ok, closed} = perform(record)
      assert closed.status == "finished"
    end

    test "steps the epochs the config asks for, and only those" do
      # The config switches training off and names fourteen evaluation epochs, so
      # what a run of it does is those fourteen and no training phase.
      {:ok, opened} = Monty.Studio.open(@experiment)
      {:ok, one_episode} = RunHistory.start(RunLog.attributes(opened, 1, 0, 1, 1))
      assert {:ok, evaluated} = perform(one_episode)

      assert File.read!(evaluated.log_path) =~ "14 eval epoch(s)"
      refute File.read!(evaluated.log_path) =~ "train epoch(s)"
    end

    test "a run that trains leaves the memory it learned where the run's own files are" do
      # Monty's `save_state_dir/1` writes the pretrained model at the end of
      # pretraining. Without that, what a training phase learned dies with the
      # process that built it, and the next run starts from the pretrained graphs
      # again. The file is the library format, so `Memory.load/3` reads it.
      {:ok, opened} = Monty.Studio.open(@training_experiment)
      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 40, 0, 1, 1))

      assert {:ok, closed} = perform(record)
      assert closed.status == "finished"
      assert File.read!(closed.log_path) =~ "the memory learning_module_0 learned is the library"

      libraries = Path.join(Artifacts.dir(closed.id), "memory")
      assert [file] = Path.wildcard(Path.join(libraries, "**/*.jsonl.gz"))

      {:ok, learned} = Memory.load(Path.basename(file, ".jsonl.gz"), "trained", libraries)

      # The object an untouched module names when it finds nothing it knows,
      # which is Monty's own naming for what a first training episode adds.
      assert GraphMemory.get_memory_ids(learned) == ["new_object0"]
    end

    # The tutorial's scene is a YCB object, and the meshes are a prerequisite
    # this suite does not carry: a machine with `MONTY_DATA` unpacked runs this,
    # one without skips it.
    @tag skip:
           if(Monty.Prerequisites.present?(Monty.Prerequisites.get("ycb_objects_1_0")),
             do: false,
             else: "the YCB meshes are not on this machine"
           )
    test "a supervised experiment states the episode's answer, so its memory has the object" do
      # The tutorial is the one config here that learns by being told what it
      # saw: its experiment class states the object and the pose at the end of
      # the episode, and that statement is what the memory is written under.
      # Three exploring steps is its whole episode (`num_exploring_steps: 3`).
      # Against MuJoCo, because a supervised episode reads the object and pose it
      # was given off the world, and the stand-in scene has none to state.
      {:ok, opened} = Monty.Studio.open("tutorial/first_experiment", world_simulator: :mujoco)
      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 3, 0, 1, 1))

      assert {:ok, closed} = perform(record)
      assert closed.status == "finished"
      assert closed.steps_done == 3

      libraries = Path.join(Artifacts.dir(closed.id), "memory")
      assert [file] = Path.wildcard(Path.join(libraries, "**/*.jsonl.gz"))

      {:ok, learned} = Memory.load(Path.basename(file, ".jsonl.gz"), "trained", libraries)

      # The object the world says it put in front of the agent, not a
      # `new_object<n>`: the experiment knew the answer and said it.
      assert GraphMemory.get_memory_ids(learned) == ["mug"]
    end

    test "and files it under the experiment when the config names neither a model nor a run" do
      # Most of Monty's test configs leave `run_name` empty and name no model, so
      # the run's own name is what is left: a memory filed under `""` is a memory
      # that was written nowhere.
      {:ok, opened} = Monty.Studio.open(@unnamed_training_experiment)
      assert opened.setup.model_name_or_path == ""
      assert opened.setup.logging.run_name == ""

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 30, 0, 1, 1))
      assert {:ok, closed} = perform(record)

      assert File.read!(closed.log_path) =~ "the memory learning_module_0 learned is the library"

      assert [file] =
               Path.wildcard(
                 Path.join([Artifacts.dir(closed.id), "memory", "trained", "*.jsonl.gz"])
               )

      assert Path.basename(file) == "test-evidence_lm-evidence.jsonl.gz"
    end

    test "numbers the episodes of a run, and walks each phase's own objects" do
      # This config trains on two objects (`capsule3DSolid`, `cubeSolid`) for three
      # epochs and evaluates one for three, so a run of it is nine episodes — and
      # each epoch counts its own episodes from zero, so a record that kept the
      # epoch's index would hold three "episode 0"s and a chart would draw them as
      # one.
      {:ok, opened} = Monty.Studio.open(@unnamed_training_experiment)
      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 30, 0, 1, nil))

      assert {:ok, closed} = perform(record)

      episodes = closed.log |> Enum.map(& &1["episode"]) |> Enum.uniq() |> Enum.sort()
      assert episodes == Enum.to_list(0..8)

      # Each epoch walks its phase's objects — two in training, one in
      # evaluation — which `Setup.with_phase/2` is what an episode is built from
      # (`setup_test.exs` says so directly; the stand-in scene shows one sphere,
      # so the memory cannot tell the two objects apart here).

      # And every episode starts its own step counter again, which is what makes
      # the number worth having.
      assert closed.log |> Enum.filter(&(&1["episode"] == 3)) |> Enum.map(& &1["step"]) ==
               Enum.to_list(0..(Enum.count(closed.log, &(&1["episode"] == 3)) - 1))
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
      # run shows blank frames. The camera arrays themselves stay out of the row,
      # and so do the pictures: the row names the file each one was written to,
      # because ten kilobytes a step is what made a long run wider than a jsonb
      # value can be.
      {:ok, record} = start_run("base_config_10distinctobj_dist_agent", 2)
      {:ok, closed} = perform(record)

      [first | _rest] = closed.timeline
      patch = first["sensors"]["patch"]

      assert %{"depth" => depth, "colour" => colour, "range" => [low, high]} = patch["images"]
      assert picture?(record.id, depth)
      assert picture?(record.id, colour)
      assert low < high

      refute Map.has_key?(patch, "depth")
      refute Map.has_key?(patch, "rgba")
    end

    test "leaves no model of its own behind" do
      # The model outlives its episodes — the next one is started on it — so the
      # run is what stops it: one per phase, released when the last phase ends.
      # A model that outlived its run would be a memory (and a graph index) held
      # for as long as the studio lives.
      {:ok, opened} = Monty.Studio.open(@experiment)
      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 1, 2))
      before = length(DynamicSupervisor.which_children(ExTbpMonty.Core.ModelSupervisor))

      assert {:ok, _closed} = perform(record)

      assert length(DynamicSupervisor.which_children(ExTbpMonty.Core.ModelSupervisor)) == before
    end

    test "leaves no big heap behind when it ends" do
      # Everything a run gathers has to be collectable, and a process's heap is
      # only collected when it grows again: the model supervisor once kept the
      # model's spec — the pretrained memory with it, 203 MB — and went on holding
      # that dead heap after a finished run. One collection took a node from
      # 319 MB to 95 MB; the run asks for it, so what a run leaves is the baseline
      # and not the last run's peak.
      {:ok, opened} = Monty.Studio.open(@experiment)
      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 1, 2))

      assert {:ok, _closed} = perform(record)

      supervisor = Process.whereis(ExTbpMonty.Core.ModelSupervisor)
      {:memory, held} = Process.info(supervisor, :memory)
      assert held < 20 * 1_048_576
    end

    test "says what an episode boundary cost, and of what" do
      # A boundary is the second or two between one episode's last step and the
      # next one's first, and no step's timer accounts for it: the closing's
      # statistics, its conclusion, the stop, the hand-over of the transcript,
      # and the next episode's own start. It is half of a long run's wall clock,
      # so a run says which part is which instead of leaving it to a stopwatch.
      {:ok, opened} = Monty.Studio.open(@experiment)
      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 1, 2))

      assert {:ok, closed} = perform(record)

      # The first episode has no boundary behind it; the second says what its
      # boundary was, part by part and in the order the parts happened: the model
      # state read once, the statistics and the conclusion made from it, the stop,
      # the transcript's hand-over, and then the start — what it prepared, the
      # scene, the positioning steps and the model.
      assert [boundary] =
               closed.log_path
               |> File.read!()
               |> String.split("\n")
               |> Enum.filter(&(&1 =~ "the boundary took"))

      assert boundary =~ ~r/the boundary took [\d.]+ ms: /

      assert Regex.scan(
               ~r/\b(model state|statistics|conclusion|stop|hand-over|prepared|scene|positioning|model) /,
               boundary,
               capture: :all_but_first
             )
             |> List.flatten() ==
               [
                 "model state",
                 "statistics",
                 "conclusion",
                 "stop",
                 "hand-over",
                 "prepared",
                 "scene",
                 "positioning",
                 "model"
               ]
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

  describe "a run of several parts" do
    test "is one record, and every episode of the experiment is in its transcript" do
      # The whole point of the division (`Monty.Studio.Partition`): two parts of a
      # four-episode run take two episodes each, and what comes out is the
      # experiment — one row, one transcript, every episode in it.
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      assert {:ok, closed} = perform(record)
      assert closed.status == "finished"

      # One run, one row: no second record was made for any part.
      assert closed.id == record.id
      assert RunHistory.list_for(@experiment, limit: 50) |> Enum.count(&(&1.id == closed.id)) == 1

      assert length(closed.log) == 4
      assert closed.log |> Enum.map(& &1["episode"]) |> Enum.sort() == [0, 1, 2, 3]
      assert closed.log |> Enum.map(& &1["part"]) |> Enum.uniq() |> Enum.sort() == [0, 1]

      # The division is a row per part, and each says how it ended and where it
      # was performed. Today that node is this one — the row exists so a page can
      # say otherwise the day a part is handed to a peer.
      parts = RunHistory.parts(closed.id)

      assert Enum.map(parts, &{&1.part, &1.status}) == [{0, "finished"}, {1, "finished"}]

      # Nothing in the division is left describing work in progress about a run
      # that has ended: `settle_parts/1` closes whatever the waves did not.
      assert Enum.all?(parts, &(&1.status in ["finished", "failed", "skipped"]))
      assert Enum.all?(parts, &(&1.node == Monty.Paths.data_dir_name()))
      assert Enum.all?(parts, &(&1.finished_at != nil))
      assert Enum.sum(Enum.map(parts, & &1.steps)) == length(closed.log)

      log = File.read!(closed.log_path)
      assert log =~ "part 1 of 2 finished"
      assert log =~ "part 2 of 2 finished"

      # What the parts wrote as statistics is the run's: two parts of two
      # episodes each leave one file of four in the run's own directory, where a
      # reader looks for the experiment's numbers — the parts' own files stay in
      # their own directories, beside their own logs.
      stats =
        Path.join(Artifacts.dir(closed.id), "eval_stats.csv")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert [header | rows] = stats
      assert header =~ "primary_performance"
      assert length(rows) == 4
      assert Enum.count(stats, &(&1 == header)) == 1
    end

    # A part is performed wherever the run is divided to, and its steps are in
    # that node's memory — a table this node cannot read. So they leave through
    # the run's own directory, which is the one place every candidate for a part
    # shares (`ExTbpMonty.Cluster.Nodes.shares_run_files?/2`), and the transcript
    # is those files in part order, whichever node wrote them.
    test "keeps every part's steps in the run's own directory, and reads them in part order" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      assert {:ok, closed} = perform(record)

      for part <- parts do
        path = Artifacts.part_path(closed.id, part.phase, part.index)
        assert File.regular?(path), "part #{part.index} of #{part.phase} left no steps"

        assert {:ok, {entries, moments}} = Artifacts.read_part(closed.id, part.phase, part.index)
        assert length(entries) == length(moments)
        assert Enum.all?(entries, &(&1["part"] == part.index))
      end

      # What the record holds is those files, not a second copy of them: a part
      # this node performed is read back off disk like any other.
      {entries, _moments} =
        parts
        |> Enum.sort_by(&{&1.phase, &1.index})
        |> Enum.flat_map(fn part ->
          {:ok, {entries, moments}} = Artifacts.read_part(closed.id, part.phase, part.index)
          Enum.zip(entries, moments)
        end)
        |> Enum.unzip()

      assert closed.log == entries
      assert closed.log |> Enum.map(& &1["part"]) == [0, 0, 1, 1]
    end

    # The other half of a division across nodes: a part performed for the node
    # that owns the run leaves its steps where the owner reads them, and touches
    # nothing of the owner's record — a node's runs table is its own
    # (`docs/cluster.md`), so a peer has no row to write.
    test "a part performed for another node leaves its steps, and writes no row" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))
      [part | _rest] = parts

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      # What `:rpc` calls on the peer: the record, the part, and the memory an
      # evaluation part would start from (`nil` in a wave that trains nothing).
      assert {:ok, {:finished, _summary}, 2} = Jobs.Run.perform_part(record, part, nil)

      assert {:ok, {entries, moments}} = Artifacts.read_part(record.id, part.phase, part.index)
      assert {length(entries), length(moments)} == {2, 2}
      assert Enum.all?(entries, &(&1["part"] == part.index))

      # The owner's row is the owner's: the part was performed, not recorded.
      assert RunHistory.get(record.id).status == "queued"
      assert RunHistory.parts(record.id) == []
    end

    # A part appends its steps at every episode boundary, so the episodes it
    # finished are on disk before the next one starts. A part that is given to a
    # second node therefore picks up at its first unfinished episode instead of
    # taking its stretch again — work not repeated, and no episode written twice
    # into one transcript.
    test "a part given to a second node picks up at its first unfinished episode" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))
      [part | _rest] = parts

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      assert length(part.episodes) == 2
      assert part.phase == :eval

      # The node that had it finished its first episode and then went silent: the
      # progress is a marker per finished episode, and the steps of that episode
      # are in the part's file.
      :ok = Artifacts.append_part(record.id, part.phase, part.index, [], [], 0)

      assert Artifacts.progress(record.id, part.phase, part.index) == 1

      assert {:ok, {:finished, _summary}, steps} = Jobs.Run.perform_part(record, part, nil)

      # One episode left to take, one step each: the part took one, not two.
      assert steps == 1
      assert Artifacts.part_steps(record.id, part.phase, part.index) == 1

      assert {:ok, {entries, _moments}} = Artifacts.read_part(record.id, part.phase, part.index)
      assert entries |> Enum.map(& &1["episode"]) |> Enum.uniq() == [1]
    end

    # The other half: a part with nothing on disk takes its whole stretch, which
    # is what a first attempt is.
    test "a part nobody has started takes every episode it was given" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))
      [part | _rest] = parts

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      assert Artifacts.progress(record.id, part.phase, part.index) == 0
      assert {:ok, {:finished, _summary}, 2} = Jobs.Run.perform_part(record, part, nil)
    end

    # The door of a node that performs parts: a caller of another protocol is
    # refused by name, before any work is done — a node that answered a request
    # of a shape it does not know would fail half-way through the part instead of
    # at the door (`ExTbpMonty.Cluster.Protocol`).
    test "a peer speaking another protocol is refused rather than half-performed" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))
      [part | _rest] = parts

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      further = Protocol.version() + 1

      assert {:error, {:incompatible_peer, theirs, ours}, 0} =
               Jobs.Run.perform_part(record, part, nil, %{protocol: further})

      assert theirs == "monty-cluster/#{further}"
      assert ours == Protocol.describe(Protocol.local())

      # Nothing was stepped, so there is no part file to read.
      assert {:error, :enoent} = Artifacts.read_part(record.id, part.phase, part.index)
    end

    # A lost node costs a part an attempt, not the part. The cluster says two
    # nodes share the run's folder and this build; the peer is gone. The part the
    # round robin gives it is claimed, found unreachable — `{:badrpc, :nodedown}`
    # — given back (the row returns to `queued`) and taken by the next candidate,
    # which is this node. One owner at a time, and the run finishes.
    test "a part given to a node that is not there goes to the next candidate" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 40, 0, 2, 4, %{parts: parts}))

      cluster_of_two(:gone)

      assert {:ok, closed} = perform(record)

      assert closed.status == "finished"
      assert Enum.map(RunHistory.parts(closed.id), & &1.status) == ["finished", "finished"]

      # The division is settled, so it is nobody's: no claim outlives the work.
      assert RunHistory.parts(closed.id) |> Enum.all?(&(&1.claim == nil))

      # Both parts were performed by this node in the end, and the run says which
      # one had to move and away from what.
      assert Enum.map(RunHistory.parts(closed.id), & &1.node) ==
               [name_of_this_node(), name_of_this_node()]

      assert File.read!(Artifacts.log_path(closed.id)) =~ "lost gone_127.0.0.1"
    end

    # A run of several parts is one run, so its summary is one summary: the
    # parts' steps added up, their tallies one tally. A page that showed four
    # parts' steps and then "0 steps, 0 concluded" was showing the parts' work
    # and the run's silence.
    test "reports what its parts did as one summary" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 40, 0, 2, 4, %{parts: parts}))

      assert {:ok, closed} = perform(record)

      assert closed.summary["steps"] == length(closed.log)

      assert closed.summary["outcomes"] == %{"learning_module_0" => %{"match" => 4}}

      assert Summary.outcomes_line(closed.summary["outcomes"]) ==
               "learning_module_0: match 4 of 4"
    end

    # The pictures of a run of several parts were served from a directory nothing
    # answers for: a step's picture is fetched from a *run*, and a part's stream id
    # has no run row behind it, so every one of them came back 404. A part's
    # picture is the run's picture, in a folder named for the part.
    test "a part's picture is kept inside its run's own directory" do
      run = Ecto.UUID.generate()

      assert {:ok, name} = Artifacts.put_frame(run, "part-1-7", "patch", "depth", base64_png())
      assert name == "part-1-7/patch-depth.png"

      assert Artifacts.frame_url(run, name) == "/runs/#{run}/frames/part-1-7/patch-depth.png"
      assert {:ok, path} = Artifacts.frame_path(run, name)
      assert File.regular?(path)
    end

    test "keeps each part's memory to its own stream, and writes the merged one once", %{
      libraries: libraries
    } do
      # The library is what the parts learned *between* them, and it is written
      # once, from the merge: a part that wrote it as it finished would overwrite
      # the merged memory with its own share.
      {:ok, opened} = Monty.Studio.open(@training_experiment)
      name = Monty.Studio.Learned.name_for(opened)

      plan = Partition.plan(opened.setup, 2, nil)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 40, 0, 2, nil, %{parts: parts}))

      assert {:ok, closed} = perform(record)
      assert closed.status == "finished"

      assert File.read!(closed.log_path) =~ "merged"

      for part <- parts do
        assert Path.wildcard(Path.join(Monty.Studio.Learned.dir(part.stream), "**/*.jsonl.gz")) !=
                 [],
               "part #{part.index} left no memory of its own"
      end

      assert Path.wildcard(Path.join(Monty.Studio.Learned.dir(closed.id), "**/*.jsonl.gz")) != []
      assert Memory.releases_for(name, libraries) != []
    end

    # The forum's question, asked where it costs least: are a run's parts stateless
    # work, or owners that can be resumed? A worker that disappeared after one part
    # leaves a division behind, and the run performed again continues it — the part
    # that ended is not performed twice, its steps are still in the transcript, and
    # the division it found is the one it finishes.
    test "a run performed again continues the parts its attempt had left" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      # What such a worker leaves: the division, one part ended and the other
      # still queued, and no number of the attempt written down (it died before it
      # had any to write).
      :ok = RunHistory.plan_parts(record.id, parts)
      {:ok, claim} = RunHistory.claim_part(record.id, 0, name_of_this_node())
      :ok = RunHistory.release_part(claim, "finished", 2)

      assert {:ok, closed} = perform(record)

      assert closed.status == "finished"

      assert closed.log |> Enum.map(& &1["part"]) |> Enum.uniq() == [1],
             "the part that had already ended was performed a second time"

      assert RunHistory.parts(closed.id) |> Enum.map(& &1.status) == ["finished", "finished"]

      assert File.read!(Artifacts.log_path(closed.id)) =~
               "part 1 of 2 already finished in an earlier attempt"
    end

    test "starts its evaluation from the memory its training wave built" do
      # Monty's `run_parallel` merges the trained model and then evaluates the
      # configs it generated; here the evaluation wave is handed the merged
      # library, so it reads what its own run built.
      {:ok, opened} = Monty.Studio.open(@training_experiment)

      plan = Partition.plan(opened.setup, 2, nil)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 40, 0, 2, nil, %{parts: parts}))

      assert {:ok, closed} = perform(record)
      assert closed.status == "finished"

      [file] =
        Path.wildcard(Path.join([Artifacts.dir(closed.id), "memory", "trained", "*.jsonl.gz"]))

      {:ok, kept} =
        Memory.load(
          Path.basename(file, ".jsonl.gz"),
          "trained",
          Path.join(Artifacts.dir(closed.id), "memory")
        )

      assert GraphMemory.get_memory_ids(kept) != []
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

    test "keeps a row for every episode of the run" do
      # Each report is made with the logger the last one handed back, because a
      # handler renames a file it has not written to yet — a file that exists
      # belongs to the last run. A plan thrown away at the boundary therefore
      # renamed the run's own statistics away once an episode and left one row.
      {:ok, record} = start_run(@experiment, 2, episodes: 2)

      assert {:ok, closed} = perform(record)

      assert [header | episodes] = stats_rows(closed)
      assert header =~ "primary_performance"
      assert length(episodes) == 2
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

      # The module is reported as the episode left it, not as it was started: the
      # episode took steps, so its buffer holds them. A report read off the
      # coordinator's state was the start of the episode, and nothing in it had
      # happened yet.
      assert lm["locations"] != []
      assert lm["evidences"] != []

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
  # The URL a record keeps, read back through the file it names: a picture is
  # worth keeping only if it is still a PNG when a page asks for it.
  defp picture?(run_id, url) do
    with "/runs/" <> rest <- url,
         [_, name] <- String.split(rest, "/frames/", parts: 2),
         {:ok, path} <- Monty.Studio.Artifacts.frame_path(run_id, name),
         <<0x89, "PNG", _rest::binary>> <- File.read!(path) do
      true
    else
      _not_a_picture -> false
    end
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

    # A stopped run of several parts is stopped, not finished: the stop ends the
    # wave it arrived in and the run with it, and the parts no wave reached say
    # `skipped` — nothing happened to them.
    test "a divided run that is stopped says stopped, and never reaches its parts" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 4)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 4, %{parts: parts}))

      send(self(), :stop)

      assert {:ok, closed} = perform(record)
      assert closed.status == "stopped"
      assert closed.summary["steps"] == 0

      assert Enum.map(RunHistory.parts(closed.id), & &1.status) == ["skipped", "skipped"]
    end

    # Every process stepping the run is asked to stop, not just the job that holds
    # it: a part steps in a process of its own, and a stop waiting in the job's
    # mailbox is a stop that arrives after the run has finished.
    test "a stop is a message to every part as well as to the job" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      plan = Partition.plan(opened.setup, 2, 2)
      parts = Enum.map(Partition.parts(plan), &Map.put(&1, :stream, Ecto.UUID.generate()))

      {:ok, record} = RunHistory.start(RunLog.attributes(opened, 1, 0, 2, 2, %{parts: parts}))

      # One process per part, as a wave has: each says it holds its part, and
      # answers when it is asked to stop.
      for part <- parts do
        test = self()

        part_pid =
          spawn(fn ->
            {:ok, _} =
              Registry.register(Monty.Runtime.Registry, {:studio_run, part.stream}, :part)

            send(test, {:holding, self()})

            receive do
              :stop -> send(test, {:asked, self()})
            end
          end)

        assert_receive {:holding, ^part_pid}, 1_000
      end

      assert Jobs.Run.stop(record.id) == :ok

      assert_receive {:asked, _}, 1_000
      assert_receive {:asked, _}, 1_000
    end

    test "asking a run that is not running to stop is not an error" do
      assert Jobs.Run.stop("00000000-0000-4000-8000-000000000000") == {:error, :not_found}
    end

    # The message reaches the worker that owns the clock; the flag reaches the
    # tasks it started, which is where a run's steps happen. Without it a stop
    # was read only between waves — a whole phase for a run of one part — and a
    # page's Stop looked like it did nothing for as long as that took.
    test "a stop is a flag every process stepping the run can read, not only a message" do
      {:ok, record} = start_run(5)

      {:ok, _owner} = Registry.register(Monty.Runtime.Registry, {:studio_run, record.id}, :owner)

      on_exit(fn -> Stops.clear(record.id) end)

      assert Jobs.Run.stop(record.id) == :ok

      assert_receive :stop, 1_000
      assert Stops.asked?(record.id), "the flag the tasks read"
    end

    # A divided run's parts may be stepped by peers, where this node's registry
    # cannot see them: `stop/1` casts this to the node each part was given to, and
    # a node that has no such part answers `:not_found` — which is why it is a
    # cast and not a call.
    test "a part on another node is asked to stop by its own stream" do
      stream = Ecto.UUID.generate()

      Registry.register(Monty.Runtime.Registry, {:studio_run, stream}, :starting)

      assert Jobs.Run.stop_part(stream) == :ok
      assert_received :stop

      assert Jobs.Run.stop_part(Ecto.UUID.generate()) == {:error, :not_found}
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

      # The reason names the experiment, so the row says what a person would need
      # to fix. Since a name this node cannot compose is also a question for the
      # cluster (`Monty.Studio.PluginExperiment`), the answer is both halves: no
      # config here and no plugin host that offers one.
      assert {:cancel, why} = perform(record)
      assert why =~ "no/such/experiment"

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
      # A world this build does not carry. No page offers one — the only two are
      # MuJoCo and the stand-in — so this is the guard behind that: an atom that
      # is not a world must fail the record rather than be stepped as one.
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
