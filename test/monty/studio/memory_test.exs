defmodule Monty.Studio.MemoryTest do
  @moduledoc """
  A run's memory: Monty's pretrained graphs, and what a run says when there are
  none.

  The libraries are exports of Monty's own models (`priv/monty/libraries/README.md`
  says which release each came from), so the questions that matter are: does a
  config that names a model and a release get *that* memory, and does a config
  whose memory is missing or from another release say so rather than quietly
  recognising with something else.
  """

  use ExTbpMontyWeb.ConnCase, async: true

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Studio.{Catalog, Learned, Memory, Setup}
  alias Monty.Test.Tmp

  @experiment "base_config_10distinctobj_dist_agent"

  defp monty_path(release, model), do: "/models/#{release}/#{model}/pretrained/"

  describe "reading a config's model name" do
    test "is the model's own directory" do
      path = monty_path("pretrained_ycb_v10", "surf_agent_1lm_10distinctobj")

      assert Memory.name_of(path) == "surf_agent_1lm_10distinctobj"
    end

    test "names the release the model sits in" do
      path = monty_path("pretrained_ycb_v10", "surf_agent_1lm_10distinctobj")

      assert Memory.release_of(path) == "pretrained_ycb_v10"
    end

    test "is the directory the model sits in, which is how Monty lays its models out" do
      path = "/models/pretrained_ycb_v13/surf_agent_1lm_10similarobj/pretrained/"

      assert Memory.release_of(path) == "pretrained_ycb_v13"
    end

    test "is unknown for a path that is only a model name" do
      assert Memory.release_of("surf_agent_1lm_10distinctobj") == nil
    end
  end

  describe "the library a config names" do
    test "is found by model and release, and carries every object Monty trained" do
      name = "surf_agent_1lm_10distinctobj"
      release = "pretrained_ycb_v10"

      assert Memory.available?(name, release)

      {:ok, memory} = Memory.load(name, release)

      assert memory.models_in_memory |> Map.keys() |> Enum.sort() ==
               ~w(banana bowl c_lego_duplo dice golf_ball mug mustard_bottle
                  potted_meat_can spoon strawberry)
    end

    test "is found in every release that exported it, and in no other" do
      # Discovery is a question about a directory, so it is asked of one the test
      # builds: which releases a machine happens to have exported says nothing
      # about the lookup.
      dir = Tmp.dir("libraries")
      export!(dir, "pretrained_ycb_v10", "surf_agent_1lm_10distinctobj")
      export!(dir, "pretrained_ycb_v13", "surf_agent_1lm_10distinctobj")
      export!(dir, "pretrained_ycb_v13", "surf_agent_1lm_10similarobj")

      assert Memory.releases_for("surf_agent_1lm_10distinctobj", dir) ==
               ["pretrained_ycb_v10", "pretrained_ycb_v13"]

      assert Memory.releases_for("surf_agent_1lm_10similarobj", dir) == ["pretrained_ycb_v13"]
      assert Memory.releases_for("a_model_nobody_exported", dir) == []
    end

    test "is not the same memory as another release's, so another release is not a match" do
      refute Memory.available?("surf_agent_1lm_10distinctobj", "pretrained_ycb_v99")

      assert Memory.load("surf_agent_1lm_10distinctobj", "pretrained_ycb_v99") ==
               {:error, :not_found}
    end

    test "is not found for a model nobody exported" do
      refute Memory.available?("a_model_nobody_exported", "pretrained_ycb_v10")

      assert Memory.load("a_model_nobody_exported", "pretrained_ycb_v10") ==
               {:error, :not_found}
    end
  end

  describe "a run of an experiment that names a model" do
    test "gets the memory the config names, in its learning module, and is not warned about it" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      # The config names `pretrained_ycb_v14`, and the repository ships that
      # release's export of the model — so a first run of this experiment has
      # nothing to report and learns from the graphs it asked for.
      assert Setup.memory_findings(opened.setup) == []

      %{learning_modules: [learning_module]} = Setup.model_spec(opened.setup, "memory-test")

      assert map_size(learning_module.state.graph_memory.models_in_memory) == 10
    end

    test "gets the newest export of that model when the named release has none, and says so" do
      # A release nobody exported: the run still works, with the graphs that are
      # here, and the page says which ones those are. The world is named because
      # a stand-in run is the one that needs no memory at all, and this is not
      # about that one.
      {:ok, opened} =
        Monty.Studio.open(@experiment,
          pretrained_dir: "/models/pretrained_ycb_v99",
          world_simulator: :mujoco
        )

      assert [%{code: :memory_from_another_release, message: message}] =
               Setup.memory_findings(opened.setup)

      assert message =~ "surf_agent_1lm_10distinctobj"
      assert message =~ "pretrained_ycb_v99"
      assert message =~ "The run works"

      %{learning_modules: [learning_module]} = Setup.model_spec(opened.setup, "memory-test")

      assert map_size(learning_module.state.graph_memory.models_in_memory) == 10
    end
  end

  describe "what a setup says about its memory" do
    test "says nothing when the config names no model" do
      assert Setup.memory_findings(%Setup{}) == []
    end

    # The stand-in is the one thing that works on a fresh volume: it loads a
    # memory when one is exported and runs on an empty one when none is, so a
    # page that refused it for want of a download would be refusing the way in.
    test "says nothing for a stand-in run, even when no release exports the model" do
      setup = %Setup{
        world: :synthetic,
        model_name_or_path: monty_path("pretrained_ycb_v13", "a_model_nobody_exported")
      }

      assert Setup.memory_findings(setup) == []
      assert Setup.valid?(%{setup | findings: Setup.memory_findings(setup)})
    end

    test "warns when the memory is only exported from another release, and the run still starts" do
      setup = %Setup{
        world: :mujoco,
        model_name_or_path: monty_path("pretrained_ycb_v99", "surf_agent_1lm_10distinctobj")
      }

      assert [%{code: :memory_from_another_release, message: message}] =
               Setup.memory_findings(setup)

      assert message =~ "pretrained_ycb_v10"
      assert message =~ "pretrained_ycb_v99"

      assert Setup.valid?(%{setup | findings: Setup.memory_findings(setup)})
    end

    test "refuses a run when no release exports the model, and says a run writes it" do
      setup = %Setup{
        world: :mujoco,
        model_name_or_path: monty_path("pretrained_ycb_v13", "a_model_nobody_exported")
      }

      assert [%{level: :error, code: :no_pretrained_memory, message: message}] =
               Setup.memory_findings(setup)

      assert message =~ "a_model_nobody_exported"
      assert message =~ "cannot recognise any object"

      # The prerequisites page holds the archives Monty published. A model no
      # archive carries is not on that page, and sending a reader there is a
      # link to a file that is not there.
      assert message =~ "No archive carries it and no experiment here trains it"
      refute message =~ "prerequisites"

      refute Setup.valid?(%{setup | findings: Setup.memory_findings(setup)})
    end

    test "says a memory this application trained is its own, not a release of Monty's" do
      # `…/projects/surf_agent_1lm_2obj_train/pretrained` is Monty's own output
      # directory: its second-to-last segment is a folder, not a release, so
      # comparing the two reads as "the memory projects trained".
      libraries = Tmp.env_dir("memory-trained", :monty_libraries_dir)
      name = "surf_agent_1lm_2obj_train"
      :ok = Memory.save(GraphMemory.new(), name, Learned.release(), libraries)

      setup = %Setup{
        world: :mujoco,
        model_name_or_path: monty_path("projects", name),
        learning_modules: [%{id: "learning_module_0"}]
      }

      assert [%{level: :warning, code: :memory_from_another_release, message: message} = found] =
               Setup.memory_findings(setup)

      # The file it will read, not the path the config names: the second is
      # Monty's output directory, and a reader who wanted to know which graphs
      # they get was being told about a directory that is not here.
      assert message =~ "trained/#{name}.jsonl.gz"
      assert message =~ "Nothing to download or train"
      refute message =~ "projects"

      # And the experiment that wrote it, as a click: a reader told "a run here
      # trained this" next wants the run, and its experiment page is where the
      # runs of it are listed and where another is started. The label is the
      # experiment's own name, which is what the catalogue calls it.
      assert %{label: trainer, href: "/experiments/" <> trainer} = found.link

      assert trainer in Enum.map(Catalog.experiments(), & &1.name)

      assert Setup.valid?(%{setup | findings: Setup.memory_findings(setup)})
    end

    test "names the experiment whose run writes the memory a config reads" do
      # `surf_agent_2obj_eval` reads what `surf_agent_2obj_train` writes, and the
      # memory is named after the run — not after the config's file. An empty
      # library tree, because a machine that has trained this memory would answer
      # with it rather than with the run that writes it.
      Tmp.env_dir("libraries-nothing-yet", :monty_libraries_dir)

      setup = %Setup{
        world: :mujoco,
        model_name_or_path: monty_path("pretrained_ycb_v14", "surf_agent_1lm_2obj_train")
      }

      assert [%{code: :no_pretrained_memory, message: message}] = Setup.memory_findings(setup)

      assert message =~ "tutorial/surf_agent_2obj_train"
      assert message =~ "train that first"
    end
  end

  describe "a directory that holds libraries" do
    test "lists the models each release exports, and nothing that is not one" do
      dir = Tmp.dir("libraries")

      export!(dir, "pretrained_ycb_v12", "surf_agent_1lm_10distinctobj")
      File.write!(Path.join([dir, "pretrained_ycb_v12", "notes.md"]), "")
      # A README beside the releases is not a release.
      File.write!(Path.join(dir, "README.md"), "")

      assert Memory.available_libraries(dir) ==
               ["pretrained_ycb_v12/surf_agent_1lm_10distinctobj"]
    end
  end

  describe "a memory written out as a library" do
    test "reads back with the same objects, and every node in the same place with the same features" do
      dir = Tmp.dir("written")
      memory = trained_memory()

      assert :ok = Memory.save(memory, "trained_here", "pretrained_here", dir)
      assert Memory.available?("trained_here", "pretrained_here", dir)

      {:ok, loaded} = Memory.load("trained_here", "pretrained_here", dir)

      assert GraphMemory.get_memory_ids(loaded) == GraphMemory.get_memory_ids(memory)

      for object_id <- GraphMemory.get_memory_ids(memory),
          channel <- GraphMemory.get_input_channels_in_graph(memory, object_id) do
        assert nodes(loaded, object_id, channel) == nodes(memory, object_id, channel)
      end
    end

    test "is refused for a name that is not a model's, rather than written outside the library" do
      dir = Tmp.dir("written")

      assert Memory.save(trained_memory(), "../escape", "pretrained_here", dir) ==
               {:error, {:not_a_model_name, "../escape"}}

      refute File.exists?(Path.join(dir, "pretrained_here"))
    end
  end

  # What matching reads, as values that do not depend on which column a feature
  # happens to sit in: each node's position and its features by name, sorted so
  # two memories that hold the same nodes compare equal whatever order they were
  # stored in.
  defp nodes(memory, object_id, channel) do
    model = GraphMemory.get_graph(memory, object_id, channel)
    %{x: rows, feature_mapping: mapping} = GraphObjectModel.graph(model)

    [GraphObjectModel.positions(model), rows]
    |> Enum.zip_with(fn [position, row] ->
      {position,
       Map.new(mapping, fn {name, {first, last}} ->
         {name, Enum.slice(row, first, last - first)}
       end)}
    end)
    |> Enum.sort()
  end

  # A memory as a training episode leaves it: two objects, three nodes, and the
  # features the evidence-based module matches on.
  defp trained_memory do
    memory = GraphMemory.new(features_to_use: %{"patch" => ~w(hsv pose_vectors)})

    [{"mug", [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0]]}, {"bowl", [[0.0, 0.0, 0.05]]}]
    |> Enum.reduce(memory, fn {object_id, positions}, memory ->
      {:ok, model} =
        GraphObjectModel.build_model(
          GraphObjectModel.new(object_id),
          positions,
          features_for(positions)
        )

      GraphMemory.add_graph_to_memory(memory, %{"patch" => model}, object_id)
    end)
  end

  defp features_for(positions) do
    %{
      "hsv" => Enum.map(positions, fn _position -> [0.1, 0.2, 0.3] end),
      "pose_fully_defined" => Enum.map(positions, fn _position -> [1.0] end),
      "principal_curvatures_log" => Enum.map(positions, &[Enum.sum(&1)]),
      "pose_vectors" =>
        Enum.map(positions, fn _position ->
          [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
        end)
    }
  end

  # An export in the format `Memory` reads: one object, one channel, one node.
  # Discovery looks at which files exist rather than what is in them, but a file
  # that could not be loaded would be a lie about what a library is.
  defp export!(dir, release, name) do
    path = Memory.path_for(name, release, dir)
    File.mkdir_p!(Path.dirname(path))

    record = library_record(0, name)

    File.write!(path, :zlib.gzip(Jason.encode!(record) <> "\n"))
    path
  end

  # One record of a library: a node with the four features an evidence module
  # matches on, in the module the index names.
  defp library_record(module_index, object_id) do
    %{
      "lm_index" => module_index,
      "object_id" => object_id,
      "input_channel" => "patch",
      "positions" => [[0.0, 0.0, 0.0]],
      "features" => %{
        "hsv" => [[0.1, 0.2, 0.3]],
        "pose_vectors" => [[0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]],
        "pose_fully_defined" => [[1.0]],
        "principal_curvatures_log" => [[0.0]]
      }
    }
  end

  describe "a library that holds one memory per learning module" do
    test "loads the module the caller asks for, and says how many there are" do
      dir = Tmp.dir("modules")
      path = Memory.path_for("heterarchy", "pretrained_cows", dir)
      File.mkdir_p!(Path.dirname(path))

      # A heterarchy's three memories in one library: the 3-D child, the 2-D
      # child, and the high-level module. Each record says which it belongs to.
      records = [library_record(0, "001_cube"), library_record(1, "021_logo_tbp")]
      File.write!(path, :zlib.gzip(Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"))

      assert Memory.modules("heterarchy", "pretrained_cows", dir) == 2

      {:ok, child} = Memory.load_module("heterarchy", "pretrained_cows", 0, dir)
      assert GraphMemory.get_memory_ids(child) == ["001_cube"]

      {:ok, high_level} = Memory.load_module("heterarchy", "pretrained_cows", 1, dir)
      assert GraphMemory.get_memory_ids(high_level) == ["021_logo_tbp"]
    end
  end

  describe "a directory that holds no libraries" do
    test "answers that the model was never exported, rather than an empty memory" do
      empty = Tmp.dir("no-libraries")

      # The question a run asks, asked of a directory instead: no global setting
      # is touched, so this cannot leak into a test running beside it.
      refute Memory.available?("surf_agent_1lm_10distinctobj", "pretrained_ycb_v10", empty)

      assert Memory.load("surf_agent_1lm_10distinctobj", "pretrained_ycb_v10", empty) ==
               {:error, :not_found}

      assert Memory.available_libraries(empty) == []
    end
  end
end
