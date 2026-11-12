defmodule Monty.Studio.Duration do
  @moduledoc """
  A duration, in the unit a person would say it in.

  Microseconds are what a run measures in and what the record keeps, but
  "361250689 µs" is not a number anyone reads: it is a number they convert. This
  answers the conversion — milliseconds under a second, seconds under a minute,
  minutes and hours above it, and never more precision than the answer deserves.
  """

  @doc """
  `microseconds` as a person would say it.

  `nil` is a duration nobody measured, and answers a dash: a table that printed
  a nought for it said "this took no time" about a run that had been stepping
  for an hour. `of_run/1` is the question a table actually asks.
  """
  @spec humanize(non_neg_integer() | nil) :: String.t()
  def humanize(nil), do: "—"
  def humanize(us) when us < 1_000, do: "#{us}µs"
  def humanize(us) when us < 1_000_000, do: "#{decimal(us / 1_000)}ms"
  def humanize(us) when us < 60_000_000, do: "#{decimal(us / 1_000_000)}s"

  def humanize(us) when us < 3_600_000_000,
    do: minutes(div(us, 60_000_000), div(rem(us, 60_000_000), 1_000_000))

  def humanize(us), do: hours(div(us, 3_600_000_000), div(rem(us, 3_600_000_000), 60_000_000))

  @doc """
  How long a run has taken: its elapsed time while it is still going, and what
  the record says once it has stopped.

  `duration_us` is written when a run closes (`RunHistory.finish/3`), so a row
  that is still stepping holds the column's default nought — and a table that
  printed that column said "0µs" about a run an hour into its work. The elapsed
  time is the same quantity the record will keep (it is `finished_at −
  started_at` when it settles), so the number only stops growing.
  """
  @spec of_run(map()) :: String.t()
  def of_run(%{status: status, started_at: %DateTime{} = started})
      when status in ["queued", "running"],
      do: humanize(since(started))

  def of_run(%{duration_us: us}) when is_integer(us) and us > 0, do: humanize(us)
  def of_run(_run), do: "—"

  @doc """
  The same answer as a number, for a page that has to put it *in* a row.

  A LiveView comprehension re-renders a row when the item changes, not when
  something the row's body reads changes: a table of runs therefore has to carry
  the elapsed time in the record it draws, or the cell stands still until the
  collection does.
  """
  @spec elapsed_us(map()) :: non_neg_integer()
  def elapsed_us(%{status: status, started_at: %DateTime{} = started})
      when status in ["queued", "running"],
      do: since(started)

  def elapsed_us(%{duration_us: us}) when is_integer(us) and us > 0, do: us
  def elapsed_us(_run), do: 0

  defp since(%DateTime{} = started),
    do: max(DateTime.diff(DateTime.utc_now(), started, :microsecond), 0)

  # A number and its unit are one token ("38.3s", not "38.3 s"): a column of
  # durations then reads as a column of numbers. Two units keep a space, because
  # "1min 18s" is two measures and "1min18s" is a puzzle.
  defp minutes(minutes, 0), do: "#{minutes}min"
  defp minutes(minutes, seconds), do: "#{minutes}min #{seconds}s"

  defp hours(hours, 0), do: "#{hours}h"
  defp hours(hours, minutes), do: "#{hours}h #{minutes}min"

  # One decimal, and none when the decimal is zero: "2.4 s" and "38 s", never
  # "38.0 s".
  defp decimal(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end
end
