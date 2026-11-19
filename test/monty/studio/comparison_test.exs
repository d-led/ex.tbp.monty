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

  test "how many episodes reached each state, beside the last conclusion" do
    barrier =
      side("barrier", %{
        summary: %{
          "steps" => 8595,
          "outcome" => %{"learning_module_1" => "match"},
          "outcomes" => %{"learning_module_1" => %{"match" => 5}}
        }
      })

    lagged =
      side("lagged", %{
        summary: %{
          "steps" => 9000,
          "outcome" => %{"learning_module_1" => "time_out"},
          "outcomes" => %{"learning_module_1" => %{"match" => 3, "time_out" => 2}}
        }
      })

    {:ok, %{rows: rows}} = Comparison.compare(barrier, lagged)

    assert %{label: "learning_module_1 match", a: 5, b: 3} =
             Enum.find(rows, &(&1.label == "learning_module_1 match"))

    assert %{label: "learning_module_1 time_out", a: 0, b: 2} =
             Enum.find(rows, &(&1.label == "learning_module_1 time_out"))
  end

  test "an input only one run records is not a difference, and is said separately" do
    a = side("old", %{inputs: %{}})
    b = side("new", %{})

    # Nobody changed these; the older record simply predates them. Reporting them as
    # differences told a reader that a pair in which both ran one part had changed
    # the parallel count.
    assert Comparison.differences(a.inputs, b.inputs) == []
    assert Comparison.unrecorded(a.inputs, b.inputs) == ["scheduling", "sensors"]
  end

  test "an input both runs record and disagree about is the difference it looks like" do
    a = side("barrier", %{inputs: %{"scheduling" => "barrier"}})
    b = side("lagged", %{inputs: %{"scheduling" => "lagged"}})

    assert Comparison.differences(a.inputs, b.inputs) == ["scheduling"]
    assert Comparison.unrecorded(a.inputs, b.inputs) == []
  end

  # A part carries the id of the stream that collected its steps, and that id is
  # new for every run: compared whole, "parts" differed between any two runs, and
  # the page told a reader they had changed the division when they had not.
  test "the division is compared by its shape, not by each part's stream" do
    one = [%{"index" => 0, "of" => 1, "phase" => "eval", "stream" => "11111111"}]
    same = [%{"index" => 0, "of" => 1, "phase" => "eval", "stream" => "22222222"}]
    more = [%{"index" => 0, "of" => 2, "phase" => "eval", "stream" => "33333333"}]

    a = side("first", %{inputs: %{"parts" => one}})
    b = side("second", %{inputs: %{"parts" => same}})
    c = side("divided", %{inputs: %{"parts" => more}})

    assert Comparison.differences(a.inputs, b.inputs) == []
    assert Comparison.differences(a.inputs, c.inputs) == ["parts"]
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
