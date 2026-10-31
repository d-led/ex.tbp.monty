defmodule Monty.Studio.DurationTest do
  @moduledoc """
  A duration is read, not converted: the number the record keeps is microseconds,
  and what a page shows is the unit a person would have said.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Duration

  test "under a second it is milliseconds" do
    assert Duration.humanize(0) == "0 µs"
    assert Duration.humanize(850) == "850 µs"
    assert Duration.humanize(1_000) == "1 ms"
    assert Duration.humanize(361_250) == "361.3 ms"
  end

  test "under a minute it is seconds, and it does not say .0" do
    assert Duration.humanize(2_400_000) == "2.4 s"
    assert Duration.humanize(38_000_000) == "38 s"
    assert Duration.humanize(59_900_000) == "59.9 s"
  end

  test "over a minute it is minutes and seconds" do
    assert Duration.humanize(61_000_000) == "1 min 1 s"
    assert Duration.humanize(361_250_689) == "6 min 1 s"
    assert Duration.humanize(120_000_000) == "2 min"
  end

  test "over an hour it is hours and minutes" do
    assert Duration.humanize(3_600_000_000) == "1 h"
    assert Duration.humanize(3_930_000_000) == "1 h 5 min"
  end

  test "a run that was never timed still says something" do
    assert Duration.humanize(nil) == "0 µs"
  end
end
