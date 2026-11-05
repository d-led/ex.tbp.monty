defmodule ExTbpMonty.DatabaseTest do
  # These read and write the application's settings and the shell's variables,
  # which are the machine's.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Database
  alias Monty.Test.Tmp

  describe "the database a release starts" do
    # The bug this pins: `repo_module/0` answered a written-in default of
    # Postgres and nothing ever asked the environment, so `runtime.exs` echoed
    # that default back and an installation with no `DATABASE_URL` started
    # Postgres pointing at a SQLite path — the release could not migrate a fresh
    # file, and the image never became healthy.
    test "is a file when no database server is named" do
      Tmp.without_app_env(:repo)
      Tmp.without_env("DATABASE_URL")

      assert Database.repo_module() == ExTbpMonty.Repo.SQLite
      assert Database.repo()[:adapter] == Ecto.Adapters.SQLite3
      # Oban's default engine takes row locks, which a file does not have.
      assert Database.oban_engine() == Oban.Engines.Lite
    end

    test "is the Postgres `DATABASE_URL` names" do
      Tmp.without_app_env(:repo)
      Tmp.system_env("DATABASE_URL", "ecto://monty:monty@localhost/monty")

      assert Database.repo_module() == ExTbpMonty.Repo.Postgres
      assert Database.repo()[:adapter] == Ecto.Adapters.Postgres
      assert Database.oban_engine() == Oban.Engines.Basic
    end

    test "is the one this environment names, whatever the variables say" do
      Tmp.app_env(:repo, ExTbpMonty.Repo.Postgres)
      Tmp.without_env("DATABASE_URL")

      assert Database.repo_module() == ExTbpMonty.Repo.Postgres
    end
  end

  describe "the file's journal" do
    # The default journal mode takes an exclusive lock for the length of a
    # write, so the page listing runs waits behind every row the queue beside it
    # writes — under load that is a wait long enough to be a page that hangs.
    # Asked of a real file rather than of the options list: the option is only
    # worth anything if the database applies it.
    test "lets a reader read while a writer writes" do
      Tmp.without_app_env(:repo)
      Tmp.without_env("DATABASE_URL")
      path = Path.join(Tmp.dir("sqlite-journal"), "runs.db")

      # One connection, because the pragma that leaves the mode again only
      # applies while nothing else has the file open.
      options = Database.repo() |> Keyword.merge(database: path, name: nil, pool_size: 1)
      {:ok, repo} = start_supervised({ExTbpMonty.Repo.SQLite, options})

      assert %{rows: [["wal"]]} = Ecto.Adapters.SQL.query!(repo, "PRAGMA journal_mode")

      # And out of it again before the test ends. A database closed while in WAL
      # mode finalises its journal after its process has gone — the handle is
      # released when its memory is collected — so removing the directory raced a
      # journal being written back, and a CI run lost it with "file already
      # exists". Leaving the mode is what removes the journal, here and now.
      assert %{rows: [["delete"]]} =
               Ecto.Adapters.SQL.query!(repo, "PRAGMA journal_mode=delete")

      assert :ok = stop_supervised(ExTbpMonty.Repo.SQLite)
    end
  end
end
