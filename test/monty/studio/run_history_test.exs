defmodule Monty.Studio.RunHistoryTest do
  use ExTbpMonty.DataCase, async: false

  import Ecto.Query

  alias ExTbpMonty.Repo
  alias Monty.Studio.{Artifacts, RunHistory, RunLog}
  alias Monty.Studio.RunHistory.Run
  alias Monty.Test.Tmp

  @attributes %{
    experiment: "tutorial/first_experiment",
    source: "monty",
    steps: 3,
    seed: 42,
    config: %{"experiment" => %{"config" => %{"seed" => 42}}},
    inputs: %{"groups" => %{"monty/learning_module" => "displacement_1lm"}, "seed" => 42}
  }

  describe "a run that starts" do
    test "is history immediately, with the config and the inputs that produced it" do
      assert {:ok, run} = RunHistory.start(@attributes)

      # Asked for, not stepped: a record says `queued` until a worker claims it.
      assert run.status == "queued"
      assert run.experiment == "tutorial/first_experiment"
      assert run.config["experiment"]["config"]["seed"] == 42
      assert run.inputs["groups"]["monty/learning_module"] == "displacement_1lm"
      assert %DateTime{} = run.started_at
      assert run.finished_at == nil
    end

    test "says running only when a worker claims it" do
      # Asking for a run is not running it: the job may wait for a slot, or never
      # be picked up. The two words are the difference between "somebody asked
      # for this" and "somebody is working on it", and a page draws both.
      {:ok, queued} = RunHistory.start(@attributes)

      assert RunHistory.get(queued.id).status == "queued"
      assert RunHistory.in_flight?(queued)

      {:ok, began} = RunHistory.mark_running(queued)

      assert began.status == "running"
      assert RunHistory.get(queued.id).status == "running"

      # Asking twice is not an error, and not a second start.
      assert {:ok, ^began} = RunHistory.mark_running(began)
    end

    test "is one episode, and says which" do
      assert {:ok, run} = RunHistory.start(@attributes)
      assert run.episode == 0

      assert {:ok, third} = RunHistory.start(Map.put(@attributes, :episode, 3))
      assert third.episode == 3
    end

    test "the run of one episode is found without finding another's" do
      {:ok, first} = RunHistory.start(Map.put(@attributes, :episode, 0))
      {:ok, second} = RunHistory.start(Map.put(@attributes, :episode, 1))

      assert RunHistory.running_for("tutorial/first_experiment", 1).id == second.id
      assert RunHistory.running_for("tutorial/first_experiment", 0).id == first.id
      assert RunHistory.running_for("tutorial/first_experiment", 2) == nil
    end

    test "cannot be recorded without an experiment" do
      assert {:error, changeset} = RunHistory.start(Map.delete(@attributes, :experiment))
      assert %{experiment: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "a run in progress" do
    test "collects its log, and what each step saw, one step at a time" do
      {:ok, run} = RunHistory.start(@attributes)

      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))
      {:ok, run} = RunHistory.record_step(run, %{"step" => 1, "goals" => 0}, moment(1))

      assert Enum.map(run.log, & &1["step"]) == [0, 1]
      assert Enum.map(run.timeline, & &1["step"]) == [0, 1]

      recorded = RunHistory.get(run.id)
      assert recorded.log == run.log
      assert recorded.timeline == run.timeline
    end

    test "collects a step's log and its timeline together, or neither" do
      {:ok, run} = RunHistory.start(@attributes)

      # A log that says step 4 happened while the timeline is still at 3 would
      # be a replay that disagrees with itself.
      assert length(run.log) == length(run.timeline)
    end
  end

  describe "a run that steps faster than it is worth writing" do
    test "holds an appended step until the run checkpoints" do
      # Writing the whole log per step made a step cost grow with the run: a
      # 300-step run paid 0.6–1.4 s per step for 3 MB it had already written.
      {:ok, run} = RunHistory.start(@attributes)

      stepped =
        run
        |> RunHistory.append_step(%{"step" => 0, "goals" => 1}, moment(0))
        |> RunHistory.append_step(%{"step" => 1, "goals" => 0}, moment(1))

      assert Enum.map(stepped.log, & &1["step"]) == [0, 1]
      assert RunHistory.get(run.id).log == []

      assert {:ok, saved} = RunHistory.checkpoint(stepped)
      assert Enum.map(RunHistory.get(run.id).log, & &1["step"]) == [0, 1]
      assert saved.log == RunHistory.get(run.id).log
    end

    test "adds what came after what the row already holds" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))

      # The second write carries one step, not the two the record holds: a
      # transcript that is written whole grows with the run, so the steps the
      # row has are left where they are.
      stepped =
        run
        |> RunHistory.append_step(%{"step" => 1, "goals" => 0}, moment(1))
        |> RunHistory.append_step(%{"step" => 2, "goals" => 0}, moment(2))

      assert {:ok, saved} = RunHistory.checkpoint(stepped)
      assert saved.steps_done == 3
      assert Enum.map(RunHistory.get(run.id).log, & &1["step"]) == [0, 1, 2]
    end

    test "does not write the same step twice" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, once} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))

      # What the row holds is what the record says it holds, so a second
      # checkpoint of the same record has nothing to add.
      assert {:ok, _twice} = RunHistory.checkpoint(once)
      assert Enum.map(RunHistory.get(run.id).log, & &1["step"]) == [0]
      assert Enum.map(RunHistory.get(run.id).timeline, & &1["step"]) == [0]
    end

    test "a checkpoint with nothing new writes nothing" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, once} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))
      written_at = RunHistory.get(run.id).updated_at

      assert {:ok, _nothing} = RunHistory.checkpoint(once)
      assert RunHistory.get(run.id).updated_at == written_at
    end

    test "a boundary writes the transcript, and the pictures wait for the settle" do
      # Appending to a `jsonb` array rewrites the whole array: an *empty* append to
      # a 24 329-step row took 14.7 s, and a run of 140 episodes paid it 140 times.
      # A boundary writes the transcript; the pictures are five times its size and
      # are written once, when the run settles.
      {:ok, run} = RunHistory.start(@attributes)
      steps = [%{"step" => 0, "episode" => 0}, %{"step" => 1, "episode" => 0}]
      moments = [moment(0), moment(1)]

      assert {:ok, saved} =
               RunHistory.checkpoint_steps(run, steps, moments, timeline: :skip)

      assert saved.steps_done == 2
      assert Enum.map(RunHistory.get(run.id).log, & &1["step"]) == [0, 1]
      assert RunHistory.get(run.id).timeline == []

      assert {:ok, settled} = RunHistory.store(saved, steps, moments)
      assert Enum.map(RunHistory.get(run.id).timeline, & &1["step"]) == [0, 1]
      assert settled.steps_done == 2
    end

    test "reads the steps the row does not have, and not the ones it does" do
      # A boundary asks the stream for what it has not written yet. Asking for the
      # whole run to throw most of it away is the copy the stream's positions
      # exist to avoid.
      {:ok, run} = RunHistory.start(@attributes)
      Enum.each(0..4, &publish(run.id, &1))

      {log, moments} = Monty.Studio.RunStream.steps(run.id)
      assert Enum.map(log, & &1["step"]) == [0, 1, 2, 3, 4]
      assert Enum.map(moments, & &1["step"]) == [0, 1, 2, 3, 4]

      {after_the_first, _moments} = Monty.Studio.RunStream.steps_from(run.id, 1)
      assert Enum.map(after_the_first, & &1["step"]) == [2, 3, 4]
      assert Monty.Studio.RunStream.count(run.id) == 5
    end

    # An experiment page polled the whole record twice a second: 252 MB per
    test "a page's poll reads the row without its transcript" do
      # request by the end of a twenty-thousand-step run, while the run was trying
      # to step. What a poll needs is the state and the counters.
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))

      polled = RunHistory.progress(run.id)

      assert polled.status == "running"
      assert polled.steps_done == 1
      assert polled.log == []
      assert polled.timeline == []
      assert Enum.map(RunHistory.head(run.id).log, & &1["step"]) == [0]
    end

    # The desktop build's record is SQLite, which has no `||` over the column the
    # transcript lives in: a boundary rewrites the row whole. So what it already
    # holds has to travel with the batch, or every boundary after the first would
    # drop the steps before it — a run's history quietly shrinking to its last
    # episode. Nothing else in the suite takes this path.
    test "an adapter that cannot append writes the whole transcript" do
      {:ok, run} = RunHistory.start(@attributes)

      first = [%{"step" => 0, "episode" => 0}, %{"step" => 1, "episode" => 0}]

      {:ok, saved} =
        RunHistory.checkpoint_steps(run, first, [moment(0), moment(1)],
          append: false,
          timeline: :skip
        )

      {later, later_moments} = {[%{"step" => 2, "episode" => 0}], [moment(2)]}

      {:ok, _saved} =
        RunHistory.checkpoint_steps(saved, later, later_moments,
          append: false,
          timeline: :skip
        )

      assert Enum.map(RunHistory.get(run.id).log, & &1["step"]) == [0, 1, 2]
      assert RunHistory.get(run.id).steps_done == 3
    end

    test "a boundary on an adapter that cannot append leaves the pictures where they were" do
      # The pictures are the row's bulk — 42 MB by the end of a five-thousand-step
      # run — and a boundary is not where they are written: `store/3` is, once.
      # The append-only path leaves them alone by assigning the column to itself;
      # an adapter that has to rewrite the row was handing them back unchanged,
      # and on SQLite that was 185 of a boundary's 230 ms.
      {:ok, run} = RunHistory.start(@attributes)

      {:ok, saved} =
        RunHistory.checkpoint_steps(run, [%{"step" => 0, "episode" => 0}], [moment(0)],
          append: false
        )

      {:ok, _saved} =
        RunHistory.checkpoint_steps(saved, [%{"step" => 1, "episode" => 0}], [moment(1)],
          append: false,
          timeline: :skip
        )

      written = RunHistory.get(run.id)
      assert Enum.map(written.log, & &1["step"]) == [0, 1]
      assert Enum.map(written.timeline, & &1["step"]) == [0]
    end

    test "a run closed without its worker still has the steps it took" do
      {:ok, run} = RunHistory.start(@attributes)

      # A page's "End now" kills the worker, and the row it would have written is
      # never written. The steps it took are in memory, so whoever closes the run
      # writes them: a record saying "0 steps" about a run that stepped is a
      # record that lost them.
      publish(run.id, 0)
      publish(run.id, 1)
      _ = :sys.get_state(Monty.Studio.RunStream)

      assert {:ok, kept} = RunHistory.keep_streamed(RunHistory.head(run.id))

      assert Enum.map(RunHistory.get(run.id).log, & &1["step"]) == [0, 1]
      assert kept.steps_done == 2
      assert Monty.Studio.RunStream.steps(run.id) == {[], []}
    end

    test "says it is being stepped without writing its log" do
      # Between checkpoints the row is silent, and silence is what an abandoned
      # run also looks like.
      {:ok, run} = RunHistory.start(@attributes)
      :ok = quiet_since(run, 300)

      assert RunHistory.quiet_for(RunHistory.get(run.id)) > 299

      assert RunHistory.alive(run) == :ok

      assert RunHistory.quiet_for(RunHistory.get(run.id)) < 5
      assert RunHistory.get(run.id).log == []
    end

    test "speaks at most once every ten seconds, so a step is not a write" do
      {:ok, run} = RunHistory.start(@attributes)
      :ok = quiet_since(run, 300)

      # The first step of a run has never said anything, so it does; the next
      # ones carry the beat they were given, and a beat inside the ten seconds
      # is not another write — a write per step is what streaming the transcript
      # was doing.
      beat = RunHistory.heartbeat(run, nil)
      assert is_integer(beat)

      # The beat is a message to the writer, not a write: wait for the writer to
      # have handled it before asking the row (`AGENTS.md`: no sleeping).
      _ = :sys.get_state(Monty.Studio.RunWriter)
      assert RunHistory.quiet_for(RunHistory.get(run.id)) < 5

      :ok = quiet_since(run, 300)

      assert RunHistory.heartbeat(run, beat) == beat

      assert RunHistory.quiet_for(RunHistory.get(run.id)) > 299
    end

    test "a run with no record has nothing to say" do
      # `mix monty.run` without `--record` steps an experiment with no row at
      # all: there is nobody to tell, and the beat it carries is unchanged.
      assert RunHistory.heartbeat(nil, nil) == nil
      assert RunHistory.heartbeat(nil, 42) == 42
    end
  end

  # A run whose row has said nothing for a while: a step was being taken.
  defp quiet_since(record, seconds) do
    updated_at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    {1, nil} =
      Repo.update_all(from(run in Run, where: run.id == ^record.id),
        set: [updated_at: updated_at]
      )

    :ok
  end

  # A step's moment: what the sensors were looking at, in Monty's units.
  describe "a step's pictures" do
    # Where a step's pictures live is the question that put a twenty-two-
    # thousand-step run past Postgres's jsonb ceiling: ten kilobytes a step of
    # PNG inside the record is not a record. They are files of the run's own
    # directory, and the row names them.
    setup do
      Tmp.env_dir("studio-frames", :studio_artifacts_dir)
      :ok
    end

    test "are files of the run, named by the row rather than carried in it" do
      {:ok, run} = RunHistory.start(@attributes)

      # A MuJoCo step: keyed by sensor, not wrapped in the agent that holds it.
      RunLog.record_step(run, step(5), %{
        "patch_0" => %{
          "depth" => [[0.05, 0.05], [0.05, 0.05]],
          "rgba" => [[[0.2, 0.7, 0.2, 1.0], [0.2, 0.7, 0.2, 1.0]]]
        }
      })

      %{"patch_0" => %{"images" => images}} = RunHistory.sensors_at(run.id, 0)

      assert images["depth"] == "/runs/#{run.id}/frames/5/patch_0-depth.png"
      assert images["colour"] == "/runs/#{run.id}/frames/5/patch_0-colour.png"

      assert {:ok, path} = Artifacts.frame_path(run.id, "5/patch_0-depth.png")
      assert <<137, 80, 78, 71, _rest::binary>> = File.read!(path)
    end

    test "go with the run, so a deleted run leaves nothing behind" do
      {:ok, run} = RunHistory.start(@attributes)
      RunLog.record_step(run, step(1), %{"patch_0" => %{"depth" => [[0.05]]}})

      assert {:ok, path} = Artifacts.frame_path(run.id, "1/patch_0-depth.png")
      assert File.exists?(path)

      {:ok, _deleted} = RunHistory.delete(run)

      refute File.exists?(path)
      assert Artifacts.frame_path(run.id, "1/patch_0-depth.png") == :error
    end
  end

  defp step(number) do
    %{
      step: number,
      percept_ids: [:patch],
      inputs: %{lm_0: 1},
      votes: %{sent: 1, used: 1},
      goals: 1,
      actions: [],
      duration_us: 1
    }
  end

  defp moment(step) do
    %{
      "step" => step,
      "sensors" => %{"patch" => %{"location" => [step * 0.01, 0.0, 0.1], "value" => step * 0.01}}
    }
  end

  # A step handed to the stream, the way a worker hands one over. The entry the
  # row keeps and the line the log prints are the stream's to derive
  # (`RunStream.handle_cast/2`), so what a step hands over is what it reported and
  # what its sensors saw.
  defp publish(run_id, step) do
    Monty.Studio.RunStream.publish(run_id, %{
      info: report(step),
      at: Monty.Studio.RunLog.now().instant,
      episode: 0,
      beliefs: %{},
      observations: %{},
      sensor_ids: [],
      centre: nil
    })
  end

  defp report(step) do
    %{
      step: step,
      percept_ids: [:patch],
      inputs: %{learning_module_0: 1},
      votes: %{sent: 1, used: 1},
      goals: 0,
      actions: [:turn_left],
      duration_us: 140
    }
  end

  describe "a run that ends" do
    test "records how it ended, when, and how long it took" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.finish(run, %{"steps" => 3, "votes_used" => 2})

      assert run.status == "finished"
      assert run.summary["votes_used"] == 2
      assert %DateTime{} = run.finished_at
      assert run.duration_us >= 0
    end

    test "can also end badly" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.finish(run, %{"error" => "boom"}, "failed")

      assert run.status == "failed"
    end

    test "tells a watching page the row, not the pictures the run kept" do
      # Every subscriber takes its own copy, and a settled run of thousands of
      # steps carries tens of megabytes of timeline that no row looks at.
      :ok = RunHistory.subscribe()

      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))
      {:ok, run} = RunHistory.finish(run, %{"steps" => 1})

      assert_receive {:settled, %Run{} = told}
      assert told.status == "finished"
      assert told.log == run.log
      assert told.timeline == []
    end
  end

  describe "the list" do
    test "shows the newest run first" do
      {:ok, first} = RunHistory.start(%{@attributes | experiment: "one"})
      {:ok, second} = RunHistory.start(%{@attributes | experiment: "two"})

      assert [newest | _rest] = RunHistory.list() |> Enum.map(& &1.id)
      assert newest == second.id
      assert first.id in Enum.map(RunHistory.list(), & &1.id)
    end

    test "can be narrowed to one experiment" do
      {:ok, _run} = RunHistory.start(%{@attributes | experiment: "one"})
      {:ok, _run} = RunHistory.start(%{@attributes | experiment: "two"})

      assert [%{experiment: "one"}] = RunHistory.list_for("one")
    end
  end

  describe "deleting a run" do
    test "deletes the record and nothing else" do
      {:ok, run} = RunHistory.start(@attributes)

      assert {:ok, _deleted} = RunHistory.delete(run)
      assert RunHistory.get(run.id) == nil
    end

    test "the runs with these ids, and no others" do
      {:ok, first} = RunHistory.start(%{@attributes | experiment: "one"})
      {:ok, second} = RunHistory.start(%{@attributes | experiment: "two"})
      {:ok, kept} = RunHistory.start(%{@attributes | experiment: "three"})

      assert RunHistory.delete_ids([first.id, second.id, "no-such-run"]) == 2

      assert RunHistory.get(first.id) == nil
      assert RunHistory.get(second.id) == nil
      assert RunHistory.get(kept.id) != nil
    end

    test "says how far it has got, so a page can show the deletion happening" do
      {:ok, first} = RunHistory.start(%{@attributes | experiment: "one"})
      {:ok, second} = RunHistory.start(%{@attributes | experiment: "two"})

      test_process = self()

      RunHistory.delete_ids([first.id, second.id],
        on_progress: fn progress -> send(test_process, {:deleted, progress}) end
      )

      assert_receive {:deleted, %{deleted: 2, total: 2}}
    end

    test "every run a filter shows, and no others" do
      {:ok, tutorial} = RunHistory.start(@attributes)
      {:ok, dist} = RunHistory.start(%{@attributes | experiment: "base_dist"})
      {:ok, surf} = RunHistory.start(%{@attributes | experiment: "base_surf"})
      {:ok, surf} = RunHistory.finish(surf, %{}, "finished")

      assert RunHistory.delete_matching(state: "running", text: "base") == 1

      assert RunHistory.get(dist.id) == nil
      assert RunHistory.get(surf.id) != nil
      assert RunHistory.get(tutorial.id) != nil
    end
  end

  # A run writes its record on every step, so a page that shows a run "running"
  # with no step for a long time is showing something that has stopped
  # progressing. That is not the reaper's question — it asks whether a process is
  # working on the run at all — and it is not the same as a slow step, which is
  # why the threshold is minutes rather than seconds.
  describe "what a run actually did" do
    test "counts the steps it took, not the budget it was allowed" do
      # The column says 500 because that is what an episode may use; the run
      # recognised its object at step 22 and stopped.
      {:ok, run} = RunHistory.start(Map.put(@attributes, :steps, 500))

      run =
        Enum.reduce(1..22, run, fn step, run ->
          {:ok, run} =
            RunHistory.record_step(run, %{"step" => step, "episode" => 0}, moment(step))

          run
        end)

      recorded = RunHistory.head(run.id)

      assert RunHistory.steps_run(recorded) == 22
      assert recorded.steps == 500
    end

    test "counts the episodes it stepped, against the ones it was asked for" do
      {:ok, run} = RunHistory.start(Map.put(@attributes, :inputs, %{"episodes" => 140}))

      run =
        Enum.reduce(0..27, run, fn episode, run ->
          {:ok, run} =
            RunHistory.record_step(run, %{"step" => 0, "episode" => episode}, moment(episode))

          run
        end)

      recorded = RunHistory.head(run.id)

      assert RunHistory.episodes_run(recorded) == 28
      assert RunHistory.episodes_asked(recorded) == 140
    end

    test "says a record that was not asked for a scope does not know one" do
      assert RunHistory.episodes_asked(%Run{inputs: %{}}) == nil
    end

    test "a run that recognised its object ends as a recognition" do
      run = %Run{
        status: "finished",
        summary: %{"steps" => 22, "outcome" => %{"learning_module_0" => "match"}}
      }

      assert RunHistory.ending(run) == "recognised"
    end

    test "a run whose modules said no is not a recognition" do
      run = %Run{
        status: "finished",
        summary: %{"steps" => 500, "outcome" => %{"learning_module_0" => "no_match"}}
      }

      assert RunHistory.ending(run) == "no match"
    end

    test "a run that used its budget without concluding ends out of steps" do
      run = %Run{status: "finished", summary: %{"steps" => 500, "outcome" => %{}}}

      assert RunHistory.ending(run) == "out of steps"
    end

    test "an abandoned run ends as abandoned, and a running one has not ended" do
      abandoned = %Run{status: "failed", summary: %{"reason" => "it stopped before it finished"}}
      running = %Run{status: "running", summary: %{}}

      assert RunHistory.ending(abandoned) == "abandoned"
      assert RunHistory.ending(running) == nil
    end
  end

  describe "a run that has gone quiet" do
    test "is not stalled while its steps keep landing" do
      run = %Run{status: "running", updated_at: DateTime.utc_now()}

      refute RunHistory.stalled?(run)
    end

    test "is stalled once nothing has been recorded for a minute" do
      run = %Run{status: "running", updated_at: DateTime.utc_now()}

      assert RunHistory.stalled?(run, DateTime.add(DateTime.utc_now(), 61, :second))
    end

    test "is not given longer because it has been running longer" do
      now = DateTime.utc_now()

      # Twenty-five seconds a step, half an hour into a 140-episode run: a
      # deadline projected from that total would wait minutes before doubting
      # it. What is asked is whether anything new arrived, and the answer is no.
      run = %Run{
        status: "running",
        steps: 500,
        started_at: DateTime.add(now, -1800, :second),
        updated_at: DateTime.add(now, -74, :second)
      }

      assert RunHistory.stalled?(run, now)
    end

    test "says how long it has been quiet" do
      run = %Run{status: "running", updated_at: DateTime.utc_now()}

      assert RunHistory.quiet_for(run, DateTime.add(DateTime.utc_now(), 90, :second)) == 90
    end

    test "a run that has finished is not stalled, however old it is" do
      run = %Run{
        status: "finished",
        updated_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
      }

      refute RunHistory.stalled?(run)
    end
  end

  describe "a run read for a page" do
    test "comes back without the pictures its steps kept" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))
      {:ok, run} = RunHistory.record_step(run, %{"step" => 1, "goals" => 0}, moment(1))
      head = RunHistory.head(run.id)

      # The log is what a page reads on every step and the observations are what
      # it asks for one step at a time: a run of a thousand steps carries eleven
      # kilobytes of picture per step, and a page that read them all spent longer
      # decoding the record than the run spent stepping.
      assert head.log == run.log
      assert head.timeline == []
      assert head.status == "running"
      assert head.config == run.config
    end

    test "answers with the observations of one step, and nothing where there was no step" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))
      {:ok, run} = RunHistory.record_step(run, %{"step" => 1, "goals" => 0}, moment(1))

      assert RunHistory.sensors_at(run.id, 1)["patch"]["location"] == [0.01, 0.0, 0.1]
      assert RunHistory.sensors_at(run.id, 2) == nil
      assert RunHistory.sensors_at("not-an-id", 0) == nil
      assert RunHistory.head("not-an-id") == nil
    end

    test "and neither does a page of them" do
      # The list is what `/runs` asks for, and one page of twenty-five runs
      # used to be every picture of every one of them: 156 MB across this
      # machine's seventy-seven runs, and a page that timed out its connection.
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, _stepped} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))

      page = RunHistory.search().runs

      assert Enum.all?(page ++ RunHistory.list(), &(&1.timeline == []))
      assert %Run{timeline: [], log: []} = Enum.find(page, &(&1.id == run.id))
    end

    test "a page of runs still says how many steps each one took" do
      # The count is a column, written as the steps are: the alternative is
      # counting the log of every run on the page, which is what made a page
      # cost grow with its runs' transcripts.
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))
      {:ok, _run} = RunHistory.record_step(run, %{"step" => 1, "goals" => 0}, moment(1))

      row = Enum.find(RunHistory.search().runs, &(&1.id == run.id))

      assert row.steps_done == 2
      assert row.log == []
    end

    test "a table's row carries neither the pictures nor the transcript" do
      # What a list draws is which run it is, how it ended and what it cost. The
      # transcript is read when somebody opens the run, and fifty of them is
      # fifty logs nobody asked for.
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, _stepped} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))

      row = Enum.find(RunHistory.list(), &(&1.id == run.id))

      assert row.status == "running"
      assert row.steps == run.steps
      assert row.steps_done == 1
      assert row.log == []
      assert row.timeline == []
    end

    test "the run a page should watch comes without its pictures, and with its log" do
      # `running_for/2` is asked on every poll of a page that is not watching a
      # run, so it is the one read that must never carry the observations; the
      # progress it reports is counted from the log.
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.mark_running(run)
      {:ok, _stepped} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))

      watched = RunHistory.running_for(run.experiment)

      assert watched.id == run.id
      assert length(watched.log) == 1
      assert watched.timeline == []
      assert watched.inputs == run.inputs
    end

    test "whether a run is there is answered without reading it" do
      {:ok, run} = RunHistory.start(@attributes)

      assert RunHistory.exists?(run.id)
      refute RunHistory.exists?(Ecto.UUID.generate())
      # Neither is a run at all, and neither is worth an error page.
      refute RunHistory.exists?("not-an-id")
    end
  end
end
