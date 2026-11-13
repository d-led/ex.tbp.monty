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

  # A node answers "where do a run's files go" with this, and a peer decides
  # whether it shares a run's directory by comparing it — so the answer has to be
  # the directory the files are actually written to, in every environment.
  test "is where the deployment said, and its own folder otherwise" do
    Tmp.without_app_env(:studio_artifacts_dir)
    System.delete_env("MONTY_ARTIFACTS_DIR")
    assert Artifacts.root() == "priv/studio_runs"

    System.put_env("MONTY_ARTIFACTS_DIR", "/tmp/somewhere/runs")
    on_exit(fn -> System.delete_env("MONTY_ARTIFACTS_DIR") end)
    assert Artifacts.root() == "/tmp/somewhere/runs"

    # A release names the directory outright, and so does a test.
    Tmp.app_env(:studio_artifacts_dir, "/tmp/a-test/studio-runs")
    assert Artifacts.root() == "/tmp/a-test/studio-runs"
  end

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

  describe "the steps of one part of a divided run" do
    test "are written where the run can read them, and read back as they were taken" do
      # A part may be performed by another node, whose `RunStream` this node cannot
      # read: the file in the run's own directory is how its steps reach the run's
      # transcript, so what goes in has to come out unchanged — beliefs and clock
      # both, since neither is in the human log line.
      id = run_id()

      entries = [
        %{
          "step" => 0,
          "episode" => 0,
          "part" => 1,
          "beliefs" => %{"lm" => %{"evidence" => 0.25}}
        },
        %{"step" => 1, "episode" => 0, "part" => 1, "beliefs" => %{"lm" => %{"evidence" => 1.5}}}
      ]

      moments = [%{"at" => "2026-11-13T10:00:00Z"}, %{"at" => "2026-11-13T10:00:01Z"}]

      assert {:ok, 2} = Artifacts.store_part(id, :eval, 1, entries, moments)
      assert File.regular?(Artifacts.part_path(id, :eval, 1))

      assert {:ok, {^entries, ^moments}} = Artifacts.read_part(id, :eval, 1)
    end

    test "are none for a part that never wrote any, which is not an error" do
      id = run_id()
      :ok = Artifacts.start(id)

      assert {:error, :enoent} = Artifacts.read_part(id, :train, 0)
    end

    test "are kept apart per wave, because both waves number their parts from one" do
      id = run_id()
      trained = [%{"step" => 0, "part" => 0}]
      evaluated = [%{"step" => 0, "part" => 0, "episode" => 2}]

      assert {:ok, 1} = Artifacts.store_part(id, :train, 0, trained, [%{"at" => "t"}])
      assert {:ok, 1} = Artifacts.store_part(id, :eval, 0, evaluated, [%{"at" => "e"}])

      assert {:ok, {^trained, _}} = Artifacts.read_part(id, :train, 0)
      assert {:ok, {^evaluated, _}} = Artifacts.read_part(id, :eval, 0)
    end
  end

  describe "the pictures of a step" do
    # A one-pixel PNG: the smallest thing that is a file a camera could have
    # drawn, and the bytes are what makes the assertions about files rather than
    # about strings.
    @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    test "are written under the run's own directory, by step and sensor" do
      id = run_id()

      assert {:ok, "7/patch-depth.png"} =
               Artifacts.put_frame(id, 7, "patch", "depth", @png)

      path = Path.join(Artifacts.frames_dir(id), "7/patch-depth.png")
      assert File.read!(path) == Base.decode64!(@png)
    end

    test "are served from the path a page is given, and only from inside that run" do
      id = run_id()
      {:ok, name} = Artifacts.put_frame(id, 3, "view_finder", "colour", @png)

      assert Artifacts.frame_url(id, name) == "/runs/#{id}/frames/#{name}"
      assert {:ok, path} = Artifacts.frame_path(id, name)
      assert File.read!(path) == Base.decode64!(@png)

      assert Artifacts.frame_path(id, "../../run.log") == :error
      assert Artifacts.frame_path(id, "3/no-such-sensor-colour.png") == :error
    end

    test "go with the run when it is deleted" do
      id = run_id()
      {:ok, _name} = Artifacts.put_frame(id, 1, "patch", "depth", @png)
      assert File.exists?(Artifacts.frames_dir(id))

      Artifacts.forget(id)

      refute File.exists?(Artifacts.dir(id))
      assert Artifacts.frame_path(id, "1/patch-depth.png") == :error
    end

    # The row holds a step's moments only as far as the stream wrote them, so a
    # page drawing a step the row lost asks the files what was there. What the
    # files say is the same thing the row would have said.
    test "a step's pictures are read back by sensor, as a record keeps them" do
      id = run_id()
      {:ok, _depth} = Artifacts.put_frame(id, 4, "patch_0", "depth", @png)
      {:ok, _colour} = Artifacts.put_frame(id, 4, "patch_0", "colour", @png)
      {:ok, _view} = Artifacts.put_frame(id, 4, "view_finder", "depth", @png)
      {:ok, _elsewhere} = Artifacts.put_frame(id, 5, "patch_0", "depth", @png)

      assert Artifacts.frames_at(id, 4) == %{
               "patch_0" => %{
                 "images" => %{
                   "depth" => "/runs/#{id}/frames/4/patch_0-depth.png",
                   "colour" => "/runs/#{id}/frames/4/patch_0-colour.png"
                 }
               },
               "view_finder" => %{
                 "images" => %{"depth" => "/runs/#{id}/frames/4/view_finder-depth.png"}
               }
             }
    end

    test "a step that wrote nothing is no pictures, not an error" do
      assert Artifacts.frames_at(run_id(), 0) == %{}
    end

    test "and names only what is a picture: a stray file is not a sensor's" do
      id = run_id()
      step = Path.join(Artifacts.frames_dir(id), "7")
      File.mkdir_p!(step)
      File.write!(Path.join(step, "notes.txt"), "not a picture")
      File.write!(Path.join(step, "patch-depth.json"), "{}")
      {:ok, _png} = Artifacts.put_frame(id, 7, "patch", "depth", @png)

      assert Artifacts.frames_at(id, 7) == %{
               "patch" => %{"images" => %{"depth" => "/runs/#{id}/frames/7/patch-depth.png"}}
             }
    end
  end
end
