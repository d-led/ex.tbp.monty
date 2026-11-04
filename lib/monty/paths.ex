defmodule Monty.Paths do
  @moduledoc """
  Where this application writes, when nobody has said otherwise.

  One folder under the operating system's per-user application-data directory:
  `~/Library/Application Support/ex-tbp-monty` on macOS, `~/.local/share/…` on
  Linux, `%APPDATA%\\…` on Windows. Everything this application keeps of its own
  — the database, the runs, the memory it exports, the bundles a run reads —
  hangs off that one root, because an installed application has no writable
  `priv/`, and a user's data does not belong beside the source.

  An environment variable, when it is set, is still the answer. `MONTY_DATA`,
  `MONTY_MODELS`, `MONTY_LOGS`, `MONTY_LIBRARIES` and `SQLITE_PATH` are Monty's
  own names, and a container, CI and `mix` tasks all use them; this module only
  supplies what a desktop install has instead, where there is nobody to export
  one.

  The root is *fixed* rather than chosen. A folder that can be picked is a path
  that has to be remembered, in a file that can be lost, stale or unreadable —
  for a decision a person made once.
  """

  @app_name "ex-tbp-monty"
  @database_file "ex_tbp_monty.db"

  @doc """
  The folder this application keeps its own things in, as the operating system
  names it.

  Nothing is created here: a path is a name, and the modules that write make the
  directory they write into.
  """
  @spec root() :: Path.t()
  def root, do: :filename.basedir(:user_data, @app_name)

  @doc "Monty's object data — the `MONTY_DATA` root."
  @spec data() :: Path.t()
  def data, do: env("MONTY_DATA", Path.join(root(), "data"))

  @doc "Monty's pretrained model archives — the `MONTY_MODELS` root."
  @spec models() :: Path.t()
  def models, do: env("MONTY_MODELS", Path.join(root(), "models"))

  @doc "Where Monty writes a run's own output — the `MONTY_LOGS` root."
  @spec logs() :: Path.t()
  def logs, do: env("MONTY_LOGS", Path.join(root(), "projects"))

  @doc """
  The memory this application exports from those archives — the
  `MONTY_LIBRARIES` root.

  Beside the data the pickles came from, so deleting the data deletes the export
  that describes it, rather than leaving graphs of objects nobody has.
  """
  @spec libraries() :: Path.t()
  def libraries, do: env("MONTY_LIBRARIES", Path.join(data(), "libraries"))

  @doc """
  The SQLite file a release without `DATABASE_URL` keeps its runs in.

  One file in the root above: a desktop install is one reader, and a file is the
  database it can have without installing a server.
  """
  @spec database() :: Path.t()
  def database, do: env("SQLITE_PATH", Path.join(root(), @database_file))

  @doc """
  The files a run leaves beside its record.

  `config/runtime.exs` points `:studio_artifacts_dir` here, so the desktop build
  writes them under the root above while development keeps writing them into the
  checkout.
  """
  @spec artifacts() :: Path.t()
  def artifacts, do: Path.join(root(), "runs")

  @doc "Where wandb writes what a run logs, when it logs anything."
  @spec wandb() :: Path.t()
  def wandb, do: Path.join(root(), "wandb")

  # An unset variable and an empty one are the same answer here: "nobody said".
  # Code that asks whether a variable *is there* would hear two things, and every
  # caller of this module wants the path.
  defp env(variable, default) do
    case System.get_env(variable) do
      value when value in [nil, ""] -> default
      value -> Path.expand(value)
    end
  end
end
