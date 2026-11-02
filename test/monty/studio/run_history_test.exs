defmodule Monty.Studio.RunHistoryTest do
  use ExTbpMonty.DataCase, async: false

  import Ecto.Query

  alias ExTbpMonty.Repo
  alias Monty.Studio.RunHistory
  alias Monty.Studio.RunHistory.Run

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

      assert run.status == "running"
      assert run.experiment == "tutorial/first_experiment"
      assert run.config["experiment"]["config"]["seed"] == 42
      assert run.inputs["groups"]["monty/learning_module"] == "displacement_1lm"
      assert %DateTime{} = run.started_at
      assert run.finished_at == nil
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
  defp moment(step) do
    %{
      "step" => step,
      "sensors" => %{"patch" => %{"location" => [step * 0.01, 0.0, 0.1], "value" => step * 0.01}}
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

  describe "forgetting a run" do
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
      run = %Run{status: "finished", steps: 500, log: for(n <- 1..22, do: %{"step" => n})}

      assert RunHistory.steps_run(run) == 22
      assert run.steps == 500
    end

    test "counts the episodes it stepped, against the ones it was asked for" do
      run = %Run{
        status: "finished",
        inputs: %{"episodes" => 140},
        log: for(step <- 0..1, episode <- 0..27, do: %{"step" => step, "episode" => episode})
      }

      assert RunHistory.episodes_run(run) == 28
      assert RunHistory.episodes_asked(run) == 140
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
      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1}, moment(0))
      {:ok, run} = RunHistory.record_step(run, %{"step" => 1, "goals" => 0}, moment(1))

      assert RunHistory.sensors_at(run.id, 1)["patch"]["location"] == [0.01, 0.0, 0.1]
      assert RunHistory.sensors_at(run.id, 2) == nil
      assert RunHistory.sensors_at("not-an-id", 0) == nil
      assert RunHistory.head("not-an-id") == nil
    end
  end
end
