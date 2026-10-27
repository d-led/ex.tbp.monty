defmodule Monty.Frameworks.Models.EvidenceMatching.LearningModuleTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.InvalidEvidenceThresholdConfig

  describe "which hypotheses a step is worth spending on" do
    test "a fixed number is the threshold, whatever the rest of the field says" do
      assert LearningModule.evidence_update_threshold(0.5, 10.0, [1.0, 2.0, 3.0]) == 0.5
    end

    test ~s("all" updates the field down to its lowest hypothesis) do
      assert LearningModule.evidence_update_threshold(:all, 10.0, [1.0, 2.0, 3.0]) == 1.0
    end

    test ~s("mean" and "median" summarise the field) do
      assert LearningModule.evidence_update_threshold(:mean, 10.0, [1.0, 2.0, 6.0]) == 3.0
      assert LearningModule.evidence_update_threshold(:median, 10.0, [1.0, 2.0, 6.0]) == 2.0
    end

    test "the median of an even-sized field averages the two middle hypotheses" do
      assert LearningModule.evidence_update_threshold(:median, 10.0, [1.0, 2.0, 6.0, 9.0]) == 4.0
    end

    test "a percentage keeps everything within that much of the best hypothesis" do
      config = {:percent_of_max, 10.0}

      assert LearningModule.evidence_update_threshold(config, 10.0, [1.0]) == 9.0
    end

    test "nothing observed yet lets every hypothesis through" do
      for config <- [0.5, :mean, :median, :all, {:percent_of_max, 10.0}] do
        assert LearningModule.evidence_update_threshold(config, 0.0, []) == 0.0
      end
    end
  end

  describe "reading the setting" do
    test "the settings Monty names are understood" do
      assert LearningModule.parse_config("mean", 10) == {:ok, :mean}
      assert LearningModule.parse_config("median", 10) == {:ok, :median}
      assert LearningModule.parse_config("all", 10) == {:ok, :all}
      assert LearningModule.parse_config(2, 10) == {:ok, 2}
    end

    test "a percentage is a percentage of the leader" do
      assert LearningModule.parse_config("95%", 10) == {:ok, {:percent_of_max, 95.0}}
      assert LearningModule.parse_config("0%", 10) == {:ok, {:percent_of_max, 0.0}}
    end

    test ~s("x_percent_threshold" is read against the module's own percentage) do
      assert LearningModule.parse_config("x_percent_threshold", 20) ==
               {:ok, {:percent_of_max, 20.0}}
    end

    test "a setting Monty does not define is refused and says which" do
      assert {:error, %InvalidEvidenceThresholdConfig{config: "avg"} = error} =
               LearningModule.parse_config("avg", 10)

      assert Exception.message(error) =~ "\"avg\""
    end

    test "a percentage outside 0 to 100 is refused" do
      assert {:error, %InvalidEvidenceThresholdConfig{}} = LearningModule.parse_config("120%", 10)
      assert {:error, %InvalidEvidenceThresholdConfig{}} = LearningModule.parse_config("-5%", 10)
    end

    test "a value that is neither a number nor a string is refused" do
      assert {:error, %InvalidEvidenceThresholdConfig{config: nil}} =
               LearningModule.parse_config(nil, 10)
    end
  end
end
