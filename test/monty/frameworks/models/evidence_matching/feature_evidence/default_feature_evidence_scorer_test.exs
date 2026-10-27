defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorerTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

  # A graph whose nodes differ only in curvature, so evidence is predictable.
  defp memory(curvatures) do
    locations = for index <- 0..(length(curvatures) - 1)//1, do: [index / 10, 0.0, 0.0]

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(
        locations,
        %{
          "principal_curvatures" => Enum.map(curvatures, &[&1]),
          "pose_vectors" => List.duplicate(@pose, length(curvatures))
        },
        nil,
        nil
      )

    GraphMemory.new(features_to_use: %{"patch" => ["principal_curvatures"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp scorer(memory, options \\ []) do
    DefaultFeatureEvidenceScorer.new(
      memory,
      Keyword.merge(
        [
          feature_weights: %{"patch" => %{"principal_curvatures" => 1}},
          tolerances: %{"patch" => %{"principal_curvatures" => [0.1]}}
        ],
        options
      )
    )
  end

  describe "evidence/4" do
    test "a node whose stored value matches the observation is fully supported" do
      evidence =
        memory([0.2, 0.6])
        |> scorer()
        |> DefaultFeatureEvidenceScorer.evidence("mug", "patch", %{
          "principal_curvatures" => [0.2]
        })

      assert [supported, unsupported] = evidence
      assert_in_delta supported, 1.0, 1.0e-9
      assert unsupported == 0.0
    end

    test "evidence falls off between the match and the tolerance" do
      evidence =
        DefaultFeatureEvidenceScorer.evidence(scorer(memory([0.25])), "mug", "patch", %{
          "principal_curvatures" => [0.2]
        })

      assert_in_delta hd(evidence), 0.5, 1.0e-9
    end

    test "the increment scales feature evidence before it reaches a hypothesis" do
      scaled =
        memory([0.2])
        |> scorer(increment: 3)
        |> DefaultFeatureEvidenceScorer.evidence("mug", "patch", %{
          "principal_curvatures" => [0.2]
        })

      assert_in_delta hd(scaled), 3.0, 1.0e-9
    end
  end

  describe "a channel that is not matched on features" do
    test "is not used when it weights nothing but poses" do
      weights = %{"patch" => %{"pose_vectors" => [10.0, 10.0, 10.0]}}

      built = scorer(memory([0.2, 0.6]), feature_weights: weights)

      refute DefaultFeatureEvidenceScorer.matched_on_features?(built, "patch")
      assert DefaultFeatureEvidenceScorer.evidence(built, "mug", "patch", %{}) == [0.0, 0.0]
    end

    test "is not used when feature evidence counts for nothing" do
      built = scorer(memory([0.2]), increment: 0)

      refute DefaultFeatureEvidenceScorer.matched_on_features?(built, "patch")
    end

    test "is not used when the experiment never weighted the channel" do
      built = scorer(memory([0.2]), feature_weights: %{})

      refute DefaultFeatureEvidenceScorer.matched_on_features?(built, "patch")
    end

    test "but the channel's nodes are still hypotheses, one zero each" do
      built = scorer(memory([0.2, 0.6, 0.9]), feature_weights: %{})

      assert DefaultFeatureEvidenceScorer.evidence(built, "mug", "patch", %{}) == [0.0, 0.0, 0.0]
    end
  end

  describe "a node with no stored value" do
    test "has no evidence, rather than the best or the worst score" do
      built = memory([0.2])

      graph = GraphMemory.get_graph(built, "mug", "patch")
      stripped = GraphObjectModel.set_graph(graph, %{graph.graph | x: [[0.0, nil]]})

      memory =
        built
        |> GraphMemory.add_graph_to_memory(%{"patch" => stripped}, "mug")
        |> GraphMemory.initialize_feature_arrays()

      assert DefaultFeatureEvidenceScorer.evidence(scorer(memory), "mug", "patch", %{
               "principal_curvatures" => [0.2]
             }) == [nil]
    end
  end
end
