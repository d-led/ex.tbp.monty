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
      assert Memory.releases_for(name) == ["pretrained_ycb_v10", "pretrained_ycb_v13"]

      {:ok, memory} = Memory.load(name, release)

      assert memory.models_in_memory |> Map.keys() |> Enum.sort() ==
               ~w(banana bowl c_lego_duplo dice golf_ball mug mustard_bottle
                  potted_meat_can spoon strawberry)
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
    test "gets that model's memory in its learning module, and no memory finding" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      assert Setup.memory_findings(opened.setup) == []

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
      assert message =~ "cannot recognise anything"
    end
  end

  describe "a directory that holds no libraries" do
    test "answers that the model was never exported, rather than an empty memory" do
      empty = Path.join(System.tmp_dir!(), "no-libraries-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      # The question a run asks, asked of a directory instead: no global setting
      # is touched, so this cannot leak into a test running beside it.
      refute Memory.available?("surf_agent_1lm_10distinctobj", "pretrained_ycb_v10", empty)

      assert Memory.load("surf_agent_1lm_10distinctobj", "pretrained_ycb_v10", empty) ==
               {:error, :not_found}

      assert Memory.available_libraries(empty) == []
    end
  end
end
