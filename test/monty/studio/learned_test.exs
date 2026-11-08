defmodule Monty.Studio.LearnedTest do
  @moduledoc """
  What a run that trained leaves behind — and who gets to leave it.

  Two things run an experiment: the queue's worker and `mix monty.run`. A memory
  only one of them kept was a memory a reader lost by choosing a different door,
  so the writing is one function and both call it.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Studio.Learned
  alias Monty.Test.Tmp

  # A config that trains: five learning modules, so the naming rule for a
  # heterarchy is the one under test, and no model and no run name are not.
  @training "tutorial/dist_agent_5lm_2obj_train"

  setup do
    _root = Tmp.env_dir("studio-learned", :studio_artifacts_dir)
    :ok
  end

  describe "a run that trained" do
    test "keeps one memory per learning module, under the run's own name" do
      {:ok, opened} = Monty.Studio.open(@training)
      run_id = Ecto.UUID.generate()

      assert length(Learned.keep(run_id, opened, [{:train, 14}], memories(opened))) == 5

      files =
        Path.wildcard(Path.join([Learned.dir(run_id), Learned.release(), "*.jsonl.gz"]))
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      assert files == [
               "dist_agent_5lm_2obj_train-learning_module_0.jsonl.gz",
               "dist_agent_5lm_2obj_train-learning_module_1.jsonl.gz",
               "dist_agent_5lm_2obj_train-learning_module_2.jsonl.gz",
               "dist_agent_5lm_2obj_train-learning_module_3.jsonl.gz",
               "dist_agent_5lm_2obj_train-learning_module_4.jsonl.gz"
             ]
    end

    test "says where each memory went, in a line the runner says in its own voice" do
      {:ok, opened} = Monty.Studio.open(@training)
      run_id = Ecto.UUID.generate()

      assert [line | _rest] = Learned.keep(run_id, opened, [{:train, 1}], memories(opened))
      assert line == "the memory learning_module_0 learned is in #{Learned.dir(run_id)}"
    end
  end

  describe "a run that learned nothing to keep" do
    test "is a run that only evaluated" do
      {:ok, opened} = Monty.Studio.open(@training)

      assert Learned.keep(Ecto.UUID.generate(), opened, [{:eval, 3}], memories(opened)) == []
    end

    test "is a run with no record, which has nowhere to put a memory" do
      # `mix monty.run --no-record` is a throwaway run: it writes nothing, and
      # saying nothing is the honest answer rather than a line about a failure.
      {:ok, opened} = Monty.Studio.open(@training)

      assert Learned.keep(nil, opened, [{:train, 1}], memories(opened)) == []
    end

    test "is a module that keeps no graph memory at all" do
      # A config without an evidence model gets a stand-in learning module, and
      # the `shell` finding already says so: writing a file for it would be a
      # library of nothing.
      {:ok, opened} = Monty.Studio.open(@training)

      kept =
        Learned.keep(Ecto.UUID.generate(), opened, [{:train, 1}], %{learning_module_0: :none})

      assert kept == []
    end
  end

  defp memories(opened) do
    Map.new(opened.setup.learning_modules, &{&1.id, GraphMemory.new()})
  end
end
