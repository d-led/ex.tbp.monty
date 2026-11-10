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
  Writes one picture of one step, and answers the path a page asks for it at.

  The path is relative to the run (`frames/<step>/<sensor>-<depth|colour>.png`),
  so a record that is moved to another host still names its own pictures.
  """
  @spec put_frame(binary(), non_neg_integer(), String.t(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def put_frame(run_id, step, sensor_id, kind, base64) do
    name = Path.join(["frames", Integer.to_string(step), "#{sensor_id}-#{kind}.png"])
    path = Path.join(dir(run_id), name)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, bytes} <- Base.decode64(base64),
         :ok <- File.write(path, bytes) do
      {:ok, name}
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
    base = dir(run_id)
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
end
