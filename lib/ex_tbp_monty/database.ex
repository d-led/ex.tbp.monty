defmodule ExTbpMonty.Database do
  @moduledoc """
  Which database this instance keeps its runs in, decided when it starts.

  Postgres when `DATABASE_URL` names one — a deployment that has a database
  server says where it is, and that is the whole configuration. Otherwise
  SQLite, in a file: one container, no second service, nothing to point at
  anything. Both drivers are compiled into the release, so one image serves
  either.

  `SQLITE_PATH` moves the file, for a deployment that mounts a volume where it
  wants the runs kept. Without it the file is `ex_tbp_monty.db` in the folder
  `Monty.Paths` names — the operating system's per-user application-data
  directory, which in the image is under `HOME=/app/priv`, the writable volume
  the release already has.
  """

  @doc """
  The repo module this instance starts and calls.

  Postgres when `DATABASE_URL` names one, SQLite otherwise; the two are compiled
  repos (`ExTbpMonty.Repo.Postgres`, `ExTbpMonty.Repo.SQLite`) because Ecto
  binds an adapter to a repo at compile time, and `ExTbpMonty.Repo` is the name
  the application calls whichever of them this answers.
  """
  @spec repo_module() :: module()
  def repo_module do
    # A configured answer wins — `dev` and `test` name the Postgres they have —
    # and nothing else is configured, so an installation that does not know this
    # application gets the question asked of the environment rather than of a
    # default that was written when Postgres was the only answer.
    Application.get_env(:ex_tbp_monty, :repo) || from_environment()
  end

  defp from_environment do
    case postgres_url() do
      nil -> ExTbpMonty.Repo.SQLite
      _url -> ExTbpMonty.Repo.Postgres
    end
  end

  # `nil` for a database server that was not named, which is also the question
  # `repo/0` and `oban_engine/0` ask: one predicate, so the module that is
  # started and the configuration it is started with cannot disagree.
  defp postgres_url do
    case System.get_env("DATABASE_URL") do
      url when url in [nil, ""] -> nil
      url -> url
    end
  end

  @doc "The `ExTbpMonty.Repo` configuration for this instance."
  @spec repo() :: keyword()
  def repo do
    case postgres_url() do
      nil -> sqlite()
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
    case postgres_url() do
      nil -> Oban.Engines.Lite
      _url -> Oban.Engines.Basic
    end
  end

  @doc "The SQLite file, when SQLite is the database in use."
  @spec sqlite_path() :: String.t()
  def sqlite_path, do: Monty.Paths.database()

  defp sqlite do
    [
      adapter: Ecto.Adapters.SQLite3,
      database: sqlite_path(),
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
      # The default journal takes an exclusive lock for the length of a write,
      # so a page reading the run list waits for every row the queue beside it
      # writes. WAL lets a reader keep reading while one writer commits, which
      # is exactly this studio's traffic: a page per reader, a row per run.
      #
      # The cost is two files beside the database (`-wal`, `-shm`) and a
      # dependency on shared memory, which a network filesystem may not offer —
      # this file lives in the per-user application-data directory or on a
      # container's own volume, so it does.
      journal_mode: :wal,
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
