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

  alias Monty.Studio.{Memory, Setup}
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
      # here, and the page says which ones those are.
      {:ok, opened} = Monty.Studio.open(@experiment, pretrained_dir: "/models/pretrained_ycb_v99")

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

    test "warns when the memory is only exported from another release" do
      setup = %Setup{
        model_name_or_path: monty_path("pretrained_ycb_v99", "surf_agent_1lm_10distinctobj")
      }

      assert [%{code: :memory_from_another_release, message: message}] =
               Setup.memory_findings(setup)

      assert message =~ "pretrained_ycb_v10"
      assert message =~ "pretrained_ycb_v99"
    end

    test "warns that nothing can be recognised when no release exports the model" do
      setup = %Setup{
        model_name_or_path: monty_path("pretrained_ycb_v13", "a_model_nobody_exported")
      }

      assert [%{code: :no_pretrained_memory, message: message}] = Setup.memory_findings(setup)
      assert message =~ "a_model_nobody_exported"
      assert message =~ "cannot recognise any object"
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

  # An export in the format `Memory` reads: one object, one channel, one node.
  # Discovery looks at which files exist rather than what is in them, but a file
  # that could not be loaded would be a lie about what a library is.
  defp export!(dir, release, name) do
    path = Memory.path_for(name, release, dir)
    File.mkdir_p!(Path.dirname(path))

    record = %{
      "object_id" => name,
      "input_channel" => "patch",
      "positions" => [[0.0, 0.0, 0.0]],
      "features" => %{
        "hsv" => [[0.1, 0.2, 0.3]],
        "pose_vectors" => [[0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]],
        "pose_fully_defined" => [[1.0]],
        "principal_curvatures_log" => [[0.0]]
      }
    }

    File.write!(path, :zlib.gzip(Jason.encode!(record) <> "\n"))
    path
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
