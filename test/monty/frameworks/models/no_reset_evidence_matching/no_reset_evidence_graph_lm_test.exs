defmodule Monty.Frameworks.Models.NoResetEvidenceMatching.NoResetEvidenceGraphLMTest do
  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator
  alias Monty.Frameworks.Models.NoResetEvidenceMatching.NoResetEvidenceGraphLM
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation

  # Hand-written intent, not parity: Monty has no unit test for this class —
  # `tests/integration/frameworks/models/no_reset_evidence_lm_test.py` drives a
  # whole Habitat experiment, and what it asserts is that a module's evidence is
  # unchanged between two episodes (`assert_dicts_equal` on the hypothesis
  # space). The cases below state the same behaviour one step at a time, plus the
  # two differences from `EvidenceGraphLM` the class exists for.

  @pose_flat [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  defp memory do
    locations = [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0], [0.2, 0.0, 0.0]]

    features = %{
      "rgba" => [[0.0], [0.1], [0.2]],
      "pose_vectors" => List.duplicate(@pose_flat, 3),
      "pose_fully_defined" => List.duplicate([1.0], 3)
    }

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(locations, features, nil, nil)

    GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp module_in(evidence \\ [1.0, 3.0]) do
    {:ok, lm} =
      EvidenceGraphLM.new(memory(),
        max_match_distance: 0.05,
        tolerances: %{"patch" => %{"rgba" => 0.05}},
        feature_weights: %{"patch" => %{"rgba" => 1.0}},
        # A generator, because one thing this class changes is its schedule.
        gsg: EvidenceGoalGenerator.new()
      )

    lm
    |> Map.put(:hypotheses, %{
      "mug" =>
        Hypotheses.new(
          evidence: evidence,
          locations: [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]],
          poses: [@identity, @identity],
          possible: [true, true]
        )
    })
    |> NoResetEvidenceGraphLM.new()
  end

  # Where the module remembers the sensor was, and a buffer that has been emptied
  # by the model the way an object change empties it.
  defp seen_at(lm, location), do: %{lm | last_location: location}

  defp emptied(lm), do: %{lm | lm: %{lm.lm | buffer: FeatureAtLocationBuffer.new()}}

  # A percept from a sensor that looked at nothing: a location-only step.
  defp moving_to(location) do
    {:ok, message} =
      Monty.Cmp.Message.new(
        location: location,
        morphological_features: %{},
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: false,
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  defp step(lm, percepts), do: NoResetEvidenceGraphLM.matching_step(percepts, Context.new(0), lm)

  defp locations(%NoResetEvidenceGraphLM{lm: inner}),
    do: inner.hypotheses |> Map.fetch!("mug") |> Hypotheses.locations()

  defp evidence(%NoResetEvidenceGraphLM{lm: inner}),
    do: inner.hypotheses |> Map.fetch!("mug") |> Hypotheses.evidence()

  describe "a step with no features in it" do
    test "moves the hypotheses by where the sensor went, and leaves their evidence alone" do
      lm = module_in() |> seen_at([0.0, 0.0, 0.0])

      assert {:ok, moved} = step(lm, [moving_to([0.1, 0.0, 0.0])])

      assert locations(moved) == [[0.1, 0.0, 0.0], [0.2, 0.0, 0.0]]
      assert evidence(moved) == [1.0, 3.0]
      assert moved.last_location == [0.1, 0.0, 0.0]
    end

    test "moves by its own memory of the sensor, not by the buffer's" do
      # The model empties every module's buffer at an object change. A module
      # that read the buffer would find no place to measure from and leave the
      # hypotheses on the object it has just left.
      lm = module_in() |> seen_at([0.0, 0.0, 0.0]) |> emptied()

      assert lm.lm.buffer.last_location == nil
      assert {:ok, moved} = step(lm, [moving_to([0.1, 0.0, 0.0])])

      assert locations(moved) == [[0.1, 0.0, 0.0], [0.2, 0.0, 0.0]]
    end

    test "leaves the hypotheses where they are when the sensor has never been seen" do
      lm = module_in()

      assert {:ok, unmoved} = step(lm, [moving_to([0.1, 0.0, 0.0])])

      assert locations(unmoved) == [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]]
    end
  end

  describe "its short-term memory" do
    test "forgets where the sensor was, so the next step is an unmoved one again" do
      lm = module_in() |> seen_at([0.0, 0.0, 0.0])

      assert NoResetEvidenceGraphLM.reset_stm(lm).last_location == nil
    end
  end

  describe "the goal generator it drives" do
    test "does not wait longer for a goal the longer the object takes to turn up" do
      # Monty sets `wait_growth_multiplier = 1`: waiting is for a sensor that
      # cannot find what it is on, and here the object is simply replaced.
      assert %EvidenceGoalGenerator{wait_growth_multiplier: 1} =
               module_in().lm.gsg
    end
  end
end
