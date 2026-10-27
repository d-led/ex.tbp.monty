defmodule Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTrackerTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection

  # Translated from Monty's `evidence_slope_tracker_test.py`. The window is
  # three steps and the minimum age two, so a hypothesis can be considered for
  # removal on its second update — the smallest numbers that show the behaviour.
  defp tracker, do: EvidenceSlopeTracker.new(window_size: 3, min_age: 2)

  defp update!(tracker, values, opts \\ []) do
    assert {:ok, tracker} = EvidenceSlopeTracker.update(tracker, values, opts)
    tracker
  end

  describe "an empty tracker" do
    test "has nothing, and answers with nothing" do
      tracker = tracker()

      assert EvidenceSlopeTracker.total_size(tracker) == 0
      assert EvidenceSlopeTracker.removable_indices_mask(tracker) == []
      assert EvidenceSlopeTracker.hyp_ages(tracker) == []
      assert EvidenceSlopeTracker.calculate_slopes(tracker) == []
    end
  end

  describe "adding hypotheses" do
    test "gives each an empty window and an age of zero" do
      tracker = EvidenceSlopeTracker.add_hyp(tracker(), 2)

      assert EvidenceSlopeTracker.total_size(tracker) == 2
      assert tracker.evidence == [[nil, nil, nil], [nil, nil, nil]]
      assert EvidenceSlopeTracker.hyp_ages(tracker) == [0, 0]
    end

    test "a hypothesis that has never been updated has no slope to report" do
      tracker = EvidenceSlopeTracker.add_hyp(tracker(), 1)

      assert EvidenceSlopeTracker.calculate_slopes(tracker) == [nil]
    end
  end

  describe "updating" do
    test "slides the window and records the new value" do
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(2)
        |> update!([1.0, 2.0])
        |> update!([2.0, 3.0])
        |> update!([3.0, 4.0])

      assert tracker.evidence == [[1.0, 2.0, 3.0], [2.0, 3.0, 4.0]]
      assert EvidenceSlopeTracker.hyp_ages(tracker) == [3, 3]
    end

    test "keeps only the most recent values in the window" do
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(1)
        |> update!([0.0])
        |> update!([3.0])
        |> update!([5.0])
        |> update!([4.0])
        |> update!([3.0])

      assert tracker.evidence == [[5.0, 4.0, 3.0]]

      # (−1 + −1) / 2: the slope is falling one unit per step.
      assert [slope] = EvidenceSlopeTracker.calculate_slopes(tracker)
      assert_in_delta slope, -1.0, 1.0e-9
    end

    test "every hypothesis must be given a value, or none is" do
      tracker = EvidenceSlopeTracker.add_hyp(tracker(), 2)

      assert EvidenceSlopeTracker.update(tracker, [1.0]) == {:error, :wrong_number_of_values}
    end
  end

  describe "the slope" do
    test "is the average of the window's steps" do
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(1)
        |> update!([1.0])
        |> update!([2.0])
        |> update!([3.0])

      assert [slope] = EvidenceSlopeTracker.calculate_slopes(tracker)
      assert_in_delta slope, 1.0, 1.0e-9
    end

    test "is per channel, so more sensors do not look like faster learning" do
      # Evidence rises 2.0 → 3.0 with two channels, then 3.0 → 4.5 with three:
      # the per-channel rate is 0.5 a step throughout, where an unnormalised
      # slope would read 1.25.
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(1)
        |> update!([2.0], num_channels: 2)
        |> update!([3.0], num_channels: 2)
        |> update!([4.5], num_channels: 3)

      assert [slope] = EvidenceSlopeTracker.calculate_slopes(tracker)
      assert_in_delta slope, 0.5, 1.0e-9
    end
  end

  describe "removing hypotheses" do
    test "removes exactly the named ones, keeping the rest in order" do
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(3)
        |> update!([1.0, 2.0, 3.0])
        |> EvidenceSlopeTracker.remove_hyp([1])

      assert EvidenceSlopeTracker.total_size(tracker) == 2
      assert tracker.evidence == [[nil, nil, 1.0], [nil, nil, 3.0]]
    end

    test "clearing forgets every hypothesis but not the tracker's settings" do
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(4)
        |> update!([1.0, 2.0, 3.0, 4.0])
        |> EvidenceSlopeTracker.clear_hyp()

      assert EvidenceSlopeTracker.total_size(tracker) == 0
      assert tracker.evidence == []
      assert tracker.ages == []
      assert tracker.window_size == 3
    end
  end

  describe "choosing which hypotheses to keep" do
    test "age is what makes a hypothesis removable" do
      tracker = tracker() |> EvidenceSlopeTracker.add_hyp(3)
      tracker = %{tracker | ages: [1, 2, 3]}

      assert EvidenceSlopeTracker.removable_indices_mask(tracker) == [false, true, true]
    end

    test "a falling hypothesis is dropped, a young one is not" do
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(4)
        |> update!([1.0, 2.0, 3.0, 3.0])
        |> update!([2.0, 2.0, 2.0, 2.0])
        |> update!([3.0, 2.0, 1.0, 1.0])

      # Slopes are 1, 0, −1, −1; the last hypothesis is too young to remove.
      tracker = %{tracker | ages: [3, 3, 3, 1]}

      selection = EvidenceSlopeTracker.select_hypotheses(tracker, -0.5)

      assert HypothesesSelection.ids_to_retain(selection) == [0, 1, 3]
      assert HypothesesSelection.ids_to_remove(selection) == [2]
    end

    test "a threshold above every slope still keeps the young hypotheses" do
      tracker =
        tracker()
        |> EvidenceSlopeTracker.add_hyp(2)
        |> update!([1.0, 1.0])
        |> update!([2.0, 2.0])
        |> update!([3.0, 3.0])

      tracker = %{tracker | ages: [2, 1]}
      selection = EvidenceSlopeTracker.select_hypotheses(tracker, 100.0)

      assert HypothesesSelection.ids_to_retain(selection) == [1]
    end
  end
end
