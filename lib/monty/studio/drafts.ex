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

  alias Monty.Config.Source
  alias Monty.Studio.Blueprint
  alias Monty.Studio.Setup

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

  @doc """
  The experiment as a file: the text a person would edit, not what it composes to.

  A draft is already a file. A Monty experiment is exported from its own config
  tree — the `defaults:` list that names groups — because that is the file worth
  copying and changing: it is short, it reads as choices, and it composes here
  exactly as it does in Monty.

  The name is checked against the catalog rather than joined onto a path, so a
  name that is not an experiment Monty ships cannot reach outside the tree.
  """
  @spec export(String.t()) :: {:ok, map()} | {:error, String.t()}
  def export(name) do
    cond do
      exists?(name) ->
        with {:ok, text} <- read(name),
             do: {:ok, %{name: name, source: :draft, filename: file_name(name), yaml: text}}

      name in Source.experiments() ->
        export_monty(name)

      true ->
        {:error, "`#{name}` is neither a draft nor an experiment Monty ships."}
    end
  end

  # Only a name Monty ships gets here (`export/1` checks `Source.experiments/0`
  # first), and the file is read under the checked-in `conf` directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp export_monty(name) do
    path = Path.join([Source.conf_dir(), "experiment", name <> ".yaml"])

    case File.read(path) do
      {:ok, text} ->
        {:ok, %{name: name, source: :monty, filename: file_name(name), yaml: text}}

      {:error, reason} ->
        {:error, "`#{name}` cannot be read: #{inspect(reason)}"}
    end
  end

  # A download's file name is one segment: `tutorial/first_experiment` becomes
  # `tutorial_first_experiment.yaml`, which is what a browser can save.
  defp file_name(name), do: String.replace(name, "/", "_") <> ".yaml"

  @doc """
  Keeps an experiment file that came from somewhere else, as a draft.

  A file from another machine is a config this application has not seen, so it
  is composed before it is written: a file that is not a Hydra config is an
  error, and one that composes but would not run is saved *and* reported as such
  — findings are the answer to "what is wrong with it", not a reason to refuse
  the question.

  The name is a new name, not the file's: a draft is one file name, and
  overwriting an existing draft takes `overwrite: true`.
  """
  # `importable_name/1` and `path/1` refuse anything that is not one file name,
  # so neither the directory nor the file it writes can leave the drafts dir.
  # sobelow_skip ["Traversal.FileModule"]
  @spec import(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def import(name, yaml, opts \\ []) do
    with :ok <- importable_name(name),
         :ok <- addressable(name, opts[:overwrite] == true),
         {:ok, setup} <- Setup.from_text(yaml, name: name) do
      File.mkdir_p!(dir())

      case File.write(path(name), yaml) do
        :ok ->
          {:ok,
           %{
             name: name,
             path: path(name),
             valid?: Setup.valid?(setup),
             findings: setup.findings
           }}

        {:error, reason} ->
          {:error, "`#{name}` cannot be written: #{inspect(reason)}"}
      end
    end
  end

  defp importable_name(name) do
    if draft_name?(name),
      do: :ok,
      else:
        {:error,
         "`#{name}` cannot be a draft's name: letters, digits, `-` and `_` only, " <>
           "starting with a letter or a digit. Rename the file you are importing."}
  end

  defp addressable(_name, true), do: :ok

  defp addressable(name, false) do
    if exists?(name),
      do:
        {:error, "a draft named `#{name}` is already here; import with `overwrite` to replace it"},
      else: :ok
  end
end
