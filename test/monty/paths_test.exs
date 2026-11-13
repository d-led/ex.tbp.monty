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

  describe "a node that was given a name" do
    # Two nodes on one machine must not open one SQLite file, and the runs each
    # writes are its own — so what is a node's hangs off `nodes/<its name>`. What
    # they share is what is downloaded: fetching the same gigabytes twice is the
    # one thing worse than fetching them once.
    setup do
      previous = Application.get_env(:ex_tbp_monty, :data_dir_name)
      Application.put_env(:ex_tbp_monty, :data_dir_name, "monty_127.0.0.1")
      on_exit(fn -> Application.put_env(:ex_tbp_monty, :data_dir_name, previous) end)

      for variable <- ~w(SQLITE_PATH MONTY_LOGS WANDB_DIR MONTY_DATA MONTY_MODELS) do
        Tmp.without_env(variable)
      end

      :ok
    end

    test "keeps its database, its runs and its own output under its own name" do
      node_root = Path.join([Paths.root(), "nodes", "monty_127.0.0.1"])

      assert Paths.data_dir_name() == "monty_127.0.0.1"
      assert Path.dirname(Paths.database()) == node_root
      assert Paths.artifacts() == Path.join(node_root, "runs")
      assert Paths.logs() == Path.join(node_root, "projects")
      assert Paths.wandb() == Path.join(node_root, "wandb")
    end

    test "still shares what was downloaded" do
      assert Paths.data() == Path.join(Paths.root(), "data")
      assert Paths.models() == Path.join(Paths.root(), "models")
      assert Paths.libraries() == Path.join(Paths.data(), "libraries")
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
