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
        label: "Database file",
        value: database_file(repo),
        note: "the run's rows; its pictures and transcript go in the data directory either way"
      },
      %{
        label: "Connection queue target",
        value: milliseconds(Keyword.get(config, :queue_target)),
        note: "config/config.exs — a change needs a restart"
      },
      %{label: "Pool size", value: number(Keyword.get(config, :pool_size)), note: nil},
      %{
        label: "Kernels",
        value: kernels(),
        note: "the Rust NIFs, or the Elixir fallback when they cannot load"
      },
      %{
        label: "Data directory",
        value: Monty.Paths.root(),
        note: "runs, frames and the database live under it"
      },
      %{label: "Elixir", value: System.version(), note: nil},
      %{label: "OTP", value: otp(), note: nil},
      %{label: "Machine", value: machine(), note: nil},
      %{label: "Application", value: version(), note: nil}
    ]
  end

  # A desktop reports what it cannot be asked about otherwise: whether its hot
  # loops are the Rust kernels or the Elixir fallback, where its writes land (a
  # file on a synced volume behaves nothing like a file on disk), and what it is
  # running on. Each of these has cost a session of guessing when it was missing.
  defp kernels do
    if ExTbpMonty.Core.MatcherNif.loaded?() and ExTbpMonty.Core.KdTreeNif.loaded?(),
      do: "native (Rust)",
      else: "Elixir reference paths"
  end

  defp database_file(ExTbpMonty.Repo.SQLite),
    do: "#{Monty.Paths.database()} (#{journal_mode()})"

  # A Postgres may be on this machine or on another — the connection says which,
  # but not whether it is a file here. What is certain is that the rows are not:
  # a run's pictures, transcript and statistics are written under the data
  # directory whichever database holds the rows.
  defp database_file(_server), do: "a database server — the rows are not a file here"

  # WAL is what lets a page read while a run writes, so a report that says the
  # file is where it is should say how it journals as well.
  defp journal_mode do
    case Ecto.Adapters.SQL.query(ExTbpMonty.Repo.SQLite, "PRAGMA journal_mode", []) do
      {:ok, %{rows: [[mode]]}} -> "journal: #{mode}"
      _other -> "journal: unknown"
    end
  rescue
    _not_running -> "journal: unknown"
  end

  defp machine do
    parts = [
      :erlang.system_info(:system_architecture) |> to_string(),
      "#{:erlang.system_info(:schedulers_online)} schedulers"
      | memory()
    ]

    Enum.join(parts, " · ")
  end

  # The machine's memory, not the VM's: a report of "it is slow" is worth
  # nothing beside a number that says the box had 8 GB or 64. os_mon answers it
  # and is already running here; a build without it drops the number rather than
  # the row.
  defp memory do
    case :memsup.get_system_memory_data()[:total_memory] do
      nil -> []
      bytes -> ["#{div(bytes, 1024 * 1024)} MB"]
    end
  rescue
    _no_memsup -> []
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
