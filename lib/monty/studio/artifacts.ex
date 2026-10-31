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
    case Ecto.UUID.cast(run_id) do
      {:ok, uuid} -> Path.join(root(), uuid)
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

  @doc "Appends one line to a run's log file."
  # A run's own log file, under the UUID-checked directory `dir/1` builds.
  # sobelow_skip ["Traversal.FileModule"]
  @spec append(binary(), String.t()) :: :ok | {:error, term()}
  def append(run_id, line) do
    File.write(log_path(run_id), line <> "\n", [:append])
  end

  @doc "Forgets a run's directory, if it has one."
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
end
