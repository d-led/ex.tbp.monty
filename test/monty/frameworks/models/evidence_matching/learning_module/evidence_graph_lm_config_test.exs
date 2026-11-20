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
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Frameworks.Models.ObjectModel.GridObjectModel
  alias Monty.Geometry.Rotation

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

  # What a library exported from a trained model holds: one graph per object,
  # stored under the object's id, which is what the index is rebuilt from.
  defp pretrained(object_ids) do
    memory = GraphMemory.new(features_to_use: %{"patch" => ["hsv"]})

    object_ids
    |> Enum.reduce(memory, fn object_id, memory ->
      model =
        object_id
        |> GraphObjectModel.new()
        |> GraphObjectModel.build_model(
          [[0.0, 0.0, 0.0]],
          %{"hsv" => [[0.0, 0.0, 0.0]]},
          nil,
          nil
        )

      GraphMemory.add_graph_to_memory(memory, %{"patch" => model}, object_id)
    end)
    |> GraphMemory.initialize_feature_arrays()
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

    test "a threshold it cannot read is refused, not guessed at" do
      # Translated from Monty's
      # `test_init_fails_when_passed_invalid_evidence_threshold_config`. Monty
      # validates it in the updater's constructor; this port parses the setting
      # once, when the module is built, so the same refusal is asserted at that
      # entry point: a threshold that is neither a rule this port knows, nor a
      # percentage, nor a number.
      alias Monty.Frameworks.Models.EvidenceMatching.LearningModule
      alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.InvalidEvidenceThresholdConfig

      assert {:error, %InvalidEvidenceThresholdConfig{config: "invalid"}} =
               LearningModule.parse_config("invalid", 0.9)
    end

    test "decides the comparison strategy and how many neighbours it reads" do
      {:ok, lm} = EvidenceGraphLM.from_config(config())

      assert {BurstSamplingHypothesesUpdater, updater} = lm.hypotheses_updater
      assert updater.displacer.max_nneighbors == 5
    end

    test "decides the poses a run starts from, out of the updater's own arguments" do
      # Monty's Hydra instantiates the updater with `**hypotheses_updater_args`,
      # and `learning_module/evidence_omniglot_tutorial.yaml` pins
      # `initial_possible_poses: [[0, 0, 0]]` there. Reading it as "informed"
      # instead gave every node two aligned poses where Monty has one — twice
      # the hypothesis space, and a different run.
      {:ok, lm} =
        EvidenceGraphLM.from_config(
          config(%{
            "hypotheses_updater_class" =>
              "tbp.monty.frameworks.models.evidence_matching.hypotheses_updater.DefaultHypothesesUpdater",
            "hypotheses_updater_args" => %{
              "initial_possible_poses" => [[0, 0, 0]],
              "umbilical_num_poses" => 4
            }
          })
        )

      assert {DefaultHypothesesUpdater, updater} = lm.hypotheses_updater
      assert updater.initial_possible_poses == [Rotation.to_matrix(Rotation.identity())]
      assert updater.umbilical_num_poses == 4
    end

    test "a config that names no poses starts from the first observation" do
      {:ok, lm} =
        EvidenceGraphLM.from_config(
          config(%{
            "hypotheses_updater_class" =>
              "tbp.monty.frameworks.models.evidence_matching.hypotheses_updater.DefaultHypothesesUpdater"
          })
        )

      assert {DefaultHypothesesUpdater, updater} = lm.hypotheses_updater
      assert updater.initial_possible_poses == :first_observation
    end

    test "decides what memory an object is stored in" do
      {:ok, lm} = EvidenceGraphLM.from_config(config())

      assert %GraphMemory{object_model: GridObjectModel} = lm.graph_memory
      assert lm.graph_memory.object_model_options[:max_size] == 0.3
      assert lm.graph_memory.object_model_options[:num_voxels_per_dim] == 100
      assert lm.graph_memory.object_model_options[:max_nodes] == 2000
    end

    test "a pretrained memory says which object each of its graphs was built from" do
      {:ok, lm} =
        EvidenceGraphLM.from_config(config(), memory: pretrained(["mug", "spoon"]))

      assert lm.graph_id_to_target == %{
               "mug" => MapSet.new(["mug"]),
               "spoon" => MapSet.new(["spoon"])
             }

      assert lm.target_to_graph_id == %{
               "mug" => MapSet.new(["mug"]),
               "spoon" => MapSet.new(["spoon"])
             }
    end

    test "a memory that names the objects its graphs came from is indexed by those names" do
      # What a library carries now (`docs/monty-differences.md` §2.27): an
      # unsupervised training run names its graphs `new_object3`, and the library
      # says which dog that was, so a recognition run can score itself.
      {:ok, lm} =
        EvidenceGraphLM.from_config(config(),
          memory: pretrained(["new_object0", "new_object1"]),
          memory_targets: %{"new_object0" => ["milka"], "new_object1" => ["puppy"]}
        )

      assert lm.graph_id_to_target == %{
               "new_object0" => MapSet.new(["milka"]),
               "new_object1" => MapSet.new(["puppy"])
             }

      assert lm.target_to_graph_id == %{
               "milka" => MapSet.new(["new_object0"]),
               "puppy" => MapSet.new(["new_object1"])
             }
    end

    test "a module about to learn starts with no graph built from any object" do
      {:ok, lm} = EvidenceGraphLM.from_config(config())

      assert lm.graph_id_to_target == %{}
      assert lm.target_to_graph_id == %{}
    end

    test "decides the goal generator, and the schedule it explores on" do
      # `gsg` is the entry that turns "I cannot tell these apart" into "look
      # there next"; without it the module only ever matches.
      {:ok, lm} =
        EvidenceGraphLM.from_config(
          config(%{
            "gsg" => %{
              "_target_" => "tbp.monty.frameworks.models.goal_generation.EvidenceGoalGenerator",
              "goal_tolerances" => %{"location" => 0.015},
              "elapsed_steps_factor" => 10,
              "min_post_goal_success_steps" => 5,
              "x_percent_scale_factor" => 0.75,
              "desired_object_distance" => 0.025
            }
          })
        )

      assert %EvidenceGoalGenerator{} = gsg = lm.gsg
      assert gsg.base.goal_tolerances == %{"location" => 0.015}
      assert gsg.elapsed_steps_factor == 10
      assert gsg.min_post_goal_success_steps == 5
      assert gsg.x_percent_scale_factor == 0.75
      assert gsg.desired_object_distance == 0.025
    end

    test "points the generator at its module when an episode starts" do
      # A generator reads its module's hypotheses, so the module hands itself
      # over on reset — `point_at`/`put_parent_lm` in Monty. Without that the
      # generator has nothing to compare and the run never looks anywhere.
      {:ok, lm} =
        EvidenceGraphLM.from_config(
          config(%{
            "gsg" => %{
              "_target_" => "tbp.monty.frameworks.models.goal_generation.EvidenceGoalGenerator"
            }
          })
        )

      lm = EvidenceGraphLM.reset_stm(lm)

      assert EvidenceGoalGenerator.parent_lm(lm.gsg).learning_module_id ==
               lm.learning_module_id

      assert {goals, _lm} = EvidenceGraphLM.propose_goals(lm)
      assert goals == []
    end

    test "has no goal generator when the config asks for none" do
      {:ok, lm} = EvidenceGraphLM.from_config(config())

      assert lm.gsg == nil
    end

    test "a goal generator this port has not written leaves the module without one" do
      # The module still matches — its graph is the valuable part — and
      # `Setup` reports that the run explores without goals.
      {:ok, lm} =
        EvidenceGraphLM.from_config(
          config(%{
            "gsg" => %{"_target_" => "tbp.monty.frameworks.models.goal_generation.MyGenerator"}
          })
        )

      assert lm.gsg == nil
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
