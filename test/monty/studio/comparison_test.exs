defmodule Monty.Studio.ComparisonTest do
  @moduledoc """
  Two runs of one experiment beside each other: what each cost, what each
  concluded, and which inputs differ — or the refusal when they are not the same
  experiment.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Comparison

  @experiment "tutorial/dist_agent_5lm_2obj_train"

  # One run of the experiment: the numbers `Monty.Studio.RunLog.summary/2`
  # writes, and the inputs the page recorded.
  defp side(name, attrs) do
    Map.merge(
      %{
        name: name,
        experiment: @experiment,
        inputs: %{"scheduling" => "barrier", "sensors" => "concurrent"},
        summary: %{
          "steps" => 8595,
          "duration_us" => 61_000_000,
          "world_us" => 9_000_000,
          "deadline_hits" => 0,
          "outcome" => %{"learning_module_0" => "match", "learning_module_1" => "match"}
        }
      },
      attrs
    )
  end

  test "a table of two runs, one input apart, and the input that differs" do
    barrier = side("barrier", %{})
    lagged = side("lagged", %{inputs: %{"scheduling" => "lagged", "sensors" => "concurrent"}})

    assert {:ok, %{sides: ["barrier", "lagged"], differences: ["scheduling"], rows: rows}} =
             Comparison.compare(barrier, lagged)

    assert %{label: "Steps", a: 8595, b: 8595} = Enum.find(rows, &(&1.label == "Steps"))

    assert %{a: "match", b: "match"} =
             Enum.find(rows, &(&1.label == "learning_module_0 concluded"))
  end

  test "two different experiments are refused, naming both" do
    a = side("one", %{experiment: "tutorial/first_experiment"})
    b = side("two", %{})

    assert {:error, {:different_experiments, "tutorial/first_experiment", @experiment}} =
             Comparison.compare(a, b)
  end

  test "a module that concluded differently is the row that says so" do
    barrier = side("barrier", %{})

    lagged =
      side("lagged", %{
        summary: %{
          "steps" => 8595,
          "outcome" => %{"learning_module_0" => "match", "learning_module_1" => "time_out"}
        }
      })

    {:ok, %{rows: rows}} = Comparison.compare(barrier, lagged)

    assert %{label: "learning_module_1 concluded", a: "match", b: "time_out"} =
             Enum.find(rows, &(&1.label == "learning_module_1 concluded"))
  end

  test "an input only one run has is a difference too" do
    a = side("old", %{inputs: %{}})
    b = side("new", %{})

    assert Comparison.differences(a.inputs, b.inputs) == ["scheduling", "sensors"]
  end

  test "wall clock is a row when both sides have it, and absent when none does" do
    a = side("a", %{wall_us: 90_000_000})
    b = side("b", %{wall_us: 30_000_000})

    {:ok, %{rows: with_wall}} = Comparison.compare(a, b)

    assert %{label: "Wall clock", a: 90_000_000, b: 30_000_000} =
             Enum.find(with_wall, &(&1.label == "Wall clock"))

    {:ok, %{rows: without_wall}} = Comparison.compare(side("a", %{}), side("b", %{}))
    refute Enum.any?(without_wall, &(&1.label == "Wall clock"))
  end
end
