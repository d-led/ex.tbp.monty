defmodule Monty.Studio.BenchReportTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.{BenchReport, Summary}

  defp sample(durations, deadline_hits \\ 0) do
    %{
      durations: durations,
      summary: %Summary{duration_us: Enum.sum(durations), deadline_hits: deadline_hits}
    }
  end

  describe "summarise/3" do
    test "the middle repetition is the total, because one unlucky run is not the code" do
      report =
        BenchReport.summarise("experiment", [sample([100]), sample([10_000]), sample([300])], 1)

      assert report.total_us == 300
    end

    test "the tail of the steps survives: p95 and the maximum, not just the mean" do
      # Nine steps at a second each and one that took sixteen.
      report =
        BenchReport.summarise(
          "experiment",
          [sample(List.duplicate(1_000_000, 9) ++ [16_000_000])],
          10
        )

      assert report.p50_us == 1_000_000
      assert report.p95_us == 16_000_000
      assert report.max_us == 16_000_000
      assert report.mean_us > 1_000_000
    end

    test "the deadline hits are the worst repetition's, not a sum over repetitions" do
      report = BenchReport.summarise("experiment", [sample([1], 2), sample([1], 5)], 1)

      assert report.deadline_hits == 5
    end

    test "a run that ended early is still reported at the size it was asked for" do
      report = BenchReport.summarise("experiment", [sample([1, 2])], 20)

      assert report.steps == 20
      assert report.runnable?
    end
  end

  describe "table/1" do
    # The shape that started this: a measurement whose numbers are wider than
    # the headings, which used to run into each other.
    defp wide do
      %{
        experiment: "base_config_10distinctobj_dist_agent",
        steps: 20,
        total_us: 71_676_068,
        mean_us: 3_306_733.8,
        p50_us: 2_799_536,
        p95_us: 6_580_530,
        max_us: 11_756_853,
        deadline_hits: 0,
        runnable?: true
      }
    end

    test "a heading and a row per measurement" do
      assert [head, _row] = BenchReport.table([wide()])
      assert head =~ "experiment"
      assert head =~ "µs/step"
    end

    test "a number wider than its heading does not run into the next one" do
      [head, row] = BenchReport.table([wide()])

      assert String.length(row) == String.length(head)
    end

    test "the row reads as the headings say it should" do
      [_head, row] = BenchReport.table([wide()])

      assert String.split(row) == [
               "base_config_10distinctobj_dist_agent",
               "20",
               "71676068",
               "3306733.8",
               "2799536",
               "6580530",
               "11756853",
               "0"
             ]
    end

    test "every row is as wide as the widest one, so a short experiment does not shift the numbers" do
      small = %{
        wide()
        | experiment: "x",
          total_us: 1,
          mean_us: 1.0,
          p50_us: 1,
          p95_us: 1,
          max_us: 1
      }

      [_head, first, second] = BenchReport.table([wide(), small])

      assert String.length(first) == String.length(second)
    end
  end

  describe "not_runnable/2" do
    test "an experiment that would not start says that nothing was measured" do
      report = BenchReport.not_runnable("broken", 20)

      assert report.experiment == "broken"
      assert report.steps == 20

      refute report.runnable?
      assert report.total_us == 0
      assert report.max_us == 0
    end
  end
end
