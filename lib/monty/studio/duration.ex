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

  `nil` is a run that has not been timed, and answers `0 µs` rather than a blank:
  the row exists either way.
  """
  @spec humanize(non_neg_integer() | nil) :: String.t()
  def humanize(nil), do: "0 µs"
  def humanize(us) when us < 1_000, do: "#{us} µs"
  def humanize(us) when us < 1_000_000, do: "#{decimal(us / 1_000)} ms"
  def humanize(us) when us < 60_000_000, do: "#{decimal(us / 1_000_000)} s"

  def humanize(us) when us < 3_600_000_000,
    do: minutes(div(us, 60_000_000), div(rem(us, 60_000_000), 1_000_000))

  def humanize(us), do: hours(div(us, 3_600_000_000), div(rem(us, 3_600_000_000), 60_000_000))

  defp minutes(minutes, 0), do: "#{minutes} min"
  defp minutes(minutes, seconds), do: "#{minutes} min #{seconds} s"

  defp hours(hours, 0), do: "#{hours} h"
  defp hours(hours, minutes), do: "#{hours} h #{minutes} min"

  # One decimal, and none when the decimal is zero: "2.4 s" and "38 s", never
  # "38.0 s".
  defp decimal(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end
end
