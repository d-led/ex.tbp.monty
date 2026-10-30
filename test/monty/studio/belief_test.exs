defmodule Monty.Studio.BeliefTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation
  alias Monty.Studio.Belief

  @pose_flat [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

  # Two objects, three nodes each along x: enough for the module to hold a
  # hypothesis space, and small enough that a test reads the numbers it asserts.
  defp learning_module do
    memory =
      %{"mug" => [0.0, 0.1, 0.2], "bowl" => [0.0, 0.1, 0.2]}
      |> Enum.reduce(GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]}), fn
        {id, positions}, memory ->
          model =
            GraphObjectModel.new(id)
            |> GraphObjectModel.build_model(
              Enum.map(positions, &[&1, 0.0, 0.0]),
              %{
                "rgba" => Enum.map(positions, &[&1]),
                "pose_vectors" => List.duplicate(@pose_flat, length(positions))
              },
              nil,
              nil
            )

          GraphMemory.add_graph_to_memory(memory, %{"patch" => model}, id)
      end)
      |> GraphMemory.initialize_feature_arrays()

    {:ok, lm} =
      EvidenceGraphLM.new(memory,
        max_match_distance: 0.05,
        tolerances: %{"patch" => %{"rgba" => 0.05}},
        feature_weights: %{"patch" => %{"rgba" => 1.0}},
        x_percent_threshold: 20
      )

    lm
  end

  defp hypotheses(evidence, locations) do
    %Hypotheses{
      evidence: evidence,
      locations: locations,
      poses: List.duplicate(Rotation.to_matrix(Rotation.identity()), length(evidence)),
      possible: List.duplicate(true, length(evidence))
    }
  end

  # A module that has concluded: one object is possible, its best hypothesis is
  # at a known place with a known rotation.
  defp believing(lm) do
    {:ok, turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], 0.4)

    %{
      lm
      | possible_matches: ["mug"],
        hypotheses: %{
          "mug" =>
            hypotheses([3.0, 2.9, 2.0], [[0.1, 0.0, 0.0], [0.2, 0.0, 0.0], [0.3, 0.0, 0.0]])
        },
        current_mlh: %{
          graph_id: "mug",
          mlh_id: 0,
          location: [0.0, 0.0, 0.0],
          rotation: turn,
          scale: 1,
          evidence: 3.0
        }
    }
  end

  describe "what the module holds" do
    test "an object's four numbers are the ones a conclusion turns on" do
      belief = learning_module() |> believing() |> Belief.of()

      assert %{
               hypotheses: 3,
               max_evidence: 3.0,
               within_x_percent: 2,
               top_evidence: [3.0, 2.9, 2.0]
             } =
               belief.graphs["mug"]
    end

    test "the band is the module's own threshold, not a number of its own" do
      # Three hypotheses at 3.0, 2.9 and 2.0: the last is more than 20 % behind
      # the best, so two of them are worth testing for pose.
      belief = learning_module() |> believing() |> Belief.of()
      assert belief.x_percent_threshold == 20
      assert belief.graphs["mug"].within_x_percent == 2
    end

    test "the objects it has not ruled out come back as Monty names them" do
      belief = learning_module() |> believing() |> Belief.of()

      assert belief.possible_matches == ["mug"]
    end

    test "the most likely hypothesis carries its location, its evidence and its rotation" do
      belief = learning_module() |> believing() |> Belief.of()

      assert belief.mlh.graph_id == "mug"
      assert belief.mlh.id == 0
      assert belief.mlh.location == [0.1, 0.0, 0.0]
      assert belief.mlh.evidence == 3.0
      assert length(belief.mlh.rotation_wxyz) == 4
    end

    test "the rotation is Monty's wxyz, so a quarter turn about z reads (0.98, 0, 0, 0.2)" do
      belief = learning_module() |> believing() |> Belief.of()
      [w, x, y, z] = belief.mlh.rotation_wxyz

      assert_in_delta w, :math.cos(0.2), 1.0e-12
      assert_in_delta z, :math.sin(0.2), 1.0e-12
      assert [x, y] == [0.0, 0.0]
    end

    test "the location is the one the space holds now, not the one last recorded" do
      # The space moved since the MLH was written down: a location-only step
      # displaces the hypothesis but not its identity.
      belief =
        learning_module()
        |> believing()
        |> Map.put(:current_mlh, %{
          graph_id: "mug",
          mlh_id: 1,
          location: [0.0, 0.0, 0.0],
          rotation: Rotation.identity(),
          scale: 1,
          evidence: 2.9
        })
        |> Belief.of()

      assert belief.mlh.location == [0.2, 0.0, 0.0]
    end
  end

  describe "what it holds before it has seen anything" do
    test "no most likely hypothesis, because a hypothesis with no id is none" do
      belief = learning_module() |> Belief.of()

      assert belief.mlh == nil
      assert belief.graphs == %{}
    end

    test "a module that keeps no hypothesis space has no belief to report" do
      assert Belief.of(%{}) == nil
    end
  end
end
