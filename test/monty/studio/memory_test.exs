defmodule Monty.Studio.MemoryTest do
  @moduledoc """
  A run's memory: Monty's pretrained graphs, and what a run says when there are
  none.

  The library is an export of Monty's own `surf_agent_1lm_10distinctobj` model
  (`priv/monty/libraries/README.md` says where it came from), so these are the
  questions that matter: does a config that names that model get its ten
  objects, and does a config that names something else say so rather than
  quietly starting with an empty memory.
  """

  use ExTbpMontyWeb.ConnCase, async: true

  alias Monty.Studio.{Memory, Setup}

  @experiment "base_config_10distinctobj_dist_agent"

  describe "the library a config names" do
    test "is found by the model's own directory name" do
      path =
        "/somewhere/pretrained_models/pretrained_ycb_v10/" <>
          "surf_agent_1lm_10distinctobj/pretrained/"

      assert Memory.name_of(path) == "surf_agent_1lm_10distinctobj"
    end

    test "is not found for a name the directory does not hold" do
      refute Memory.available?("a_model_nobody_exported")
      assert Memory.load("a_model_nobody_exported") == {:error, :not_found}
    end

    test "carries every object Monty trained" do
      assert Memory.available_libraries() == ["surf_agent_1lm_10distinctobj"]

      {:ok, memory} = Memory.load("surf_agent_1lm_10distinctobj")

      assert memory.models_in_memory |> Map.keys() |> Enum.sort() ==
               ~w(banana bowl c_lego_duplo dice golf_ball mug mustard_bottle
                  potted_meat_can spoon strawberry)
    end
  end

  describe "a run of an experiment that names a model" do
    test "gets that model's memory in its learning module" do
      {:ok, opened} = Monty.Studio.open(@experiment)

      refute Enum.any?(opened.setup.findings, &(&1.code == :no_pretrained_memory))

      %{learning_modules: [learning_module]} = Setup.model_spec(opened.setup, "memory-test")

      assert map_size(learning_module.state.graph_memory.models_in_memory) == 10
    end
  end

  describe "a directory that holds no libraries" do
    test "answers that the model was never exported, rather than an empty memory" do
      empty = Path.join(System.tmp_dir!(), "no-libraries-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      # The question a run asks, asked of a directory instead: no global setting
      # is touched, so this cannot leak into a test running beside it.
      refute Memory.available?("surf_agent_1lm_10distinctobj", empty)
      assert Memory.load("surf_agent_1lm_10distinctobj", empty) == {:error, :not_found}
      assert Memory.available_libraries(empty) == []
    end
  end
end
