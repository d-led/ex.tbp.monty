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

  ## One node, or one of several

  On a node that runs alone everything hangs off `root/0`. A node that was given
  a name as part of a cluster keeps what is *its* under
  `<root>/nodes/<its name>` — `node_root/0` — because two nodes on one machine
  must not open the same SQLite file, and the runs each writes are its own. What
  they do share is what is downloaded and derived from downloads: `data/0`,
  `models/0` and `libraries/0` are the same gigabytes on both, and fetching them
  twice would be a gigabyte twice.

  The name is not read here. `config/runtime.exs` asks
  `ExTbpMonty.Node.data_dir_name/0` — which is `nil` on a node that runs alone —
  and puts the answer in `:data_dir_name`, so this module stays a module about
  paths, and a test can place a node's folder without being a node.

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

  @doc """
  The folder *this node* keeps its own things in.

  The same as `root/0` on a node that runs alone, and `<root>/nodes/<name>` on a
  node that was given a name: its database, its runs and its own output are not
  another node's. `data_dir_name/0` says which of the two this is.
  """
  @spec node_root() :: Path.t()
  def node_root do
    case data_dir_name() do
      nil -> root()
      name -> Path.join([root(), "nodes", name])
    end
  end

  @doc """
  The name this node's folder carries, or `nil` on a node that runs alone.

  Set by `config/runtime.exs` from `ExTbpMonty.Node.data_dir_name/0` — a node
  name made safe for a path, nothing more.
  """
  @spec data_dir_name() :: String.t() | nil
  def data_dir_name do
    case Application.get_env(:ex_tbp_monty, :data_dir_name) do
      name when name in [nil, ""] -> nil
      name -> name
    end
  end

  @doc "Monty's object data — the `MONTY_DATA` root."
  @spec data() :: Path.t()
  def data, do: env("MONTY_DATA", Path.join(root(), "data"))

  @doc "Monty's pretrained model archives — the `MONTY_MODELS` root."
  @spec models() :: Path.t()
  def models, do: env("MONTY_MODELS", Path.join(root(), "models"))

  @doc """
  Where Monty writes a run's own output — the `MONTY_LOGS` root.

  A node's own: two nodes running experiments at once write two runs, not one
  run's lines twice.
  """
  @spec logs() :: Path.t()
  def logs, do: env("MONTY_LOGS", Path.join(node_root(), "projects"))

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

  One file in this node's own folder: a desktop install is one reader, and a file
  is the database it can have without installing a server. Two nodes sharing one
  file is the arrangement this module exists to avoid.
  """
  @spec database() :: Path.t()
  def database, do: env("SQLITE_PATH", Path.join(node_root(), @database_file))

  @doc """
  The files a run leaves beside its record: its log, its pictures, its statistics
  and the memory it learned.

  `config/runtime.exs` points `:studio_artifacts_dir` here, so the desktop build
  writes them under the root above while development keeps writing them into the
  checkout.

  `MONTY_ARTIFACTS_DIR` is the one lever a cluster has, and it is the whole
  difference between a part that may run on another node and one that may not: a
  part performed elsewhere writes all of this here (`Monty.Studio.Artifacts`), and
  the node that merges the parts reads it back, so both nodes have to be looking at
  one directory. The default stays this node's own folder — what a node that runs
  alone wants, and what an unchanged deployment keeps.
  """
  @spec artifacts() :: Path.t()
  def artifacts, do: env("MONTY_ARTIFACTS_DIR", Path.join(node_root(), "runs"))

  @doc """
  Whether anybody pointed a run's files somewhere, rather than leaving the default.

  The fact a page can state. Whether the directory two nodes read is really one
  directory is a deployment's business — a mount, a share, or a mistake — and
  nothing here can tell those apart, so it says what it knows: the root, and whether
  `MONTY_ARTIFACTS_DIR` chose it.
  """
  @spec artifacts_from_environment?() :: boolean()
  def artifacts_from_environment? do
    # Asked of the shell rather than through `env/2`, whose answer is a path: a
    # `nil` default would put `nil` in the type of every path this module answers
    # with, and "nobody said" has to stay the same two cases `env/2` treats as one.
    case System.get_env("MONTY_ARTIFACTS_DIR") do
      value when value in [nil, ""] -> false
      _said -> true
    end
  end

  @doc "Where wandb writes what a run logs, when it logs anything."
  @spec wandb() :: Path.t()
  def wandb, do: Path.join(node_root(), "wandb")

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
