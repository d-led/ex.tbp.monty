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

  test "a run that was never timed still says something" do
    assert Duration.humanize(nil) == "0µs"
  end
end
