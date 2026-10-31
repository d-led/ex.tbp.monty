defmodule Monty.Frameworks.Loggers.WandbHandlers.PythonxClientTest do
  use ExUnit.Case, async: false

  alias Monty.Frameworks.Loggers.WandbHandlers.PythonxClient

  # wandb reads its mode and its directory from the environment when a run is
  # opened, so an offline run can be pointed at a scratch directory: it needs no
  # credentials and it leaves what it wrote where this test can see it.
  setup do
    directory = Path.join(System.tmp_dir!(), "wandb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    System.put_env("WANDB_MODE", "offline")
    System.put_env("WANDB_DIR", directory)
    System.put_env("WANDB_SILENT", "true")

    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "an episode reported through the client reaches wandb", %{directory: directory} do
    {:ok, run} = PythonxClient.init(%{"name" => "episode_", "config" => %{"seed" => 42}})
    {:ok, _run} = PythonxClient.log(run, %{"loss" => 0.5})

    assert PythonxClient.finish(run) == :ok
    assert [_run_file] = Path.wildcard(Path.join(directory, "wandb/offline-run-*/run-*.wandb"))
  end
end
