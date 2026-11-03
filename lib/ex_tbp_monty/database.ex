defmodule ExTbpMonty.Database do
  @moduledoc """
  Which database this instance keeps its runs in, decided when it starts.

  Postgres when `DATABASE_URL` names one — a deployment that has a database
  server says where it is, and that is the whole configuration. Otherwise
  SQLite, in a file: one container, no second service, nothing to point at
  anything. Both drivers are compiled into the release, so one image serves
  either.

  `SQLITE_PATH` moves the file, for a deployment that mounts a volume where it
  wants the runs kept. Without it the file is `ex_tbp_monty.db` in `$HOME`,
  which in the image is the writable volume the release already has.
  """

  @sqlite_file "ex_tbp_monty.db"

  @doc """
  The repo module this instance starts and calls.

  Postgres when `DATABASE_URL` names one, SQLite otherwise; the two are compiled
  repos (`ExTbpMonty.Repo.Postgres`, `ExTbpMonty.Repo.SQLite`) because Ecto
  binds an adapter to a repo at compile time, and `ExTbpMonty.Repo` is the name
  the application calls whichever of them this answers.
  """
  @spec repo_module() :: module()
  def repo_module do
    Application.get_env(:ex_tbp_monty, :repo, ExTbpMonty.Repo.Postgres)
  end

  @doc "The `ExTbpMonty.Repo` configuration for this instance."
  @spec repo() :: keyword()
  def repo do
    case System.get_env("DATABASE_URL") do
      url when url in [nil, ""] -> sqlite()
      url -> postgres(url)
    end
  end

  @doc """
  The Oban engine this instance's database needs.

  SQLite reaches Oban through its own engine; the locking Oban's default engine
  relies on is Postgres's.
  """
  @spec oban_engine() :: module()
  def oban_engine do
    case System.get_env("DATABASE_URL") do
      url when url in [nil, ""] -> Oban.Engines.Lite
      _url -> Oban.Engines.Basic
    end
  end

  @doc "The SQLite file, when SQLite is the database in use."
  @spec sqlite_path() :: Path.t()
  def sqlite_path do
    case System.get_env("SQLITE_PATH") do
      path when path in [nil, ""] ->
        Path.join(System.get_env("HOME") || File.cwd!(), @sqlite_file)

      path ->
        path
    end
  end

  defp sqlite do
    [
      adapter: Ecto.Adapters.SQLite3,
      database: sqlite_path(),
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
      # SQLite writes one transaction at a time, and the studio's own writes —
      # a row per run — share the file with the Oban queue beside them. Waiting
      # for the writer is right; failing with "database is locked" is not.
      busy_timeout: 30_000
    ]
  end

  defp postgres(url) do
    [
      adapter: Ecto.Adapters.Postgres,
      url: url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [])
    ]
  end
end
