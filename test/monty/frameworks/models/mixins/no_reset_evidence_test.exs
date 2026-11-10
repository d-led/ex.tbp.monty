defmodule Monty.Frameworks.Models.Mixins.NoResetEvidenceTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Buffer.BufferEncoder
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.Mixins.NoResetEvidence.HypothesesUpdaterGraphTelemetry
  alias Monty.Frameworks.Models.Mixins.NoResetEvidence.TheoreticalLimitLMLoggingMixin
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation

  # Translated from Monty's `tests/unit/frameworks/models/mixins/no_reset_evidence_test.py`.
  # The mixin is a set of functions over a learning module rather than a class a
  # module is built from, so where Monty asserts that *defining* a subclass works
  # (or raises), this asks the same of calling the mixin: the guarantee is the
  # same — it applies to an evidence learning module and to nothing else — and
  # the mechanism is the argument's type instead of `__init_subclass__`.

  @pose_flat [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  defp memory do
    locations = [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]]

    features = %{
      "rgba" => [[1.0], [2.0]],
      "pose_vectors" => List.duplicate(@pose_flat, 2),
      "pose_fully_defined" => List.duplicate([1.0], 2)
    }

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(locations, features, nil, nil)

    GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  # A module that believes two poses for one object, and was told the object was
  # placed upright: the best hypothesis is then one rotation away from right.
  defp learning_module do
    {:ok, lm} =
      EvidenceGraphLM.new(memory(),
        max_match_distance: 0.05,
        tolerances: %{"patch" => %{"rgba" => 0.05}},
        feature_weights: %{"patch" => %{"rgba" => 1.0}}
      )

    {:ok, quarter_turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 2)

    lm
    |> EvidenceGraphLM.set_target(%{
      "object_name" => "mug",
      "quat_rotation" => [1.0, 0.0, 0.0, 0.0]
    })
    |> Map.put(:hypotheses, %{
      "mug" =>
        Hypotheses.new(
          evidence: [1.0, 3.0],
          locations: [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]],
          poses: [@identity, Rotation.to_matrix(quarter_turn)],
          possible: [true, true]
        )
    })
  end

  # test_mixin_used_with_compatible_learning_module_does_not_error
  describe "a mixin used with the learning module it was written for" do
    test "adds its statistics to that module's" do
      stats = TheoreticalLimitLMLoggingMixin.add_detailed_stats(learning_module(), %{})

      assert stats["max_evidence"] == %{"mug" => 3.0}
      assert stats["target_object_theoretical_limit"] == 0.0
      assert_in_delta stats["target_object_pose_error"], :math.pi() / 2, 1.0e-9
    end
  end

  # test_mixin_used_with_non_compatible_learning_module_raises_error
  describe "a mixin used with anything else" do
    test "is refused rather than given a module it cannot read" do
      # Through `mixin/0`, so the compiler is not asked to refuse at build time a
      # call this test makes on purpose: the call is the thing under test.
      assert_raise FunctionClauseError, fn ->
        mixin().add_detailed_stats(%{not: :a_learning_module}, %{})
      end
    end
  end

  # The mixin's module, as a value: a call on the result of a function is not
  # resolved at build time, which is what lets the test make a call the types say
  # cannot succeed.
  defp mixin, do: TheoreticalLimitLMLoggingMixin

  # test_buffer_encoder_encodes_hypotheses_updater_channel_telemetry
  describe "a hypotheses updater's graph telemetry" do
    test "encodes as the object of its fields, arrays and all" do
      telemetry = %HypothesesUpdaterGraphTelemetry{
        hypotheses_updater: %{},
        evidence: [0, 1],
        rotations: [0, 1],
        locations: [0, 1],
        pose_errors: [0, 1]
      }

      encoded = telemetry |> BufferEncoder.encode() |> Jason.encode!() |> Jason.decode!()

      assert encoded == %{
               "hypotheses_updater" => %{},
               "evidence" => [0, 1],
               "rotations" => [0, 1],
               "locations" => [0, 1],
               "pose_errors" => [0, 1]
             }
    end
  end
end
