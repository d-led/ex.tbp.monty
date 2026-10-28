defmodule Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLMConfigTest do
  @moduledoc """
  A learning module built from an experiment's own configuration.

  Monty instantiates its experiments through Hydra; this port reads the same
  composed mapping. What matters is that the numbers an experiment writes are
  the numbers that run: tolerances, feature weights, the threshold rule, the
  burst sampler and its neighbour count, and the memory the module learns into.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GridObjectModel

  # What `learning_module/evidence_1lm_nn5_dod0025.yaml` composes to, together
  # with the burst sampler that group selects.
  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        "_target_" =>
          "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM",
        "learning_module_id" => "learning_module_0",
        "tolerances" => %{
          "patch" => %{
            "hsv" => [0.1, 0.2, 0.2],
            "principal_curvatures_log" => [1.0, 1.0]
          }
        },
        "feature_weights" => %{
          "patch" => %{
            "hsv" => [2.0, 0.5, 0.5],
            "pose_vectors" => [1.0, 1.0, 1.0],
            "principal_curvatures_log" => [1.0, 1.0]
          }
        },
        "max_match_distance" => 0.01,
        "x_percent_threshold" => 20,
        "evidence_threshold_config" => "all",
        "max_graph_size" => 0.3,
        "num_model_voxels_per_dim" => 100,
        "hypotheses_updater_class" =>
          "tbp.monty.frameworks.models.evidence_matching.burst_sampling.BurstSamplingHypothesesUpdater",
        "hypotheses_updater_args" => %{"max_nneighbors" => 5}
      },
      overrides
    )
  end

  describe "an experiment's learning-module config" do
    test "decides the module's tolerances, weights and thresholds" do
      {:ok, lm} = EvidenceGraphLM.from_config(config())

      assert lm.learning_module_id == "learning_module_0"
      assert lm.max_match_distance == 0.01
      assert lm.x_percent_threshold == 20
      assert lm.threshold_config == :all

      assert lm.tolerances["patch"]["hsv"] == [0.1, 0.2, 0.2]
      assert lm.feature_weights["patch"]["hsv"] == [2.0, 0.5, 0.5]

      # Poses are compared whether or not the experiment names a tolerance for
      # them, so the module adds one rather than matching any pose.
      assert Map.has_key?(lm.tolerances["patch"], "pose_vectors")
    end

    test "decides the comparison strategy and how many neighbours it reads" do
      {:ok, lm} = EvidenceGraphLM.from_config(config())

      assert {BurstSamplingHypothesesUpdater, updater} = lm.hypotheses_updater
      assert updater.displacer.max_nneighbors == 5
    end

    test "decides what memory an object is stored in" do
      {:ok, lm} = EvidenceGraphLM.from_config(config())

      assert %GraphMemory{object_model: GridObjectModel} = lm.graph_memory
      assert lm.graph_memory.object_model_options[:max_size] == 0.3
      assert lm.graph_memory.object_model_options[:num_voxels_per_dim] == 100
      assert lm.graph_memory.object_model_options[:max_nodes] == 2000
    end

    test "a learning module this port has not written is refused by name" do
      {:error, {:unsupported_learning_module, target}} =
        EvidenceGraphLM.from_config(
          config(%{"_target_" => "tbp.monty.frameworks.models.feature_location_matching.GraphLM"})
        )

      assert target =~ "GraphLM"
    end

    test "an updater this port has not written is refused by name" do
      {:error, {:unsupported_hypotheses_updater, class}} =
        EvidenceGraphLM.from_config(
          config(%{
            "hypotheses_updater_class" =>
              "tbp.monty.frameworks.models.evidence_matching.sampling.MyUpdater"
          })
        )

      assert class =~ "MyUpdater"
    end
  end
end
