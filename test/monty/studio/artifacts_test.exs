defmodule Monty.Studio.ArtifactsTest do
  @moduledoc """
  What a run left, as a page can offer it: the files in its own directory, by name.

  The listing is the directory's, not a list of names a page guessed at: a run's
  handlers write whatever the config asked for, and a page that offered a fixed set
  would be wrong the first time a run asked for something else. What is *not* a
  file of that run is never a path — that is the whole of the traversal question.
  """

  use ExUnit.Case, async: false

  alias ExTbpMonty.Core.FrameVideo
  alias Monty.Studio.Artifacts
  alias Monty.Test.Tmp

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    Tmp.env_dir("studio-runs", :studio_artifacts_dir)
    :ok
  end

  defp run_id, do: Ecto.UUID.generate()

  # A node answers "where do a run's files go" with this, and a peer decides
  # whether it shares a run's directory by comparing it — so the answer has to be
  # the directory the files are actually written to, in every environment. It is
  # never inside the source tree: `mix release` copies `priv` whole, so a run
  # started outside the application's own boot — a task, a script, a development
  # run — that wrote there put its log and every frame of every step into the next
  # build.
  test "is where the deployment said, and the data folder otherwise" do
    Tmp.without_app_env(:studio_artifacts_dir)
    System.delete_env("MONTY_ARTIFACTS_DIR")

    assert Artifacts.root() == Monty.Paths.artifacts()
    refute String.starts_with?(Artifacts.root(), "priv/")
    refute String.contains?(Artifacts.root(), "/priv/")

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
  end

  describe "a run's pictures as video" do
    # A run keeps one video a sensor now, and a step's picture is a frame of it.
    # The name the record holds did not change — `<place>/<sensor>-<kind>.png` —
    # and what it resolves to did.
    test "a name says which video holds the picture, and which frame" do
      assert Artifacts.picture("0/patch-depth.png") ==
               {:ok, %{video: "run/patch-depth.mp4", frame: 0, kind: :grey}}

      assert Artifacts.picture("part-2-57/patch_0-colour.png") ==
               {:ok, %{video: "part-2/patch_0-colour.mp4", frame: 57, kind: :rgb}}

      assert Artifacts.picture("../../run.log") == :error
      assert Artifacts.picture("0/patch.mov") == :error
    end

    test "a step's picture is decoded back out of its video, as the PNG the page draws" do
      id = run_id()
      write_video(id, "run", "patch", "depth", :grey, [<<5, 9, 12, 15>>])

      assert {:ok, png} = Artifacts.frame_bytes(id, "0/patch-depth.png")
      assert binary_part(png, 0, 8) == @png_signature
    end

    test "a colour picture is decoded as colour, three bytes a pixel" do
      id = run_id()
      red = <<255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255>>
      write_video(id, "run", "patch", "colour", :rgb, [red])

      assert {:ok, png} = Artifacts.frame_bytes(id, "0/patch-colour.png")
      assert binary_part(png, 0, 8) == @png_signature
    end

    test "a frame the video has not reached is no picture, not an error page" do
      id = run_id()
      write_video(id, "run", "patch", "depth", :grey, [<<5, 9, 12, 15>>])

      assert Artifacts.frame_bytes(id, "3/patch-depth.png") == :error
    end

    # A step whose moment the row lost has no pictures of its own, so a page
    # asks the files: the newest step every video of the run can still show.
    test "the newest step the run can show, named under its own place" do
      id = run_id()
      write_video(id, "run", "patch", "depth", :grey, [<<1, 2, 3, 4>>, <<1, 2, 3, 4>>])

      assert Artifacts.pictures_at(id, 9) ==
               {:ok, 1,
                %{"patch" => %{"images" => %{"depth" => "/runs/#{id}/frames/1/patch-depth.png"}}}}

      assert Artifacts.pictures_at(run_id(), 0) == :none
    end

    # What a page offers a person to watch: the run in motion, a video a sensor,
    # in the browser's own player.
    test "what can be watched is one video a sensor, and nothing for a run with none" do
      id = run_id()
      write_video(id, "run", "patch", "depth", :grey, [<<1, 2, 3, 4>>, <<1, 2, 3, 4>>])

      assert Artifacts.videos(id) == [
               %{
                 sensor: "patch",
                 kind: "depth",
                 frames: 2,
                 url: "/runs/#{id}/videos/run/patch-depth.mp4"
               }
             ]

      assert Artifacts.videos(run_id()) == []
    end

    test "a video's file is served only from the run's own directory" do
      id = run_id()
      path = write_video(id, "run", "patch", "depth", :grey, [<<1, 2, 3, 4>>])

      assert Artifacts.video_file(id, "run/patch-depth.mp4") == {:ok, path}
      assert Artifacts.video_file(id, "../../run.log") == :error
      assert Artifacts.video_file(id, "run/patch-colour.mp4") == :error
    end
  end

  # The write end of the same contract: a video at a place, as `Pictures` leaves
  # one behind.
  defp write_video(run_id, part, sensor, kind, picture_kind, pictures) do
    path = Artifacts.video_path(run_id, part, sensor, kind)
    {:ok, video} = FrameVideo.open(path, width: 2, height: 2, kind: picture_kind)

    Enum.each(pictures, &(:ok = FrameVideo.push(video, &1, false)))
    :ok = FrameVideo.finish(video)

    path
  end
end
