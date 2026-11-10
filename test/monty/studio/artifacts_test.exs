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

  describe "the pictures of a step" do
    # A one-pixel PNG: the smallest thing that is a file a camera could have
    # drawn, and the bytes are what makes the assertions about files rather than
    # about strings.
    @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    test "are written under the run's own directory, by step and sensor" do
      id = run_id()

      assert {:ok, "frames/7/patch-depth.png"} = Artifacts.put_frame(id, 7, "patch", "depth", @png)

      path = Path.join(Artifacts.dir(id), "frames/7/patch-depth.png")
      assert File.read!(path) == Base.decode64!(@png)
    end

    test "are served from the path a page is given, and only from inside that run" do
      id = run_id()
      {:ok, name} = Artifacts.put_frame(id, 3, "view_finder", "colour", @png)

      assert Artifacts.frame_url(id, name) == "/runs/#{id}/frames/#{name}"
      assert {:ok, path} = Artifacts.frame_path(id, name)
      assert File.read!(path) == Base.decode64!(@png)

      assert Artifacts.frame_path(id, "frames/../../run.log") == :error
      assert Artifacts.frame_path(id, "frames/3/no-such-sensor-colour.png") == :error
    end

    test "go with the run when it is deleted" do
      id = run_id()
      {:ok, _name} = Artifacts.put_frame(id, 1, "patch", "depth", @png)
      assert File.exists?(Artifacts.frames_dir(id))

      Artifacts.forget(id)

      refute File.exists?(Artifacts.dir(id))
      assert Artifacts.frame_path(id, "frames/1/patch-depth.png") == :error
    end
  end
end
