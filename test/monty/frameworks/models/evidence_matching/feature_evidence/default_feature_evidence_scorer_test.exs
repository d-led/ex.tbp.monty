defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorerTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Core.MatcherNif

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

  # The scorer answers one value per node as a column of bytes — that is what a
  # kernel reads next — so these tests read it back to ask what the values are.
  defp values(column) when is_binary(column), do: MatcherNif.decode(column)
  defp values(column), do: column

  describe "evidence/4" do
    test "a node whose stored value matches the observation is fully supported" do
      evidence =
        memory([0.2, 0.6])
        |> scorer()
        |> DefaultFeatureEvidenceScorer.evidence("mug", "patch", %{
          "principal_curvatures" => [0.2]
        })
        |> values()

      assert [supported, unsupported] = evidence
      assert_in_delta supported, 1.0, 1.0e-9
      assert unsupported == 0.0
    end

    test "evidence falls off between the match and the tolerance" do
      evidence =
        DefaultFeatureEvidenceScorer.evidence(scorer(memory([0.25])), "mug", "patch", %{
          "principal_curvatures" => [0.2]
        })
        |> values()

      assert_in_delta hd(evidence), 0.5, 1.0e-9
    end

    test "the increment scales feature evidence before it reaches a hypothesis" do
      scaled =
        memory([0.2])
        |> scorer(increment: 3)
        |> DefaultFeatureEvidenceScorer.evidence("mug", "patch", %{
          "principal_curvatures" => [0.2]
        })
        |> values()

      assert_in_delta hd(scaled), 3.0, 1.0e-9
    end
  end

  describe "a channel that is not matched on features" do
    test "is not used when it weights nothing but poses" do
      weights = %{"patch" => %{"pose_vectors" => [10.0, 10.0, 10.0]}}

      built = scorer(memory([0.2, 0.6]), feature_weights: weights)

      refute DefaultFeatureEvidenceScorer.matched_on_features?(built, "patch")

      assert values(DefaultFeatureEvidenceScorer.evidence(built, "mug", "patch", %{})) == [
               0.0,
               0.0
             ]
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

      assert values(DefaultFeatureEvidenceScorer.evidence(built, "mug", "patch", %{})) == [
               0.0,
               0.0,
               0.0
             ]
    end
  end

  describe "a node with no stored value" do
    test "has no evidence, rather than the best or the worst score" do
      built = memory([0.2])

      graph = GraphMemory.get_graph(built, "mug", "patch")
      {:ok, stripped} = GraphObjectModel.set_graph(graph, %{graph.graph | x: [[0.0, nil]]})

      memory =
        built
        |> GraphMemory.add_graph_to_memory(%{"patch" => stripped}, "mug")
        |> GraphMemory.initialize_feature_arrays()

      assert values(
               DefaultFeatureEvidenceScorer.evidence(scorer(memory), "mug", "patch", %{
                 "principal_curvatures" => [0.2]
               })
             ) == [nil]
    end
  end

  # Monty's `DefaultFeatureEvidenceScorerTest`, whose cases are a selector that
  # says yes or no and a calculator that answers ones. Here the selector is the
  # memory's own `features_to_use` and the calculator a real one, so each case
  # asks the same question: what a channel scores when the match never reads it,
  # and what the increment does to it when the match does.
  describe "Monty's own cases" do
    # test_returns_all_zeros_when_input_channel_is_not_used_for_matching
    test "a channel the match never reads scores zero at every node" do
      for values_at_nodes <- [[0.2], [0.2, 0.6, 0.9]] do
        built = scorer(memory(values_at_nodes), feature_weights: %{})

        assert values(DefaultFeatureEvidenceScorer.evidence(built, "mug", "patch", %{})) ==
                 List.duplicate(0.0, length(values_at_nodes))
      end
    end

    # test_returns_feature_evidence_multiplied_by_feature_evidence_increment_when_input_channel_is_used_for_matching
    test "and the increment multiplies what a matched channel scores" do
      # Monty's calculator answers ones, so what is left is the increment.
      for increment <- [0.5, 1, 3] do
        built = scorer(memory([0.2]), increment: increment)

        assert [score] =
                 values(
                   DefaultFeatureEvidenceScorer.evidence(built, "mug", "patch", %{
                     "principal_curvatures" => [0.2]
                   })
                 )

        assert_in_delta score, 1.0 * increment, 1.0e-9
      end
    end
  end
end
