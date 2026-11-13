defmodule Monty.Studio.DurationTest do
  @moduledoc """
  A duration is read, not converted: the number the record keeps is microseconds,
  and what a page shows is the unit a person would have said.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Duration

  test "under a second it is milliseconds" do
    assert Duration.humanize(0) == "0µs"
    assert Duration.humanize(850) == "850µs"
    assert Duration.humanize(1_000) == "1ms"
    assert Duration.humanize(361_250) == "361.3ms"
  end

  test "under a minute it is seconds, and it does not say .0" do
    assert Duration.humanize(2_400_000) == "2.4s"
    assert Duration.humanize(38_000_000) == "38s"
    assert Duration.humanize(59_900_000) == "59.9s"
  end

  test "over a minute it is minutes and seconds" do
    assert Duration.humanize(61_000_000) == "1min 1s"
    assert Duration.humanize(361_250_689) == "6min 1s"
    assert Duration.humanize(120_000_000) == "2min"
  end

  test "over an hour it is hours and minutes" do
    assert Duration.humanize(3_600_000_000) == "1h"
    assert Duration.humanize(3_930_000_000) == "1h 5min"
  end

  test "a run that was never timed says nothing rather than nought" do
    # A table that printed "0µs" for an untimed run said "this took no time"
    # about a run that was stepping.
    assert Duration.humanize(nil) == "—"
  end

  describe "a run's own duration" do
    test "is the elapsed time while it is still going" do
      started = DateTime.add(DateTime.utc_now(), -90, :second)

      # `duration_us` is written when the run closes, so a running row holds the
      # column's default nought: the answer is how long ago it started.
      assert Duration.of_run(%{status: "running", started_at: started, duration_us: 0}) ==
               "1min 30s"
    end

    # A run nobody has claimed has not begun, so it has no elapsed time — what it
    # has is the wait, and that is counted from the moment it was asked for. The
    # quantity is what this states: the string is `humanize/1`'s business, and how
    # many tenths of a second the machine took to reach the assertion is not.
    test "is the wait of a run nobody has claimed yet" do
      asked = DateTime.add(DateTime.utc_now(), -40, :second)
      queued = %{status: "queued", inserted_at: asked, duration_us: 0}

      assert_in_delta Duration.elapsed_us(queued), 40_000_000, 5_000_000
      refute Duration.of_run(queued) == "—"
      assert Duration.of_run(queued) =~ ~r/[0-9]/
    end

    test "is a dash for a queued run with no asked-at clock and no duration" do
      assert Duration.of_run(%{status: "queued", duration_us: 0}) == "—"
    end

    test "is what the record says once it has stopped" do
      started = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert Duration.of_run(%{status: "finished", started_at: started, duration_us: 38_000_000}) ==
               "38s"
    end

    test "is a dash for a run with no start and no duration" do
      assert Duration.of_run(%{status: "failed", started_at: nil, duration_us: 0}) == "—"
    end
  end
end
