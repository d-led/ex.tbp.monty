defmodule Monty.Studio.RunHistoryTest do
  use ExTbpMonty.DataCase, async: false

  alias Monty.Studio.RunHistory

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

    test "cannot be recorded without an experiment" do
      assert {:error, changeset} = RunHistory.start(Map.delete(@attributes, :experiment))
      assert %{experiment: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "a run in progress" do
    test "collects its log one step at a time" do
      {:ok, run} = RunHistory.start(@attributes)

      {:ok, run} = RunHistory.record_step(run, %{"step" => 0, "goals" => 1})
      {:ok, run} = RunHistory.record_step(run, %{"step" => 1, "goals" => 0})

      assert Enum.map(run.log, & &1["step"]) == [0, 1]

      assert RunHistory.get(run.id).log == run.log
    end
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
  end
end
