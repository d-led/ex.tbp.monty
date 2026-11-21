defmodule Monty.Studio.LocalClock do
  @moduledoc """
  The clock a person reads: a recorded instant, on this machine's offset, to the
  millisecond.

  A run records UTC, because a record must not mean something different depending
  on where it was written. A log is read by someone sitting in one place, and a
  line they cannot line up with their own afternoon is a timestamp that only
  looks like one. Both the page and the log file ask here, so the two never
  disagree about what time it is.
  """

  @typedoc """
  An instant: as the record keeps it, and as the page shows it.

  `instant` stays UTC and unprefixed — it is what a record is compared against;
  `clock` is the same moment on the reader's clock, milliseconds included.
  """
  @type stamp :: %{instant: String.t(), clock: String.t()}

  @doc "This instant, as a record keeps it and as a page shows it."
  @spec stamp(DateTime.t()) :: stamp()
  def stamp(at) do
    here = at |> DateTime.add(offset(), :second) |> DateTime.truncate(:millisecond)

    %{
      instant: DateTime.to_iso8601(at),
      clock: Calendar.strftime(here, "%H:%M:%S") <> millis(here)
    }
  end

  @doc "Now, in the same shape."
  @spec now() :: stamp()
  def now, do: stamp(DateTime.utc_now())

  @doc """
  This machine's offset from UTC, in seconds, daylight saving included.

  `:calendar` knows it and needs no time-zone database, which is the difference
  between a container that can tell the time and one that cannot start.
  """
  @spec offset() :: integer()
  def offset, do: offset(&:calendar.local_time/0, &:calendar.universal_time/0)

  # The offset is the distance between two *different* clocks, so the second one
  # is read twice and the answer is only used when it did not move: a machine
  # busy enough to delay this process between the reads answered an offset a
  # second wrong, and two lines about the same instant carried clocks a second
  # apart — which is how a CI suite came to fail on a step whose line did not
  # begin with its own timestamp.
  #
  # The pair is a parameter so a test can hand in clocks that straddle a second.
  @doc false
  @spec offset((-> :calendar.datetime()), (-> :calendar.datetime())) :: integer()
  def offset(local, utc) do
    before = utc.()
    here = local.()

    case utc.() do
      ^before -> seconds(here) - seconds(before)
      _ticked -> offset(local, utc)
    end
  end

  defp seconds(moment), do: :calendar.datetime_to_gregorian_seconds(moment)

  # Three digits, because a step is a few milliseconds and a log of a run is read
  # to see how long one took: seconds alone round every step in a run to the same
  # instant. `strftime`'s `%f` is microseconds, so this pads its own.
  defp millis(at) do
    at.microsecond
    |> elem(0)
    |> div(1000)
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
    |> then(&("." <> &1))
  end
end
