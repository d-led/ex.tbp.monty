defmodule ExTbpMonty.NodeFolderTest do
  @moduledoc """
  Where a node keeps its data, and the one case where that is not its own name.

  A clustered node keeps its own folder — two nodes sharing one SQLite file is
  two writers to one lock. The desktop window is the exception the environment
  can name: its node name carries a per-launch instance id, and its data has to
  outlive the launch. `MONTY_NODE_FOLDER` says so, and the empty string is a real
  answer rather than an unset one.

  What a *named* node's folder is called is not asserted here: this VM has no
  name, and a test that started one would be a second cluster in the suite. The
  named case is checked where it matters — `scripts/boot-check.sh` starts a
  release that was told both things.
  """
  # `System.put_env/2` is the whole VM, so these cannot run beside a test that
  # asks the same question differently.
  use ExUnit.Case, async: false

  alias ExTbpMonty.Node
  alias Monty.Test.Tmp

  setup do
    Tmp.without_env("MONTY_NODE_FOLDER")
    Tmp.without_env("EX_TBP_MONTY_WINDOW")

    # Clustering on, which is the condition that gives a node a folder at all.
    previous = Application.fetch_env(:ex_tbp_monty, :cluster)
    Application.put_env(:ex_tbp_monty, :cluster, enabled: true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ex_tbp_monty, :cluster, value)
        :error -> Application.delete_env(:ex_tbp_monty, :cluster)
      end
    end)
  end

  test "a clustered node keeps its own folder, named after itself" do
    refute Node.distributed?(), "this test is about a node nobody named"

    assert Node.data_dir_name() == nil
  end

  test "an environment that names the folder is obeyed, and made safe for a path" do
    Tmp.system_env("MONTY_NODE_FOLDER", "a folder: with a colon")

    assert Node.data_dir_name() == "a_folder__with_a_colon"
  end

  test "the window keeps the shared folder, because its name is per launch" do
    # The window is the one start that is clustered and named and still has to
    # keep the folder a node that runs alone uses: yesterday's runs are in it, and
    # today's launch is called something else.
    Tmp.system_env("EX_TBP_MONTY_WINDOW", "1")

    assert Node.data_dir_name() == nil
  end

  test "and a folder somebody named wins over that, for a worker that wants its own" do
    Tmp.system_env("EX_TBP_MONTY_WINDOW", "1")
    Tmp.system_env("MONTY_NODE_FOLDER", "worker-1")

    assert Node.data_dir_name() == "worker-1"
  end
end
