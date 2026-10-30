defmodule Monty.Studio.Drafts do
  @moduledoc """
  Experiments built here, kept as config files.

  A draft is not a database row: it is an experiment file, written where this
  application can compose it and where it could be copied into Monty's own
  `conf/experiment/` unchanged. That is the point of saving one — the studio
  produces configs, not records about configs.

  The directory is `priv/experiments` by default and overridable through
  `:experiments_dir`, which is how a test writes drafts into a temporary
  directory.
  """

  alias Monty.Studio.Blueprint

  @default_dir "priv/experiments"

  # A draft's name becomes a file name, so it is only ever one: letters, digits,
  # `-` and `_`, starting with a letter or a digit.
  @name ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/

  @doc "Where drafts are stored."
  @spec dir() :: Path.t()
  def dir, do: Application.get_env(:ex_tbp_monty, :experiments_dir, @default_dir)

  @doc """
  The file a draft is stored in.

  A name arrives from a form, so it is checked as a file name before it is
  joined onto the directory: a draft called `../../config` would otherwise be a
  draft that writes somewhere it was never meant to reach. What is not a name is
  refused loudly, the way `Artifacts.dir/1` refuses a run id that is not one.
  """
  @spec path(String.t()) :: Path.t()
  def path(name) do
    if draft_name?(name) do
      Path.join(dir(), name <> ".yaml")
    else
      raise ArgumentError, "not a draft name: #{inspect(name)}"
    end
  end

  @doc """
  Whether a draft by this name exists.

  A name that could not be a draft's file name is not a draft, so the answer is
  no rather than an error: Monty's own experiments are named by path
  (`tutorial/first_experiment`), and `Monty.Studio.open/2` asks every name this
  question before it composes one from Monty's conf tree.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(name), do: draft_name?(name) and File.exists?(path(name))

  defp draft_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "The names of every draft, sorted."
  @spec names() :: [String.t()]
  def names do
    dir()
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".yaml"))
    |> Enum.sort()
  end

  @doc "Writes a blueprint as an experiment file."
  # `blueprint.name` reaches `path/1`, which refuses anything that is not one
  # file name, so the write cannot leave the drafts directory.
  # sobelow_skip ["Traversal.FileModule"]
  @spec save(Blueprint.t()) :: {:ok, Path.t()} | {:error, term()}
  def save(%Blueprint{} = blueprint) do
    File.mkdir_p!(dir())
    path = path(blueprint.name)

    case File.write(path, Blueprint.to_yaml(blueprint)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads a draft's text."
  # A name that is not one file name is refused by `path/1` before anything is
  # read.
  # sobelow_skip ["Traversal.FileModule"]
  @spec read(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(name), do: File.read(path(name))

  @doc "Removes a draft."
  # A name that is not one file name is refused by `path/1`, so a delete cannot
  # reach outside the drafts directory.
  # sobelow_skip ["Traversal.FileModule"]
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name), do: File.rm(path(name))
end
