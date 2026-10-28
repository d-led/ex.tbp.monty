defmodule Monty.Frameworks.Models.EvidenceMatching.GraphMemoryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Monty.Frameworks.Models.EvidenceMatching.GraphMemory.EvidenceGraphMemory
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GridObjectModel
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

  # Three voxels per centimetre: 30 voxels over 0.3 m, so anything closer than a
  # centimetre lands in the same voxel.
  defp memory(options \\ []) do
    EvidenceGraphMemory.new(
      Keyword.merge([max_graph_size: 0.3, num_model_voxels_per_dim: 30], options)
    )
  end

  defp observe(memory, graph_id, locations) do
    GraphMemory.update_memory(
      memory,
      locations,
      %{
        "patch" => %{
          "rgba" => Enum.map(locations, fn _ -> [0.5] end),
          "pose_vectors" => List.duplicate(@pose, length(locations)),
          "pose_fully_defined" => List.duplicate(true, length(locations))
        }
      },
      graph_id,
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0],
      Rotation.identity()
    )
  end

  describe "learning into memory" do
    test "an object is stored as a grid model, with the numbers it was made with" do
      memory = observe(memory(max_nodes_per_graph: 100), "mug", [[0.0, 0.0, 0.0]])

      assert %{"patch" => %GridObjectModel{} = model} = GraphMemory.get_graph(memory, "mug", nil)
      assert model.max_size == 0.3
      assert model.max_nodes == 100
      assert GraphMemory.get_num_nodes_in_graph(memory, "mug", "patch") == 1
    end

    test "observations closer than a voxel become one node rather than many" do
      memory =
        memory()
        |> observe("mug", [[0.0, 0.0, 0.0], [0.002, 0.0, 0.0]])
        |> observe("mug", [[0.004, 0.0, 0.0]])

      assert GraphMemory.get_num_nodes_in_graph(memory, "mug", "patch") == 1
    end

    test "an object the grid cannot hold is not stored at all" do
      log =
        capture_log(fn ->
          memory = observe(memory(), "whale", [[0.0, 0.0, 0.0], [2.0, 0.0, 0.0]])

          assert GraphMemory.size(memory) == 0
        end)

      assert log =~ "not building whale"
    end
  end

  describe "what a learning module starts from" do
    test "every object in memory is a hypothesis" do
      memory =
        memory()
        |> observe("mug", [[0.0, 0.0, 0.0]])
        |> observe("cup", [[0.0, 0.0, 0.0]])

      assert Enum.sort(EvidenceGraphMemory.get_initial_hypotheses(memory)) == ["cup", "mug"]
    end

    test "an empty memory leaves nothing possible" do
      assert EvidenceGraphMemory.get_initial_hypotheses(memory()) == []
    end
  end
end
