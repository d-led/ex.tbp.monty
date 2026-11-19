defmodule ExTbpMonty.Core.FrameVideoNif do
  @moduledoc """
  The native writer behind `ExTbpMonty.Core.FrameVideo`.

  Four calls and a handle: the encoder and the fragmented-MP4 muxer are in Rust
  (`native/frame_video_nif`), because a pure-Elixir H.264 encoder is not a thing
  this codebase should contain.

  This module is only the stubs. `FrameVideo` is what a caller uses: it is where
  the arguments are checked and the absence of the library is answered.
  """

  use Rustler, otp_app: :ex_tbp_monty_core, crate: "frame_video_nif"

  @doc "True, from the native side — the only way to know it is loaded."
  def available, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Opens `path` as a video of `kind` (`\"grey\"` or `\"rgb\"`) pictures."
  def open(_path, _width, _height, _kind, _settings), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Appends one picture, and starts a fragment there when `keyframe`."
  def push(_video, _pixels, _keyframe), do: :erlang.nif_error(:nif_not_loaded)

  @doc "How many pictures the file holds."
  def frames(_video), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Ends the file, writing what the encoder still holds."
  def finish(_video), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Writes what is queued as a fragment, so a frame just pushed can be read."
  def flush(_video), do: :erlang.nif_error(:nif_not_loaded)

  @doc "One picture of a video on disk, decoded from the keyframe it depends on."
  def frame_at(_path, _index, _kind), do: :erlang.nif_error(:nif_not_loaded)

  @doc "How many pictures a video on disk holds."
  def frames_in(_path), do: :erlang.nif_error(:nif_not_loaded)
end
