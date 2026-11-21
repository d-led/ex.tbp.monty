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

  # A part has no summary: its numbers are the statistics file it wrote, which is
  # the same format a whole run's merged file is made of. So a side is built from
  # the rows — one episode counted once, however many modules wrote about it, and
  # each module's exits as its own tally.
  test "a side read from statistics counts an episode once, and each module's exits" do
    first = %{"episode_seed" => "11", "num_steps" => "14", "time" => "1.5"}
    second = %{"episode_seed" => "12", "num_steps" => "20", "time" => "2.0"}

    stats = %{
      rows: [
        Map.merge(first, %{"primary_performance" => "correct", "lm_id" => "LM_0"}),
        Map.merge(first, %{"primary_performance" => "correct", "lm_id" => "LM_1"}),
        Map.merge(second, %{"primary_performance" => "time_out", "lm_id" => "LM_0"}),
        Map.merge(second, %{"primary_performance" => "time_out", "lm_id" => "LM_1"})
      ],
      by_seed: %{
        11 => Map.merge(first, %{"primary_performance" => "correct", "lm_id" => "LM_1"}),
        12 => Map.merge(second, %{"primary_performance" => "time_out", "lm_id" => "LM_1"})
      },
      seeded?: true
    }

    side = Comparison.from_stats("part 2", @experiment, %{"part" => "2 of 2"}, stats)

    assert side.summary["steps"] == 34
    assert side.summary["episode_us"] == 3_500_000

    assert side.summary["outcomes"] == %{
             "LM_0" => %{"matched" => 1, "steps_exhausted" => 1},
             "LM_1" => %{"matched" => 1, "steps_exhausted" => 1}
           }

    assert side.summary["outcome"] == %{"LM_0" => "steps_exhausted", "LM_1" => "steps_exhausted"}
  end

  test "two statistics sides are compared on the episode's time, which a summary does not hold" do
    stats = %{
      rows: [
        %{
          "episode_seed" => "11",
          "num_steps" => "14",
          "time" => "1.5",
          "lm_id" => "LM_0",
          "primary_performance" => "correct"
        }
      ],
      by_seed: %{
        11 => %{
          "episode_seed" => "11",
          "num_steps" => "14",
          "time" => "1.5",
          "lm_id" => "LM_0",
          "primary_performance" => "correct"
        }
      },
      seeded?: true
    }

    fast = Comparison.from_stats("part 1", @experiment, %{"part" => "1 of 2"}, stats)
    slow = Comparison.from_stats("part 2", @experiment, %{"part" => "2 of 2"}, stats)

    assert {:ok, %{differences: ["part"], rows: rows}} = Comparison.compare(fast, slow)

    assert %{label: "Episode time", a: 1_500_000, b: 1_500_000} =
             Enum.find(rows, &(&1.label == "Episode time"))
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

  # A lever is a change to what a step's numbers mean, so the side that moved one
  # says what its numbers measured: a run of five sensors served at once costs the
  # slowest of them, and comparing it with a serial run without saying so is
  # comparing two different questions.
  test "each side says what its step numbers measured" do
    sensor_ids = ~w(vf patch_0 patch_1 patch_2 patch_3)

    serial = side("serial", %{inputs: %{"sensors" => sensor_ids, "sensors_step" => "serial"}})

    concurrent =
      side("concurrent", %{inputs: %{"sensors" => sensor_ids, "sensors_step" => "concurrent"}})

    monty = side("monty", %{inputs: %{"sensors" => ["patch_0"]}})

    assert {:ok,
            %{shapes: [{"serial", [serial_sentence]}, {"concurrent", [concurrent_sentence]}]}} =
             Comparison.compare(serial, concurrent)

    assert serial_sentence =~ "their sum"
    assert concurrent_sentence =~ "slowest of them"

    # Nothing to explain about a round of one, so that side says nothing.
    assert {:ok, %{shapes: []}} = Comparison.compare(monty, monty)
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
