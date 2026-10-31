defmodule Monty.Studio.ArtifactsTest do
  @moduledoc """
  What a run left, as a page can offer it: the files in its own directory, by name.

  The listing is the directory's, not a list of names a page guessed at: a run's
  handlers write whatever the config asked for, and a page that offered a fixed set
  would be wrong the first time a run asked for something else. What is *not* a
  file of that run is never a path — that is the whole of the traversal question.
  """

  use ExUnit.Case, async: false

  alias Monty.Studio.Artifacts
  alias Monty.Test.Tmp

  setup do
    Tmp.env_dir("studio-runs", :studio_artifacts_dir)
    :ok
  end

  defp run_id, do: Ecto.UUID.generate()

  test "lists the files a run wrote, by name and size, sorted" do
    id = run_id()
    :ok = Artifacts.start(id)
    File.write!(Path.join(Artifacts.dir(id), "eval_stats.csv"), "a,b\n1,2\n")
    File.write!(Path.join(Artifacts.dir(id), "run.log"), "step 0\n")

    assert Artifacts.files(id) == [
             %{name: "eval_stats.csv", bytes: 8},
             %{name: "run.log", bytes: 7}
           ]
  end

  test "offers no directory of a run, only its files" do
    # A per-episode detailed logger writes a directory; that is part of what the
    # run wrote, not a file to hand out.
    id = run_id()
    :ok = Artifacts.start(id)
    File.mkdir_p!(Path.join(Artifacts.dir(id), "detailed_run_stats"))

    assert Artifacts.files(id) == []
  end

  test "says nothing for a run that never wrote anything" do
    assert Artifacts.files(run_id()) == []
  end

  test "hands out a file it holds, and nothing else" do
    id = run_id()
    :ok = Artifacts.start(id)
    File.write!(Path.join(Artifacts.dir(id), "eval_stats.csv"), "a,b\n")

    assert {:ok, path} = Artifacts.file_path(id, "eval_stats.csv")
    assert File.read!(path) == "a,b\n"

    assert Artifacts.file_path(id, "config_snapshot.yaml") == :error
    assert Artifacts.file_path(id, "../run.log") == :error
    assert Artifacts.file_path(id, "detailed_run_stats") == :error
  end

  test "refuses an id that is not a run id" do
    assert_raise ArgumentError, fn -> Artifacts.files("../../etc") end
  end
end
