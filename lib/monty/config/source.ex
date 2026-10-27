defmodule Monty.Config.Source do
  @moduledoc """
  Reads Monty's own Hydra/OmegaConf config files.

  The promise this module exists for: a config that Monty ships can be handed
  to this application unchanged. Nothing here knows what an experiment *means*;
  it only knows how Hydra lays one out on disk.

  What is implemented is the subset Monty actually uses (checked against its
  `conf/` tree): a `defaults:` list, `_self_`, `# @package` headers, and
  `group@package` overrides. There is no `override` syntax, no `optional:`
  marker and no CLI group override in the tree, so none of those are invented
  here.
  """

  @type config :: %{
          package: [String.t()] | nil,
          defaults: [default()],
          body: map() | nil,
          file: Path.t()
        }

  @type default ::
          :self | {:group, String.t(), String.t() | :missing, String.t() | nil}

  @doc """
  The Monty checkout to read configs from.

  `MONTY_SOURCE` wins; otherwise `../monty-orig` next to the project, which is
  where the reference checkout lives in this workspace.
  """
  @spec root() :: Path.t()
  def root do
    Application.get_env(:ex_tbp_monty, :monty_source) ||
      Path.expand(System.get_env("MONTY_SOURCE", "../monty-orig"))
  end

  @doc "The Hydra config directory inside a Monty checkout."
  @spec conf_dir(Path.t()) :: Path.t()
  def conf_dir(root \\ root()), do: Path.join([root, "src", "tbp", "monty", "conf"])

  @doc """
  The teleop checkout to read from.

  `TELEOP_SOURCE` wins; otherwise `../tbp.teleop` next to the project, which is
  where the reference checkout lives in this workspace.
  """
  @spec teleop_root() :: Path.t()
  def teleop_root do
    Application.get_env(:ex_tbp_monty, :teleop_source) ||
      Path.expand(System.get_env("TELEOP_SOURCE", "../tbp.teleop"))
  end

  @doc """
  Names of the experiments Monty ships, relative to the `experiment` group and
  without the `.yaml` suffix.

  Nested directories (`test/`, `tutorial/`) are included with their prefix, so
  `test/run` is a name an experiment can be launched by.
  """
  @spec experiments(Path.t()) :: [String.t()]
  def experiments(conf_dir \\ conf_dir()) do
    Path.join(conf_dir, "experiment")
    |> Path.join("**/*.yaml")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.relative_to(Path.join(conf_dir, "experiment"))
      |> String.trim_trailing(".yaml")
    end)
    |> Enum.sort()
  end

  @doc "Loads one config file of a group."
  @spec load(Path.t(), String.t(), String.t()) :: {:ok, config()} | {:error, term()}
  def load(conf_dir, group, option) do
    path = path_for(conf_dir, group, option)

    with {:ok, text} <- read(path),
         {:ok, document} <- parse_yaml(text, path) do
      {:ok, describe(document, text, path)}
    end
  end

  @doc "The file a group option lives in."
  @spec path_for(Path.t(), String.t(), String.t()) :: Path.t()
  def path_for(conf_dir, group, option) do
    segments = group |> String.split("/", trim: true)
    Path.join([conf_dir | segments] ++ [option <> ".yaml"])
  end

  @doc """
  The package a group's config lands in when the file does not say.

  Hydra's default package for `- group: option` is the group path with dots, so
  `monty/connectivity` lands at `monty.connectivity` unless a `# @package`
  header overrides it. Monty's files almost always override it; this is the
  fallback that makes the rule complete.
  """
  @spec default_package(String.t()) :: [String.t()]
  def default_package(group) do
    group
    |> String.split("/", trim: true)
    |> Enum.reject(&(&1 == "_global_"))
  end

  defp read(path) do
    # The path is the Monty checkout's own config tree (root + group + option),
    # never request or user input; the finding is reviewed in .sobelow-skips.
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:cannot_read, path, reason}}
    end
  end

  defp parse_yaml(text, path) do
    case YamlElixir.read_from_string(text) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, other} -> {:error, {:not_a_mapping, path, other}}
      {:error, reason} -> {:error, {:invalid_yaml, path, reason}}
    end
  end

  defp describe(document, text, path) do
    {defaults, body} = Map.pop(document, "defaults", [])

    %{
      package: package_header(text),
      defaults: Enum.map(defaults, &parse_default/1),
      body: body,
      file: path
    }
  end

  # Only the leading comment block may announce a package: a `# @package` in a
  # comment further down is documentation, not routing.
  defp package_header(text) do
    text
    |> String.split("\n")
    |> Enum.take_while(&comment_or_blank?/1)
    |> Enum.join("\n")
    |> then(&Regex.run(~r/^#\s*@package\s+(\S+)\s*$/m, &1))
    |> case do
      [_, "_global_"] -> []
      [_, package] -> String.split(package, ".")
      nil -> nil
    end
  end

  defp comment_or_blank?(line), do: String.trim(line) == "" or String.starts_with?(line, "#")

  defp parse_default("_self_"), do: :self

  # `- group/option@package` is Hydra's shorthand for `- group: option` with the
  # loaded config placed at `package`. The last path segment is the option; a
  # path without a leading slash is relative to the config that includes it.
  defp parse_default(entry) when is_binary(entry) do
    {path, package} = split_package(entry)
    {group, option} = split_group_option(path)
    {:group, group, parse_option(option), package}
  end

  defp parse_default(entry) when is_map(entry) and map_size(entry) == 1 do
    [{group_and_package, option}] = Map.to_list(entry)
    {group, package} = split_package(group_and_package)
    {:group, group, parse_option(option), package}
  end

  defp parse_default(entry), do: {:error, {:unsupported_default, entry}}

  defp split_group_option(path) do
    case String.split(path, "/", trim: true) do
      [option] -> {"/", option}
      segments -> {segments |> Enum.drop(-1) |> Enum.join("/"), List.last(segments)}
    end
  end

  defp split_package(group_and_package) do
    case String.split(group_and_package, "@") do
      [group, package] -> {group, package}
      [group] -> {group, nil}
    end
  end

  defp parse_option("??"), do: :missing
  defp parse_option(option), do: option
end
