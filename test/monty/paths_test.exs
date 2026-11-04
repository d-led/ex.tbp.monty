defmodule Monty.PathsTest do
  # These read and write the shell's variables, which are the machine's.
  use ExUnit.Case, async: false

  alias Monty.Paths
  alias Monty.Test.Tmp

  describe "the folder this application keeps its things in" do
    # An installed application has no writable `priv/`, so every default hangs
    # off the directory the operating system gives a per-user application.
    test "is the one the operating system names for this application" do
      assert Paths.root() == :filename.basedir(:user_data, "ex-tbp-monty")
    end

    test "holds the runs, the memory and the database until something says otherwise" do
      Tmp.without_env("MONTY_DATA")
      Tmp.without_env("MONTY_LIBRARIES")
      Tmp.without_env("SQLITE_PATH")

      assert Path.dirname(Paths.data()) == Paths.root()
      assert Path.dirname(Paths.libraries()) == Paths.data()
      assert Path.dirname(Paths.database()) == Paths.root()
      assert String.starts_with?(Paths.artifacts(), Paths.root())
      assert String.starts_with?(Paths.wandb(), Paths.root())
    end
  end

  describe "a variable that is set" do
    test "is the answer, so a container and CI keep their own layout" do
      Tmp.system_env("MONTY_DATA", "/srv/monty/data")
      Tmp.system_env("SQLITE_PATH", "/srv/monty/runs.db")

      assert Paths.data() == "/srv/monty/data"
      assert Paths.database() == "/srv/monty/runs.db"
    end

    # An empty variable is a shell that exported a name and no value. Reading it
    # as a path would put the database in the working directory.
    test "only counts when it has a value" do
      Tmp.system_env("SQLITE_PATH", "")

      assert Paths.database() == Path.join(Paths.root(), "ex_tbp_monty.db")
    end

    test "is expanded rather than kept relative" do
      Tmp.system_env("MONTY_DATA", "./data")

      assert Paths.data() == Path.expand("./data")
    end
  end
end
