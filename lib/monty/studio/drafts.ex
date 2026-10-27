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

  @doc "Where drafts are stored."
  @spec dir() :: Path.t()
  def dir, do: Application.get_env(:ex_tbp_monty, :experiments_dir, @default_dir)

  @doc "The file a draft is stored in."
  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(dir(), name <> ".yaml")

  @doc "Whether a draft by this name exists."
  @spec exists?(String.t()) :: boolean()
  def exists?(name), do: File.exists?(path(name))

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
  @spec read(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(name), do: File.read(path(name))

  @doc "Removes a draft."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name), do: File.rm(path(name))
end
