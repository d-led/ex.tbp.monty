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
end
