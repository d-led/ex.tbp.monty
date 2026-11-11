defmodule Monty.Studio.MemoriesTest do
  @moduledoc """
  What a parallel training run leaves behind: one memory, from parts that each
  learned a share of it.

  Monty's `load_state_dict_from_parallel` is the reference: per module, every
  part's graphs are loaded over what came before. These cases say that the merge
  is that — the union, no graph lost, and a graph two parts both trained decided
  the way Monty decides it.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Studio.{Learned, Memories, Memory}
  alias Monty.Test.Tmp

  # Two objects trained in three rotations: two parts, one object each.
  @training "tutorial/dist_agent_5lm_2obj_train"

  setup do
    _root = Tmp.env_dir("studio-memories", :studio_artifacts_dir)
    {:ok, libraries: Tmp.env_dir("studio-memories-libraries", :monty_libraries_dir)}
  end

  describe "putting the parts back together" do
    test "is the union of what the parts learned, module by module" do
      merged =
        Memories.merge([
          %{"learning_module_0" => remembered("mug")},
          %{"learning_module_0" => remembered("bowl")}
        ])

      assert merged["learning_module_0"] |> GraphMemory.get_memory_ids() |> Enum.sort() == [
               "bowl",
               "mug"
             ]
    end

    test "keeps the parts' modules apart, because a heterarchy is several opinions" do
      merged =
        Memories.merge([
          %{"learning_module_0" => remembered("mug")},
          %{"learning_module_1" => remembered("bowl")}
        ])

      assert Enum.sort(Map.keys(merged)) == ["learning_module_0", "learning_module_1"]
      assert GraphMemory.get_memory_ids(merged["learning_module_0"]) == ["mug"]
      assert GraphMemory.get_memory_ids(merged["learning_module_1"]) == ["bowl"]
    end

    test "a graph two parts both trained is the later part's, as Monty's dict update has it" do
      first = remembered("mug", nodes: 2)
      second = remembered("mug", nodes: 5)

      merged = Memories.merge([%{"learning_module_0" => first}, %{"learning_module_0" => second}])

      assert GraphMemory.get_num_nodes_in_graph(merged["learning_module_0"], "mug", nil) == 5
    end

    test "a part that learned nothing adds nothing" do
      merged = Memories.merge([%{"learning_module_0" => remembered("mug")}, %{}])

      assert GraphMemory.get_memory_ids(merged["learning_module_0"]) == ["mug"]
    end

    test "a merged memory can still be asked for its objects and its rows" do
      # The merge drops each graph's cached rows (`add_graph_to_memory` forgets
      # them), and a memory whose rows were dropped has to rebuild them — a
      # merged model is written, read back and matched against like any other.
      merged =
        Memories.merge([
          %{"learning_module_0" => remembered("mug")},
          %{"learning_module_0" => remembered("bowl")}
        ])

      memory = merged["learning_module_0"]

      assert GraphMemory.size(memory) == 2

      for graph_id <- ["mug", "bowl"] do
        assert length(GraphMemory.get_locations_in_graph(memory, graph_id, "rgba")) == 2
      end
    end
  end

  describe "a batch's memory" do
    test "is read from what each part wrote in its own directory", %{libraries: libraries} do
      {:ok, opened} = Monty.Studio.open(@training)
      [%{id: first_module}, %{id: second_module} | _rest] = opened.setup.learning_modules

      first = Ecto.UUID.generate()
      second = Ecto.UUID.generate()

      # Two parts, each of which trained one object. A part's memory is kept in
      # its own directory, so what a merge reads is what the run itself wrote.
      Learned.keep(
        first,
        opened,
        [{:train, 1}],
        %{first_module => remembered("mug"), second_module => remembered("mug")},
        library: false
      )

      Learned.keep(
        second,
        opened,
        [{:train, 1}],
        %{first_module => remembered("bowl"), second_module => remembered("bowl")},
        library: false
      )

      assert Memory.releases_for(Learned.name_for(opened), libraries) == []

      learned = Memories.learned([first, second], opened)
      merged = Memories.merge(learned)

      for module <- [first_module, second_module] do
        assert merged[module] |> GraphMemory.get_memory_ids() |> Enum.sort() == ["bowl", "mug"]
      end
    end

    test "is written where the next configuration looks for it", %{libraries: libraries} do
      {:ok, opened} = Monty.Studio.open(@training)
      [%{id: module} | _rest] = opened.setup.learning_modules
      batch = Ecto.UUID.generate()

      assert {:ok, name} = Memories.keep(batch, opened, %{module => remembered("mug")})
      assert name == Learned.name_for(opened)

      # Both places: the batch's own directory, and the library tree a config
      # that names this model reads.
      assert {:ok, kept} =
               Memory.load_module(name, Learned.release(), 0, Memories.batch_dir(batch))

      assert GraphMemory.get_memory_ids(kept) == ["mug"]

      assert {:ok, filed} = Memory.load_module(name, Learned.release(), 0, libraries)
      assert GraphMemory.get_memory_ids(filed) == ["mug"]
    end
  end

  # A memory that knows one object: which part a graph came from is readable from
  # the graph id, and how many nodes it has is what "the later part wins" needs.
  defp remembered(object_id, options \\ []) do
    nodes = Keyword.get(options, :nodes, 2)
    positions = for index <- 1..nodes, do: [index * 0.01, 0.0, 0.0]
    {:ok, model} = GraphObjectModel.build_model(GraphObjectModel.new(object_id), positions, %{})

    GraphMemory.add_graph_to_memory(GraphMemory.new(), %{"rgba" => model}, object_id)
  end
end
