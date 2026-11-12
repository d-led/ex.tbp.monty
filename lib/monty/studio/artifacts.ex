defmodule Monty.Studio.Artifacts do
  @moduledoc """
  Where a run's own files live: one directory per run, named by its id.

  What a run leaves behind is a log a human can read without this application —
  `grep` it, `tail -f` it, quote a line from it in an issue. The database holds
  the structured version (for filtering and replay); the file holds the rendered
  one, and the two are written from the same line so they cannot drift.

  Deleting the run deletes the directory: these files are this application's,
  not Monty's, and a run nobody wants is a directory nobody wants.
  """

  @default_root "priv/studio_runs"

  # The two pictures a sensor draws of a step, as `put_frame/5` names them.
  @kinds ["depth", "colour"]

  @doc "The directory run artifacts are kept under."
  @spec root() :: Path.t()
  def root, do: Application.get_env(:ex_tbp_monty, :studio_artifacts_dir, @default_root)

  @doc """
  A run's own directory.

  The id is validated as a UUID rather than trusted: a run's id comes from the
  database, but a path built from whatever it is given would be a path built
  from whatever it is given.
  """
  @spec dir(binary()) :: Path.t()
  def dir(run_id) do
    Path.join(root(), uuid(run_id))
  end

  # The id a path may be built from: a run's id comes from the database, but
  # nothing here builds a path out of whatever it was handed.
  @spec uuid(binary()) :: binary()
  defp uuid(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "not a run id: #{inspect(run_id)}"
    end
  end

  @doc "The file a run's log is written to."
  @spec log_path(binary()) :: Path.t()
  def log_path(run_id), do: Path.join(dir(run_id), "run.log")

  @doc """
  Makes the run's directory, or says why it could not.

  A run whose log cannot be written still runs — the database is the record —
  but it says so here instead of pretending.
  """
  # `dir/1` has already refused a run id that is not a UUID, so the path is this
  # application's own directory for that run.
  # sobelow_skip ["Traversal.FileModule"]
  @spec start(binary()) :: :ok | {:error, term()}
  def start(run_id) do
    case File.mkdir_p(dir(run_id)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_create, dir(run_id), reason}}
    end
  end

  @doc "Appends one line to a run's log file, stamped with the clock it happened at."
  # A run's own log file, under the UUID-checked directory `dir/1` builds.
  # sobelow_skip ["Traversal.FileModule"]
  @spec append(binary(), String.t()) :: :ok | {:error, term()}
  def append(run_id, line) do
    File.write(log_path(run_id), stamped(line) <> "\n", [:append])
  end

  # Every line says when it was written, on the clock of the machine that ran
  # it. A step line carries its own step time, which is a duration and not a
  # time of day: without a stamp, "run started" and "run finished" cannot be
  # lined up with anything else a person did that afternoon.
  defp stamped(line), do: "#{Monty.Studio.LocalClock.now().clock} #{line}"

  @doc "Deletes a run's directory, if it has one."
  # A run's own directory, named by a UUID `dir/1` has checked; a recursive
  # delete of anything else never gets this far.
  # sobelow_skip ["Traversal.FileModule"]
  @spec forget(binary()) :: :ok
  def forget(run_id) do
    _ignored = File.rm_rf(dir(run_id))
    :ok
  end

  @typedoc "A file a run wrote, as a page offers it."
  @type file :: %{name: String.t(), bytes: non_neg_integer()}

  @doc """
  The files this run has written, by name, with their sizes.

  The run's own directory is read rather than a list of names being guessed at:
  the handlers write whatever the config asked them for — a CSV per mode, one
  detailed JSON or a directory of episode files — and a page that listed a fixed
  set would be wrong the moment a run asked for something else.

  Only regular files directly in that directory are offered. A subdirectory is
  part of what a run wrote, not a thing to hand out.
  """
  # The directory of a run whose id `dir/1` has already refused unless it is a
  # UUID; nothing here is given a path from outside.
  # sobelow_skip ["Traversal.FileModule"]
  @spec files(binary()) :: [file()]
  def files(run_id) do
    case File.ls(dir(run_id)) do
      {:ok, names} -> names |> Enum.sort() |> Enum.flat_map(&file_entry(run_id, &1))
      {:error, :enoent} -> []
      {:error, _reason} -> []
    end
  end

  defp file_entry(run_id, name) do
    case File.stat(Path.join(dir(run_id), name)) do
      {:ok, %File.Stat{type: :regular, size: size}} -> [%{name: name, bytes: size}]
      _not_a_regular_file -> []
    end
  end

  @doc """
  The path of one of this run's files, or `:error`.

  The name is matched against the files the directory actually holds, so what a
  caller asked for never becomes part of a path: `..%2f..%2fetc%2fpasswd` is not
  one of the run's files and there is nothing to escape to.
  """
  @spec file_path(binary(), String.t()) :: {:ok, Path.t()} | :error
  def file_path(run_id, name) do
    if Enum.any?(files(run_id), &(&1.name == name)),
      do: {:ok, Path.join(dir(run_id), name)},
      else: :error
  end

  @doc """
  Where a run's pictures are kept: a directory of its own, beside its log.

  A step's pictures are two PNGs per sensor, and keeping them inside the record
  cost ten kilobytes a step: that put `base_10simobj_surf_agent` within four
  percent of Postgres's 256 MB ceiling on a jsonb value, and put one
  twenty-two-thousand-step run past it, where the store fails and the run has no
  record at all. The record keeps a name; the bytes are a file.
  """
  @spec frames_dir(binary()) :: Path.t()
  def frames_dir(run_id), do: Path.join(dir(run_id), "frames")

  @doc """
  Writes one picture of one step, and answers its name.

  The name is relative to the run's `frames` directory
  (`<step>/<sensor>-<depth|colour>.png`), which is what the route under
  `/runs/:id/frames/` appends: the record a page reads says
  `/runs/<id>/frames/12/patch-depth.png`, and there is one `frames` in a URL
  rather than two.
  """
  @spec put_frame(binary(), non_neg_integer() | String.t(), String.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  # Not a path from a request: the step is a number this run gave its own
  # pictures — a step number, or part-and-step for a run of several parts — and
  # the sensor and kind are the names a config and a camera gave, inside a run's
  # own directory: the same confinement `frame_path/2` checks again when the file
  # is read.
  # sobelow_skip ["Traversal.FileModule"]
  def put_frame(run_id, step, sensor_id, kind, base64) do
    # The step is whatever a run numbers its pictures by: a step number for a run
    # of the whole experiment, and part-and-step for a run of several parts, whose
    # parts each count from nought inside one run's directory.
    name = frame_name(step, sensor_id, kind)
    path = Path.join(frames_dir(run_id), name)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, bytes} <- decode64(base64),
         :ok <- File.write(path, bytes) do
      {:ok, name}
    end
  end

  @doc """
  The name a picture is kept under, without writing it.

  `<step>/<sensor>-<depth|colour>.png`, which is what the route under
  `/runs/:id/frames/` appends. A run's pictures are named by convention, so a
  record can keep a picture's name before its bytes exist — `RunStream` does,
  and the drawing happens afterwards in a process of its own.
  """
  @spec frame_name(non_neg_integer() | String.t(), String.t(), String.t()) :: String.t()
  def frame_name(step, sensor_id, kind),
    do: Path.join(to_string(step), "#{sensor_id}-#{kind}.png")

  # `Base.decode64/1` answers `:error`, not `{:error, _}`: a picture that is not
  # base64 is refused in the shape this function promises, rather than in the
  # one a caller who checked for `{:error, _}` would miss.
  defp decode64(base64) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_base64}
    end
  end

  @doc """
  The file behind a picture's name, or `:error`.

  The name is resolved and then checked to still be inside the run's own
  directory, so a `..` in it is answered with `:error` rather than a file that
  was never the run's.
  """
  @spec frame_path(binary(), String.t()) :: {:ok, Path.t()} | :error
  def frame_path(run_id, name) do
    # Expanded on both sides: the artifacts directory is a relative path in dev
    # (`priv/studio_runs`) and an absolute one on the desktop, and a relative
    # base compared against an expanded candidate never matches — which made
    # every picture a 404 while the file sat exactly where it belonged.
    base = Path.expand(frames_dir(run_id))
    candidate = Path.expand(Path.join(base, name))

    if String.starts_with?(candidate, base <> "/") and File.regular?(candidate),
      do: {:ok, candidate},
      else: :error
  end

  @doc """
  Where a page asks for one of those pictures.

  The record keeps this rather than the bytes: it is a few dozen characters,
  the page fetches the PNG from the run's own directory, and a step costs what
  its observations cost instead of what its pictures cost.
  """
  @spec frame_url(binary(), String.t()) :: String.t()
  def frame_url(run_id, name), do: "/runs/#{uuid(run_id)}/frames/#{name}"

  @doc """
  The pictures one step wrote, by sensor, in the shape a record keeps them.

  A run's row holds its moments only as far as the stream got to write them —
  a process that dies mid-run takes the transcript with it — while the step's
  two files were already on disk when it drew them. What the files say is the
  same thing the row would have said, so a page can draw a step whose moment
  was lost.
  """
  @spec frames_at(binary(), non_neg_integer()) :: map()
  def frames_at(run_id, step) do
    step_name = Integer.to_string(step)

    case File.ls(Path.join(frames_dir(run_id), step_name)) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&pictured/1)
        |> Enum.reduce(%{}, fn {sensor_id, kind, name}, sensors ->
          url = frame_url(run_id, Path.join(step_name, name))

          Map.update(sensors, sensor_id, %{"images" => %{kind => url}}, fn observation ->
            Map.update(observation, "images", %{kind => url}, &Map.put(&1, kind, url))
          end)
        end)

      _no_step ->
        %{}
    end
  end

  # `<sensor>-<depth|colour>.png`, which is what `put_frame/5` wrote. A name that
  # is neither is not a picture this function can name a sensor for.
  defp pictured(name) do
    with ".png" <- Path.extname(name),
         {kind, sensor_id, _suffix} <- split_kind(Path.rootname(name)) do
      [{sensor_id, kind, name}]
    else
      _not_a_picture -> []
    end
  end

  defp split_kind(root) do
    Enum.find_value(@kinds, :neither, fn kind ->
      suffix = "-" <> kind

      if String.ends_with?(root, suffix),
        do: {kind, String.replace_suffix(root, suffix, ""), suffix}
    end)
  end
end
