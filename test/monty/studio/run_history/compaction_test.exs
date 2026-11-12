defmodule Monty.Studio.RunHistory.CompactionTest do
  @moduledoc """
  A moment written before the pictures moved to files, and what happens to it.

  The two halves are tested apart on purpose: `compact/2` decides, and it is a
  pure function of a moment; `apply_to/1` writes the files and the row, and its
  order is the promise — a picture is on disk before the record stops carrying
  it.
  """

  use ExTbpMonty.DataCase, async: false

  alias Monty.Studio.{Artifacts, RunHistory}
  alias Monty.Studio.RunHistory.Compaction
  alias Monty.Test.Tmp

  # A one-pixel PNG, which is all a test needs to be a real picture.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  setup do
    Tmp.env_dir("studio-runs", :studio_artifacts_dir)
    :ok
  end

  defp legacy_moment(step \\ 7, sensor_id \\ "patch") do
    %{
      "step" => step,
      "sensors" => %{
        sensor_id => %{
          "cam_to_world" => [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 1.5]],
          "images" => %{"colour" => @png, "depth" => @png, "range" => [0.04, 0.05]}
        }
      }
    }
  end

  describe "a moment that still carries its pictures" do
    test "names them, and says which bytes have to be written first" do
      run_id = Ecto.UUID.generate()

      {moment, pictures} = Compaction.compact(run_id, legacy_moment())

      assert moment["sensors"]["patch"]["images"]["colour"] ==
               "/runs/#{run_id}/frames/7/patch-colour.png"

      assert moment["sensors"]["patch"]["images"]["depth"] ==
               "/runs/#{run_id}/frames/7/patch-depth.png"

      # What the moment is *about* is not the compaction's business: the depth
      # range and the pose stay exactly as they were.
      assert moment["sensors"]["patch"]["images"]["range"] == [0.04, 0.05]
      assert moment["step"] == 7

      assert Enum.sort(Enum.map(pictures, & &1.kind)) == ["colour", "depth"]
      assert Enum.all?(pictures, &(&1.sensor_id == "patch" and &1.step == 7))
      assert Enum.all?(pictures, &(&1.base64 == @png))
    end

    test "is legacy, and stops being legacy once it is compacted" do
      assert Compaction.legacy?(legacy_moment())

      {compacted, _pictures} = Compaction.compact(Ecto.UUID.generate(), legacy_moment())

      refute Compaction.legacy?(compacted)
    end

    test "has nothing left to write the second time, so a run is compacted once" do
      {compacted, _pictures} = Compaction.compact(Ecto.UUID.generate(), legacy_moment())
      {again, pictures} = Compaction.compact(Ecto.UUID.generate(), compacted)

      assert pictures == []
      assert again == compacted
    end

    test "is read whether the bytes came with a data prefix or without one" do
      moment =
        put_in(
          legacy_moment()["sensors"]["patch"]["images"]["colour"],
          "data:image/png;base64," <> @png
        )

      {_moment, pictures} = Compaction.compact(Ecto.UUID.generate(), moment)

      assert Enum.find(pictures, &(&1.kind == "colour")).base64 == @png
    end
  end

  describe "a moment that names its pictures" do
    test "is left exactly as it is" do
      moment = %{
        "step" => 3,
        "sensors" => %{
          "patch" => %{"images" => %{"colour" => "/runs/x/frames/3/patch-colour.png"}}
        }
      }

      assert Compaction.compact(Ecto.UUID.generate(), moment) == {moment, []}
      refute Compaction.legacy?(moment)
    end

    test "is a moment with no sensors, or a sensor with no pictures" do
      assert Compaction.compact(Ecto.UUID.generate(), %{"step" => 0}) ==
               {%{"step" => 0}, []}

      rangeless = %{"step" => 0, "sensors" => %{"patch" => %{"cam_to_world" => []}}}

      assert Compaction.compact(Ecto.UUID.generate(), rangeless) == {rangeless, []}
    end
  end

  describe "compacting one run's record" do
    @attributes %{
      experiment: "tutorial/first_experiment",
      source: "monty",
      steps: 1,
      seed: 42
    }

    test "writes the pictures to disk and leaves the record naming them" do
      {:ok, run} = RunHistory.start(@attributes)

      {:ok, run} =
        RunHistory.store(run, [%{"step" => 0, "episode" => 0}], [legacy_moment(0)])

      assert {:ok, result} = Compaction.apply_to(run)
      assert result.pictures == 2
      assert result.after_bytes < result.before_bytes

      # The files are where the URL says they are, and they are the bytes the
      # record used to hold.
      assert {:ok, path} = Artifacts.frame_path(run.id, "0/patch-colour.png")
      assert File.read!(path) == Base.decode64!(@png)

      stored = RunHistory.get(run.id)

      assert stored.timeline |> hd() |> get_in(["sensors", "patch", "images", "colour"]) ==
               "/runs/#{run.id}/frames/0/patch-colour.png"

      refute Compaction.legacy?(hd(stored.timeline))
    end

    test "does nothing the second time" do
      {:ok, run} = RunHistory.start(@attributes)
      {:ok, run} = RunHistory.store(run, [%{"step" => 0, "episode" => 0}], [legacy_moment(0)])
      {:ok, _first} = Compaction.apply_to(run)

      assert {:ok, again} = Compaction.apply_to(RunHistory.get(run.id))
      assert again.pictures == 0
      assert again.before_bytes == again.after_bytes
    end
  end
end
