defmodule ExTbpMonty.Core.FrameVideoTest do
  # A run's pictures as one video instead of a file a step. What these describe
  # is the file: that a player can open it before it is finished, that a
  # keyframe is a seek point, and that a picture of the wrong shape never reaches
  # the encoder.

  use ExUnit.Case, async: true

  alias ExTbpMonty.Core.FrameVideo

  @width 64
  @height 64

  setup do
    dir = Path.join(System.tmp_dir!(), "frame_video_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, path: Path.join(dir, "patch-depth.mp4")}
  end

  test "writes a stream a player can open, with the index it needs before the media", %{
    path: path
  } do
    video = open_video(path)

    for step <- 1..3 do
      :ok = FrameVideo.push(video, grey(step), step == 1)
    end

    :ok = FrameVideo.finish(video)

    # `ftyp` and `moov` first is what lets a player start before the whole file is
    # there; `moof`+`mdat` after is the fragment the keyframe opened.
    assert boxes(path) |> Enum.take(4) == ["ftyp", "moov", "moof", "mdat"]
  end

  test "counts the pictures it holds, which is what a resumed run appends after", %{path: path} do
    video = open_video(path)

    assert FrameVideo.frames(video) == 0
    :ok = FrameVideo.push(video, grey(1), true)
    :ok = FrameVideo.push(video, grey(2), false)

    assert FrameVideo.frames(video) == 2
  end

  test "a run that dies leaves what it flushed, without a finish", %{path: path} do
    video = open_video(path)
    :ok = FrameVideo.push(video, grey(1), true)

    # No `finish/1`: the fragment the keyframe wrote is already on disk, so the
    # file is a playable one-frame video.
    assert boxes(path) == ["ftyp", "moov", "moof", "mdat"]
  end

  test "a picture that is not the video's shape is refused, not encoded", %{path: path} do
    video = open_video(path)

    assert {:error, reason} = FrameVideo.push(video, :binary.copy(<<0>>, 10), true)
    assert reason =~ "4096"
    assert FrameVideo.frames(video) == 0
  end

  test "a picture nothing can be written to is an error the caller can handle" do
    # `/dev/null` is a file, so the directory under it cannot be made: the run
    # keeps stepping and only its pictures are missing.
    assert {:error, {:cannot_create, _path, _reason}} =
             FrameVideo.open("/dev/null/frames/patch-depth.mp4",
               width: @width,
               height: @height
             )
  end

  test "a picture comes back out of the video, as it was pushed", %{path: path} do
    video = open_video(path)
    pictures = for step <- 1..5, do: grey(step)

    pictures
    |> Enum.with_index()
    |> Enum.each(fn {picture, at} -> :ok = FrameVideo.push(video, picture, rem(at, 5) == 0) end)

    :ok = FrameVideo.finish(video)

    assert {:ok, {@width, @height, pixels}} = FrameVideo.frame_at(path, 3)

    # Lossy, so not the same bytes: within a grey level of what went in, which is
    # what a picture a person looks at can promise.
    assert mean_error(Enum.at(pictures, 3), pixels) < 1.0
  end

  test "a frame the video does not hold is an error, not a crash", %{path: path} do
    video = open_video(path)
    :ok = FrameVideo.push(video, grey(1), true)
    :ok = FrameVideo.finish(video)

    assert {:error, reason} = FrameVideo.frame_at(path, 40)
    assert reason =~ "40"
  end

  defp open_video(path) do
    assert {:ok, video} = FrameVideo.open(path, width: @width, height: @height, kind: :grey)

    video
  end

  # A depth picture that changes step to step, so the encoder has something to
  # predict rather than a still.
  defp grey(step) do
    for row <- 0..(@height - 1), column <- 0..(@width - 1), into: <<>> do
      <<rem(column + step * 4, @width) * 3 + row::8>>
    end
  end

  # How far a picture read back is from the greys that were pushed, in grey
  # levels. The encoder squeezes a grey into luma's 16–235 band and the decoder
  # expands it again, so the smallest honest tolerance is one level.
  defp mean_error(expected, actual) do
    expected
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(actual))
    |> Enum.map(fn {want, got} -> abs(want - got) end)
    |> Enum.sum()
    |> Kernel./(byte_size(expected))
  end

  # The top-level boxes of the file, in order: what a demuxer walks. A box is a
  # 32-bit length and a four-character type.
  defp boxes(path) do
    path
    |> File.read!()
    |> walk([])
    |> Enum.reverse()
  end

  defp walk(<<0::32, type::binary-4, _rest::binary>>, found), do: [type | found]

  defp walk(<<length::32, type::binary-4, rest::binary>>, found) when length >= 8 do
    payload = binary_part(rest, 0, min(length - 8, byte_size(rest)))

    walk(binary_part(rest, byte_size(payload), byte_size(rest) - byte_size(payload)), [
      type | found
    ])
  end

  defp walk(_truncated, found), do: found
end
