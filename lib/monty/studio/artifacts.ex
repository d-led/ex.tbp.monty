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
  @spec start(binary()) :: :ok | {:error, term()}
  def start(run_id) do
    case File.mkdir_p(dir(run_id)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_create, dir(run_id), reason}}
    end
  end

  @doc "Appends one line to a run's log file."
  @spec append(binary(), String.t()) :: :ok | {:error, term()}
  def append(run_id, line) do
    File.write(log_path(run_id), line <> "\n", [:append])
  end

  @doc "Forgets a run's directory, if it has one."
  @spec forget(binary()) :: :ok
  def forget(run_id) do
    _ignored = File.rm_rf(dir(run_id))
    :ok
  end
end
