defmodule ExamplePlugin.LearningModuleTest do
  @moduledoc """
  The one decision the learning module makes: which hypotheses are worth a step.

  The rule is the framework's own — the cases are here to hold the plugin to it
  at the plugin's boundary: the setting arrives as a string from the environment
  and is read once, and the threshold a step compares against is what Monty
  computes for that setting.
  """

  use ExUnit.Case, async: true

  alias ExamplePlugin.LearningModule

  test "a fixed threshold is the number it was given, whatever the field holds" do
    {:ok, module} = LearningModule.from_settings(threshold: 3)

    assert LearningModule.evidence_update_threshold(module, 100.0, [1.0, 2.0, 3.0]) == 3.0
  end

  test "on a setting of twenty per cent, a hypothesis within a fifth of the leader is updated" do
    {:ok, module} =
      LearningModule.from_settings(threshold: "x_percent_threshold", x_percent_threshold: 20)

    # The best hypothesis has 10.0, so everything at 8.0 and above may be
    # updated and everything below keeps the evidence it had.
    assert LearningModule.evidence_update_threshold(module, 10.0, [1.0, 8.0, 10.0]) == 8.0
  end

  test "the lowest hypothesis is the threshold when the setting says all" do
    {:ok, module} = LearningModule.from_settings(threshold: "all")

    assert LearningModule.evidence_update_threshold(module, 10.0, [2.5, 6.0, 10.0]) == 2.5
  end

  test "a setting Monty does not define is refused where the module is built" do
    assert {:error, reason} = LearningModule.from_settings(threshold: "avg")

    assert reason =~ ~s{"avg"}
  end
end
