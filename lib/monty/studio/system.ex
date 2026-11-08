defmodule Monty.Studio.System do
  @moduledoc """
  What this instance is running with, and which of those numbers a page cannot
  change.

  A number like the database's write timeout is not a setting: `DBConnection`
  reads it when the pool starts. A page that offered to change it would be lying,
  so this module answers it read-only, with where it came from — the alternative
  is what happens today, where the only way to learn the timeout is to read a
  `DBConnection.ConnectionError` after a run has died of it.
  """

  @doc """
  One row per fact: what it is called, what it is, and where it came from when
  that is not obvious.
  """
  @spec facts() :: [%{label: String.t(), value: String.t(), note: String.t() | nil}]
  def facts do
    repo = ExTbpMonty.Database.repo_module()
    config = Application.get_env(:ex_tbp_monty, repo, [])

    [
      %{
        label: "Database",
        value: inspect(repo),
        note: "chosen at boot from the environment"
      },
      %{
        label: "Connection queue target",
        value: milliseconds(Keyword.get(config, :queue_target)),
        note: "config/config.exs — a change needs a restart"
      },
      %{label: "Pool size", value: number(Keyword.get(config, :pool_size)), note: nil},
      %{label: "Elixir", value: System.version(), note: nil},
      %{label: "OTP", value: otp(), note: nil},
      %{label: "Application", value: version(), note: nil}
    ]
  end

  defp milliseconds(nil), do: "the adapter's default"

  defp milliseconds(value) when is_integer(value),
    do: "#{value} ms (#{Float.round(value / 1000, 1)} s)"

  defp number(nil), do: "—"
  defp number(value), do: to_string(value)

  defp otp, do: :erlang.system_info(:otp_release) |> to_string()

  defp version do
    case Application.spec(:ex_tbp_monty, :vsn) do
      nil -> "—"
      vsn -> to_string(vsn)
    end
  end
end
