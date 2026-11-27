defmodule Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTrackerMontyTest do
  @moduledoc """
  Monty's own cases for `EvidenceSlopeTracker`, translated.

  Each test names the case in
  `tests/unit/frameworks/models/evidence_matching/evidence_slope_tracker_test.py`
  it translates. The tracker is Monty's: a window of three evidence values per
  hypothesis, and a hypothesis removable once it is two updates old.

  Three things are stated differently because the port states them differently,
  and each says so where it happens:

    * Monty's window is a numpy array of NaN, and its cases read `_evidence_buffer`
      and `_hyp_age` directly. The port keeps the window as `hypotheses *
      window_size` floats in ring order, and answers a hypothesis with no two
      observations as `nil` rather than NaN — so "the window is empty" is
      asserted as `nil` slopes, which is what empty means downstream.
    * `update` on the wrong number of values answers `{:error,
      :wrong_number_of_values}` instead of raising `ValueError`: the caller is a
      learning module mid-episode, and Monty's exception and this tuple say the
      same thing.
    * Ages are a field of the struct, so forcing them (Monty assigns `_hyp_age[:]
      = ...`) is `%{tracker | ages: ...}` — the same act, without a mock.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection

  defp tracker, do: EvidenceSlopeTracker.new(window_size: 3, min_age: 2)

  # test_empty_tracker_returns_valid_results
  test "an empty tracker answers an empty slope, age and removal question" do
    tracker = tracker()

    assert EvidenceSlopeTracker.total_size(tracker) == 0
    assert EvidenceSlopeTracker.removable_indices_mask(tracker) == []
    assert EvidenceSlopeTracker.hyp_ages(tracker) == []
    assert EvidenceSlopeTracker.calculate_slopes(tracker) == []
  end

  # test_add_hypotheses_initializes
  test "a new hypothesis has an empty window and an age of zero" do
    tracker = tracker() |> EvidenceSlopeTracker.add_hyp(2)

    assert EvidenceSlopeTracker.total_size(tracker) == 2
    assert EvidenceSlopeTracker.hyp_ages(tracker) == [0, 0]

    # An empty window has no two observations to differ: the slope is `nil`.
    assert EvidenceSlopeTracker.calculate_slopes(tracker) == [nil, nil]
  end

  # test_update_correctly_shifts_and_sets_values
  test "three updates leave each window holding the last three values, aged three" do
    tracker = tracker() |> EvidenceSlopeTracker.add_hyp(2)

    tracker =
      Enum.reduce([[1.0, 2.0], [2.0, 3.0], [3.0, 4.0]], tracker, fn values, tracker ->
        put_values(tracker, values)
      end)

    assert EvidenceSlopeTracker.hyp_ages(tracker) == [3, 3]

    # The windows are [1, 2, 3] and [2, 3, 4]: both rise by one a step.
    assert EvidenceSlopeTracker.calculate_slopes(tracker) == [1.0, 1.0]
  end

  defp put_values(tracker, values) do
    {:ok, tracker} = EvidenceSlopeTracker.update(tracker, values)
    tracker
  end

  # test_update_more_than_window_size_slides_correctly
  test "values older than the window do not reach the slope" do
    tracker = tracker() |> EvidenceSlopeTracker.add_hyp(1)

    # Five updates against a window of three: [5, 4, 3] is what is left.
    tracker = Enum.reduce([0.0, 3.0, 5.0, 4.0, 3.0], tracker, &put_values(&2, [&1]))

    # (3 - 4) + (4 - 5) over two steps is -1.
    assert [slope] = EvidenceSlopeTracker.calculate_slopes(tracker)
    assert_in_delta slope, -1.0, 1.0e-9
  end

  # test_update_raises_on_wrong_length
  test "an update with one value too few is refused" do
    tracker = tracker() |> EvidenceSlopeTracker.add_hyp(2)

    assert EvidenceSlopeTracker.update(tracker, [1.0]) ==
             {:error, :wrong_number_of_values}
  end

  # test_remove_hypotheses_removes_correct_indices
  test "removing a hypothesis keeps the others in their order" do
    tracker =
      tracker()
      |> EvidenceSlopeTracker.add_hyp(3)
      |> put_values([1.0, 2.0, 3.0])
      |> EvidenceSlopeTracker.remove_hyp([1])

    assert EvidenceSlopeTracker.total_size(tracker) == 2
    assert EvidenceSlopeTracker.hyp_ages(tracker) == [1, 1]

    # The hypotheses that are left are still one step old and still have no two
    # observations between them, which is what a removal that shifted the wrong
    # rows would not give.
    assert EvidenceSlopeTracker.calculate_slopes(tracker) == [nil, nil]
  end

  # test_clear_hyp_removes_all_hypotheses
  test "clearing forgets every hypothesis and keeps the window size" do
    tracker =
      tracker()
      |> EvidenceSlopeTracker.add_hyp(4)
      |> put_values([1.0, 2.0, 3.0, 4.0])

    assert EvidenceSlopeTracker.total_size(tracker) == 4

    cleared = EvidenceSlopeTracker.clear_hyp(tracker)

    assert EvidenceSlopeTracker.total_size(cleared) == 0
    assert EvidenceSlopeTracker.hyp_ages(cleared) == []
    assert cleared.window_size == 3
  end

  # test_calculate_slopes_correctly
  test "a rise of one a step is a slope of one" do
    tracker = tracker() |> EvidenceSlopeTracker.add_hyp(1)

    tracker =
      Enum.reduce([1.0, 2.0, 3.0], tracker, fn value, tracker -> put_values(tracker, [value]) end)

    assert [slope] = EvidenceSlopeTracker.calculate_slopes(tracker)
    assert_in_delta slope, (2.0 - 1.0 + (3.0 - 2.0)) / 2, 1.0e-9
  end

  # test_slope_is_invariant_to_channel_count_change
  test "the slope is per channel, so more channels do not steepen it" do
    # Evidence rises 2.0 to 3.0 over two channels and then 3.0 to 4.5 over three:
    # half a unit per channel per step throughout.
    tracker = tracker() |> EvidenceSlopeTracker.add_hyp(1)

    {:ok, tracker} = EvidenceSlopeTracker.update(tracker, [2.0], num_channels: 2)
    {:ok, tracker} = EvidenceSlopeTracker.update(tracker, [3.0], num_channels: 2)
    {:ok, tracker} = EvidenceSlopeTracker.update(tracker, [4.5], num_channels: 3)

    assert [slope] = EvidenceSlopeTracker.calculate_slopes(tracker)
    assert_in_delta slope, 0.5, 1.0e-9
  end

  # test_removable_indices_mask_matches_min_age
  test "only a hypothesis as old as the minimum age may be removed" do
    tracker = %{(tracker() |> EvidenceSlopeTracker.add_hyp(3)) | ages: [1, 2, 3]}

    assert EvidenceSlopeTracker.removable_indices_mask(tracker) == [false, true, true]
  end

  # test_select_hypotheses_threshold_and_age
  test "a hypothesis is kept for its slope or for being too young to judge" do
    tracker = tracker() |> EvidenceSlopeTracker.add_hyp(4)

    tracker =
      Enum.reduce(
        [[1.0, 2.0, 3.0, 3.0], [2.0, 2.0, 2.0, 2.0], [3.0, 2.0, 1.0, 1.0]],
        tracker,
        fn values, tracker -> put_values(tracker, values) end
      )

    # Slopes are [1, 0, -1, -1]; the last hypothesis is too young to remove.
    tracker = %{tracker | ages: [3, 3, 3, 1]}

    selection = EvidenceSlopeTracker.select_hypotheses(tracker, -0.5)

    assert %HypothesesSelection{} = selection
    assert HypothesesSelection.ids_to_retain(selection) == [0, 1, 3]
    assert HypothesesSelection.ids_to_remove(selection) == [2]
  end
end
