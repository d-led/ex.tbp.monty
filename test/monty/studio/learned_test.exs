defmodule Monty.Studio.LearnedTest do
  @moduledoc """
  What a run that trained leaves behind — and who gets to leave it.

  Two things run an experiment: the queue's worker and `mix monty.run`. A memory
  only one of them kept was a memory a reader lost by choosing a different door,
  so the writing is one function and both call it.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Studio.{Learned, Memory}
  alias Monty.Test.Tmp

  # A config that trains: five learning modules, so the naming rule for a
  # heterarchy is the one under test, and no model and no run name are not.
  @training "tutorial/dist_agent_5lm_2obj_train"

  setup do
    _root = Tmp.env_dir("studio-learned", :studio_artifacts_dir)
    # Both places a memory is written are temporary: a test that trained into the
    # checkout's own library tree would be a library nobody asked for.
    libraries = Tmp.env_dir("studio-learned-libraries", :monty_libraries_dir)

    {:ok, libraries: libraries}
  end

  describe "a run that trained" do
    test "keeps one library for the model, holding a memory a module" do
      # A heterarchy's model is five memories and one name: a config that reads
      # `…/dist_agent_5lm_2obj_train/pretrained/` asks for the model, and the
      # evaluation config of this tutorial is exactly such a config. Five files
      # named after each module are five libraries nothing asks for.
      {:ok, opened} = Monty.Studio.open(@training)
      run_id = Ecto.UUID.generate()

      assert [line] = Learned.keep(run_id, opened, [{:train, 14}], memories(opened))

      files =
        Path.wildcard(Path.join([Learned.dir(run_id), Learned.release(), "*.jsonl.gz"]))
        |> Enum.map(&Path.basename/1)

      assert files == ["dist_agent_5lm_2obj_train.jsonl.gz"]

      assert line ==
               "the memory 5 modules learned is the library dist_agent_5lm_2obj_train " <>
                 "(trained), in #{Learned.dir(run_id)} and in the libraries"
    end

    test "writes the index of each module, so a module reads back its own memory" do
      {:ok, opened} = Monty.Studio.open(@training)
      run_id = Ecto.UUID.generate()
      [%{id: first}, %{id: second} | _rest] = opened.setup.learning_modules

      kept =
        memories(opened)
        |> Map.put(first, remembered("mug"))
        |> Map.put(second, remembered("bowl"))

      Learned.keep(run_id, opened, [{:train, 1}], kept)

      name = "dist_agent_5lm_2obj_train"

      assert {:ok, first_memory} =
               Memory.load_module(name, Learned.release(), 0, Learned.dir(run_id))

      assert {:ok, second_memory} =
               Memory.load_module(name, Learned.release(), 1, Learned.dir(run_id))

      assert GraphMemory.get_memory_ids(first_memory) == ["mug"]
      assert GraphMemory.get_memory_ids(second_memory) == ["bowl"]
    end

    test "files it where a config that reads the memory will find it", %{libraries: libraries} do
      # The point of a training run is the run after it: an evaluation config that
      # names this memory asks `Memory.load_module/3`, which reads the library
      # tree. A memory kept only in the run's own directory is a memory nothing
      # finds, so "train it" would train for nothing.
      {:ok, opened} = Monty.Studio.open(@training)
      run_id = Ecto.UUID.generate()

      # What a training episode leaves: every module knows the objects it saw.
      learned =
        opened.setup.learning_modules
        |> Enum.with_index(fn module, index -> {module.id, remembered("object_#{index}")} end)
        |> Map.new()

      Learned.keep(run_id, opened, [{:train, 1}], learned)

      name = "dist_agent_5lm_2obj_train"

      assert Memory.releases_for(name, libraries) == [Learned.release()]
      assert Memory.modules(name, Learned.release(), libraries) == 5

      for index <- 0..4 do
        assert {:ok, memory} = Memory.load_module(name, Learned.release(), index, libraries)
        assert GraphMemory.get_memory_ids(memory) == ["object_#{index}"]
      end
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

  # A memory that knows one object, so which module a record belongs to is
  # readable from what the file holds.
  defp remembered(object_id) do
    positions = [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0]]
    {:ok, model} = GraphObjectModel.build_model(GraphObjectModel.new(object_id), positions, %{})

    GraphMemory.add_graph_to_memory(GraphMemory.new(), %{"rgba" => model}, object_id)
  end
end
