defmodule Monty.Studio.LocalClockTest do
  @moduledoc """
  The clock a person reads, taken from two clocks that must agree.

  A run records UTC and a log is read in the reader's own zone, so the offset
  between them is measured here — from `:calendar`'s local time and its universal
  time, which are two reads of two clocks rather than one reading of the
  difference.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.LocalClock

  describe "this machine's offset" do
    test "is the distance between a local reading and the universal one beside it" do
      assert LocalClock.offset(
               always({{2026, 11, 9}, {23, 41, 27}}),
               always({{2026, 11, 9}, {22, 41, 27}})
             ) ==
               3600
    end

    test "is measured again when the universal clock ticked between the two readings" do
      # The local reading was taken while the universal one was still at 22:41:27
      # and the second reading has moved on: the local value may belong to either
      # second, and an offset a second wrong puts two lines about one instant a
      # second apart. The readings are taken again rather than trusted.
      utc =
        readings([
          {{2026, 11, 9}, {22, 41, 27}},
          {{2026, 11, 9}, {22, 41, 28}},
          {{2026, 11, 9}, {22, 41, 28}},
          {{2026, 11, 9}, {22, 41, 28}}
        ])

      local = readings([{{2026, 11, 9}, {23, 41, 27}}, {{2026, 11, 9}, {23, 41, 29}}])

      assert LocalClock.offset(local, utc) == 3601
    end
  end

  describe "a recorded instant" do
    test "is shown on this machine's clock, to the millisecond" do
      stamp = LocalClock.stamp(~U[2026-11-09 22:41:27.137962Z])

      assert stamp.instant == "2026-11-09T22:41:27.137962Z"
      assert stamp.clock =~ ~r/^\d\d:\d\d:\d\d\.137$/
    end
  end

  # A clock that answers the same moment every time it is read.
  defp always(moment), do: fn -> moment end

  # A clock that answers each moment in turn, and keeps answering the last.
  defp readings(moments) do
    counter =
      start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> moments end]}})

    fn ->
      Agent.get_and_update(counter, fn
        [only] -> {only, [only]}
        [moment | rest] -> {moment, rest}
      end)
    end
  end
end
