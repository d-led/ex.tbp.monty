defmodule ExTbpMonty.Core.FrameVideo.Settings do
  @moduledoc """
  How a run's pictures are encoded: the knobs, in one place, as data.

  Nothing here is compiled in. A run's pictures are a trade between how small the
  archive is, how much of the picture survives, and how far a seek has to decode
  — and which way that trade should go is a question for a benchmark, not a
  guess made once in a `native/` file. So the encoder's settings are a struct
  with defaults, the defaults are read from the application's config, and a
  caller may override any of them for one video.

  ## The four knobs

    * `:fps` — ticks a second, and frames a second: one tick a frame, so a step's
      number divided by this is the second a player seeks to. It is a *mapping*,
      not a measurement, and it is fixed for the life of one video: changing it
      midway would move every frame already written. A run whose steps come
      faster than this is a run whose video plays slow, not a broken one.
    * `:qp` — the quantiser, 0 (near-lossless, larger) to 51 (small, visible).
      At 64 × 64 the difference between 18 and 26 is a few bytes and the
      difference between them is a visible picture, which is why it is low.
    * `:gop` — the longest a seek may have to decode: a keyframe at least this
      often. It bounds a read-back's cost and a crash's loss, and it is the
      knob to turn when a single picture takes too long to come back.
    * `:bitrate` — bits a second, or `0` to keep the constant quantiser above.
      Rate control trades picture quality for a size budget; for an archive of a
      run there is no budget to hit.

  ## Changing them without a release

  `config :ex_tbp_monty_core, :frame_video` overrides the defaults for a node,
  environment or benchmark:

      config :ex_tbp_monty_core, :frame_video, qp: 22, gop: 30, fps: 10

  `new/1` reads that once per call rather than caching it, so a benchmark that
  sets it between two videos is a benchmark that measures what it just set.
  """

  @typedoc "An encoder's settings for one video."
  @type t :: %__MODULE__{
          fps: pos_integer(),
          qp: 0..51,
          gop: pos_integer(),
          bitrate: non_neg_integer()
        }

  defstruct fps: 20, qp: 18, gop: 60, bitrate: 0

  @configured_keys [:fps, :qp, :gop, :bitrate]

  @doc """
  The settings in force: the defaults, with the application's own in between,
  and `overrides` last.

  Refuses a value a codec cannot take — a zero frame rate or gop would divide by
  zero in the native code, and a quantiser above 51 is not a quantiser — so a
  typo is an error at the call, not a stream nobody can decode.
  """
  @spec new(keyword()) :: t()
  def new(overrides \\ []) do
    configured()
    |> Keyword.merge(overrides)
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  defp configured do
    :ex_tbp_monty_core
    |> Application.get_env(:frame_video, [])
    |> Keyword.take(@configured_keys)
  end

  @doc """
  The settings as the native side takes them: one tuple, in one order.

  This is the only place that order is written down.
  """
  @spec to_nif(t()) :: {pos_integer(), 0..51, pos_integer(), non_neg_integer()}
  def to_nif(%__MODULE__{} = settings), do: {settings.fps, settings.qp, settings.gop, settings.bitrate}

  defp validate!(%__MODULE__{} = settings) do
    unless is_integer(settings.fps) and settings.fps > 0,
      do: raise(ArgumentError, "fps must be a positive integer, got #{inspect(settings.fps)}")

    unless is_integer(settings.qp) and settings.qp in 0..51,
      do: raise(ArgumentError, "qp must be between 0 and 51, got #{inspect(settings.qp)}")

    unless is_integer(settings.gop) and settings.gop > 0,
      do: raise(ArgumentError, "gop must be a positive integer, got #{inspect(settings.gop)}")

    unless is_integer(settings.bitrate) and settings.bitrate >= 0,
      do: raise(ArgumentError, "bitrate must be zero or more, got #{inspect(settings.bitrate)}")

    settings
  end
end
