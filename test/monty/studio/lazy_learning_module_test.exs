defmodule Monty.Studio.LazyLearningModuleTest do
  # Not async: the library a module reads is found through `:monty_libraries_dir`,
  # a setting of the whole VM (`Monty.Test.Tmp` says why that rules async out).
  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Studio.{Memory, Setup}
  alias Monty.Test.Tmp

  @library "surf_agent_1lm_a_library_for_the_test"
  @release "pretrained_ycb_v99"

  setup do
    libraries = Tmp.env_dir("lazy-module-libraries", :monty_libraries_dir)
    :ok = Memory.save(one_object(), @library, @release, libraries)

    {:ok, opened} = Setup.from_experiment("base_config_10distinctobj_dist_agent")

    # The config names Monty's own directory; the run is pointed at this test's
    # library instead, which is the same path shape with a release and a model
    # this machine has.
    model_path = Path.join([libraries, @release, @library, "pretrained"])

    %{setup: %{opened | model_name_or_path: model_path}}
  end

  # A run that reads its memory from a library asks for its modules' state to be
  # built where they run: a memory is tens of megabytes, and a spec is copied into
  # the model and into every module server while the module only reads it.
  test "a spec for a library-reading run carries the library's identity, not its graphs", %{
    setup: setup
  } do
    spec = Setup.model_spec(setup, :a_model, lazy_state: true)

    assert [%{state: {:lazy, build}}] = spec.learning_modules
    assert is_function(build, 0)
  end

  test "a module built from the library holds what the eager path holds", %{setup: setup} do
    lazy = Setup.model_spec(setup, :a_model, lazy_state: true)
    eager = Setup.model_spec(setup, :a_model)

    assert [%{state: {:lazy, build}}] = lazy.learning_modules
    assert [%{state: %{graph_memory: eager_memory}}] = eager.learning_modules

    assert %{graph_memory: built} = build.()

    assert GraphMemory.get_memory_ids(built) == ["object_0"]
    assert built == eager_memory
  end

  # Three points are a graph a module can be built over: `build_graph/5` adds no
  # edges, and edges are what stepping the memory adds. Features are one list of
  # numbers per point — the flat form a library's records carry.
  defp one_object do
    GraphMemory.new()
    |> GraphMemory.build_graph(
      [[0.0, 0.0, 0.0], [0.001, 0.0, 0.0], [0.0, 0.001, 0.0]],
      %{
        "hsv" => [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, 0.5]],
        "pose_vectors" => [
          [0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
          [0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
          [0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
        ]
      },
      "object_0",
      "patch"
    )
  end
end
