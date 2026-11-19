defmodule ExTbpMonty.Core.FrameVideo do
  @moduledoc """
  A run's pictures as video: one file a sensor, instead of a file a step.

  What this replaces, measured on this machine (2026-11-19) on one studio run of
  53 826 steps: **215 304 PNG files, 48.7 MB of pixels, 882 MB of disk** — because
  a 100-byte picture still costs a block, an inode, a directory entry and a
  metadata write, and a run writes four of them a step. The same pictures as
  H.264 came to about seventy bytes a frame, and a few files.

  ## Why a video rather than a container of PNGs

  The pictures are already PNGs of a few dozen bytes each, so the codec is not
  where the disk goes: **one file instead of a hundred and eighty thousand** is.
  The reason it is H.264 rather than PNG payloads appended to one file is the
  page: a browser decodes this in hardware, so a run can be *played* — a
  timeline that scrubs — where a file of PNGs could only ever be a lookup.

  The cost of that, stated plainly: H.264 is lossy. A depth picture travels as
  luma with neutral chroma and comes back within a grey level or two; a colour
  picture keeps a quarter of its chroma, because 4:2:0 is the profile every
  player decodes. These are pictures for a person to look at — the numbers a run
  is judged by are in its record — and the quantiser is 18, low enough that the
  difference from the source is not visible at 64 × 64.

  ## Crash safety

  A run that dies is normal here, so the file must be readable whenever the run
  last wrote: the container is **fragmented** MP4, with `ftyp`+`moov` first and a
  self-contained `moof`+`mdat` per flush. A keyframe starts a fragment, so
  everything flushed before a crash is playable and seekable, and a process that
  dies without `finish/1` still leaves a video of the steps it took.
  """

  alias ExTbpMonty.Core.FrameVideo.Settings
  alias ExTbpMonty.Core.FrameVideoNif

  @typedoc """
  An open video. The reference is the native writer; `frames/1` reads the count
  from it rather than from a counter here, so nothing about the file is guessed.
  """
  @type t :: reference()

  @typedoc """
  What the pictures are: `:grey` (one byte a pixel, a depth image) or `:rgb`
  (three, interleaved).
  """
  @type kind :: :grey | :rgb

  @doc """
  Opens `path` as a video of `width` × `height` pictures.

  The directory is made here: a video belongs in the run's own folder, and a
  caller that had to remember to create it would be a caller that sometimes did
  not.

  `:settings` is a `FrameVideo.Settings` — or the keyword list `Settings.new/1`
  takes — and it is the whole of how the video is encoded.

  Answers `{:error, reason}` for a path that cannot be opened, and `{:error,
  :not_built}` on a machine whose Rust toolchain did not build the library —
  which is a run whose pictures are missing, not a run that failed.
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, options) do
    width = Keyword.fetch!(options, :width)
    height = Keyword.fetch!(options, :height)
    kind = Keyword.get(options, :kind, :grey)
    settings = settings(Keyword.get(options, :settings, []))

    with :ok <- ensure_loaded(),
         :ok <- make_directory(path) do
      render_open(path, width, height, kind, settings)
    end
  end

  defp settings(%Settings{} = settings), do: settings
  defp settings(overrides) when is_list(overrides), do: Settings.new(overrides)

  defp make_directory(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_create, path, reason}}
    end
  end

  defp render_open(path, width, height, kind, settings) do
    FrameVideoNif.open(path, width, height, Atom.to_string(kind), Settings.to_nif(settings))
  rescue
    # A NIF that is not in this build answers a call by raising, which is the
    # runtime saying "not here" rather than an error the caller could match.
    ErlangError -> {:error, :not_built}
  end

  @doc """
  Appends one picture: `width * height` grey bytes, or RGB triples.

  `keyframe` asks for an intra frame here — a seek point, and a fragment
  boundary. A caller keys the frames it knows are discontinuities: an episode's
  first frame is a different object in a different place.

  A picture that does not fit the video's shape is refused rather than written:
  an encoder fed the wrong size writes a stream nothing can decode.
  """
  @spec push(t(), binary(), boolean()) :: :ok | {:error, term()}
  def push(video, pixels, keyframe \\ false) do
    video |> FrameVideoNif.push(pixels, keyframe) |> answer()
  end

  @doc """
  How many pictures the video holds.

  Read from the writer, so it is the number of frames that are actually in the
  file — which is what makes a resumed run append rather than overwrite.
  """
  @spec frames(t()) :: non_neg_integer()
  def frames(video), do: FrameVideoNif.frames(video)

  @doc """
  Ends the file.

  Optional: a video nobody finished is still a video of what was flushed, because
  every keyframe wrote its own fragment.
  """
  @spec finish(t()) :: :ok | {:error, term()}
  def finish(video), do: video |> FrameVideoNif.finish() |> answer()

  @doc """
  Writes what is queued as a fragment now.

  A keyframe writes its own fragment, so this is for the pictures between two of
  them: a frame that is still in this process's queue is a frame no reader can
  find, and a caller about to read them says so with this.
  """
  @spec flush(t()) :: :ok | {:error, term()}
  def flush(video), do: video |> FrameVideoNif.flush() |> answer()

  @doc """
  One picture of a video on disk, by its frame number.

  This is what lets the video be the only artifact: the page asks for a step's
  picture, and gets the pixels that step's PNG used to hold. The decode starts at
  the keyframe the frame depends on, so its cost is at most one `:gop`.

  Answers `{:ok, {width, height, pixels}}`, or `{:error, reason}` for a frame the
  video does not hold — which is what a run that died before writing it looks
  like.
  """
  @spec frame_at(Path.t(), non_neg_integer(), keyword()) ::
          {:ok, {pos_integer(), pos_integer(), binary()}} | {:error, term()}
  def frame_at(path, index, options \\ []) do
    kind = Keyword.get(options, :kind, :grey)

    case FrameVideoNif.frame_at(path, index, Atom.to_string(kind)) do
      {:ok, {width, height, pixels}} -> {:ok, {width, height, pixels}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ErlangError -> {:error, :not_built}
  end

  # A native function that answers nothing answers `{:ok, {}}`: a Rust unit is an
  # empty tuple on this side, and the boundary is where that stops being visible
  # to a caller.
  defp answer({:ok, _nothing}), do: :ok
  defp answer({:error, reason}), do: {:error, reason}

  @doc """
  How many pictures a video on disk holds, without opening it for writing.

  What a reader asks before it asks for a frame: an index that stops early is a
  video of a run that stopped early, and a frame past that is not there.
  """
  @spec frames_in(Path.t()) :: non_neg_integer()
  def frames_in(path) do
    FrameVideoNif.frames_in(path)
  rescue
    ErlangError -> 0
  end

  @doc "Whether this VM built and loaded the native writer."
  @spec loaded?() :: boolean()
  def loaded? do
    ensure_loaded() == :ok
  end

  defp ensure_loaded do
    if FrameVideoNif.available(), do: :ok, else: {:error, :not_built}
  rescue
    ErlangError -> {:error, :not_built}
  end
end
