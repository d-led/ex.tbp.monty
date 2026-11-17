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
          %{"learning_module_0" => part("mug")},
          %{"learning_module_0" => part("bowl")}
        ])

      assert merged["learning_module_0"].memory
             |> GraphMemory.get_memory_ids()
             |> Enum.sort() == [
               "bowl",
               "mug"
             ]
    end

    test "keeps the parts' modules apart, because a heterarchy is several opinions" do
      merged =
        Memories.merge([
          %{"learning_module_0" => part("mug")},
          %{"learning_module_1" => part("bowl")}
        ])

      assert Enum.sort(Map.keys(merged)) == ["learning_module_0", "learning_module_1"]
      assert GraphMemory.get_memory_ids(merged["learning_module_0"].memory) == ["mug"]
      assert GraphMemory.get_memory_ids(merged["learning_module_1"].memory) == ["bowl"]
    end

    test "a graph two parts both trained is the later part's, as Monty's dict update has it" do
      first = part("mug", nodes: 2)
      second = part("mug", nodes: 5)

      merged = Memories.merge([%{"learning_module_0" => first}, %{"learning_module_0" => second}])

      assert GraphMemory.get_num_nodes_in_graph(merged["learning_module_0"].memory, "mug", nil) ==
               5
    end

    test "a part that learned nothing adds nothing" do
      merged = Memories.merge([%{"learning_module_0" => part("mug")}, %{}])

      assert GraphMemory.get_memory_ids(merged["learning_module_0"].memory) == ["mug"]
    end

    test "a merged memory can still be asked for its objects and its rows" do
      # The merge drops each graph's cached rows (`add_graph_to_memory` forgets
      # them), and a memory whose rows were dropped has to rebuild them — a
      # merged model is written, read back and matched against like any other.
      merged =
        Memories.merge([
          %{"learning_module_0" => part("mug")},
          %{"learning_module_0" => part("bowl")}
        ])

      memory = merged["learning_module_0"].memory

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
        assert merged[module].memory |> GraphMemory.get_memory_ids() |> Enum.sort() == [
                 "bowl",
                 "mug"
               ]
      end
    end

    test "is written where the next configuration looks for it", %{libraries: libraries} do
      {:ok, opened} = Monty.Studio.open(@training)
      [%{id: module} | _rest] = opened.setup.learning_modules
      batch = Ecto.UUID.generate()

      assert {:ok, name} = Memories.keep(batch, opened, %{module => part("mug")})
      assert name == Learned.name_for(opened)

      # Both places: the batch's own directory, and the library tree a config
      # that names this model reads.
      assert {:ok, kept} =
               Memory.load_module(name, Learned.release(), 0, Memories.batch_dir(batch))

      assert GraphMemory.get_memory_ids(kept) == ["mug"]

      assert {:ok, filed} = Memory.load_module(name, Learned.release(), 0, libraries)
      assert GraphMemory.get_memory_ids(filed) == ["mug"]
    end

    test "is refused when no part of the batch learnt a graph", %{libraries: libraries} do
      # A wave whose parts all died before an episode, or whose merge is only
      # empty memories, has nothing to file: a library with no record in it would
      # read as a memory that recognises nothing, over the name a real memory is
      # filed under.
      {:ok, opened} = Monty.Studio.open(@training)
      batch = Ecto.UUID.generate()
      [%{id: module} | _rest] = opened.setup.learning_modules

      assert Memories.keep(batch, opened, %{module => %{memory: GraphMemory.new(), targets: %{}}}) ==
               {:error, :nothing_learned}

      assert Memory.releases_for(Learned.name_for(opened), libraries) == []
    end

    # A part's library says what each graph was built from, and a merged library
    # that dropped that would leave a recognition run able to name a graph and not
    # the object it was shown — the same defect §2.27 fixed for a single run,
    # surviving in the path a divided run takes.
    test "keeps the names the parts trained, so the merged memory can be scored", %{
      libraries: libraries
    } do
      {:ok, opened} = Monty.Studio.open(@training)
      [%{id: module} | _rest] = opened.setup.learning_modules
      batch = Ecto.UUID.generate()

      first = Ecto.UUID.generate()
      second = Ecto.UUID.generate()

      # Two parts of an unsupervised training: the graphs are named after nothing
      # anyone can check, and only what the part recorded says which dog each is.
      Learned.keep(
        first,
        opened,
        [{:train, 1}],
        %{module => remembered("new_object0")},
        library: false,
        targets: %{module => %{"new_object0" => ["milka"]}}
      )

      Learned.keep(
        second,
        opened,
        [{:train, 1}],
        %{module => remembered("new_object1")},
        library: false,
        targets: %{module => %{"new_object1" => ["puppy"]}}
      )

      merged = [first, second] |> Memories.learned(opened) |> Memories.merge()

      assert {:ok, name} = Memories.keep(batch, opened, merged)

      assert {:ok, %{targets: targets}} =
               Memory.load_with_targets(name, Learned.release(), 0, libraries)

      assert targets == %{"new_object0" => ["milka"], "new_object1" => ["puppy"]}
    end
  end

  # One part's share of a memory, as a part hands it over: the memory, and what
  # the part said each of its graphs was built from.
  defp part(object_id, options \\ []) do
    %{memory: remembered(object_id, options), targets: %{object_id => [object_id]}}
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
