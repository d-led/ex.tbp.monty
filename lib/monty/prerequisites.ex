defmodule Monty.Prerequisites do
  @moduledoc """
  What Monty needs on disk before an experiment can run, and where it goes.

  The paths are Monty's own, not this application's: the same environment
  variables (`MONTY_DATA`, `MONTY_MODELS`, `MONTY_LOGS`) and the same defaults
  the Python tooling uses, so a checkout prepared here is usable there and the
  other way round. Nothing is downloaded from a made-up location — the manifest
  ships the URLs Monty's getting-started guide documents.

  The manifest is data (`priv/prerequisites.yaml`), so adding a prerequisite is
  an edit, not a code change.
  """

  @manifest "priv/prerequisites.yaml"

  @type prerequisite :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          optional(:description) => String.t() | nil,
          required(:url) => String.t(),
          required(:root) => String.t(),
          required(:target) => String.t(),
          optional(:sha256) => String.t() | nil
        }

  @doc "Every configured prerequisite."
  @spec all(Path.t()) :: [prerequisite()]
  def all(manifest \\ manifest_path()) do
    {:ok, document} = YamlElixir.read_from_file(manifest)
    document |> Map.get("prerequisites", []) |> Enum.map(&stringify/1)
  end

  @doc "One prerequisite by id."
  @spec get(String.t(), Path.t()) :: prerequisite() | nil
  def get(id, manifest \\ manifest_path()), do: Enum.find(all(manifest), &(&1.id == id))

  @doc """
  The absolute path a prerequisite belongs at.

  Built from the environment variable its manifest entry names, so a shell
  that already exports `MONTY_MODELS` gets files where Monty expects them.
  """
  @spec target_path(prerequisite()) :: Path.t()
  def target_path(%{root: root, target: target}), do: Path.join(root_path(root), target)

  @doc """
  The directory an environment variable points at, with Monty's default.

  Monty's tooling reads the same three variables with the same defaults, so a
  shell that sets none of them still finds files where Monty expects them.
  """
  @spec root_default(String.t()) :: Path.t()
  def root_default("MONTY_DATA"), do: Path.expand("~/tbp/data")

  def root_default("MONTY_MODELS"),
    do: Path.expand("~/tbp/results/monty/pretrained_models")

  def root_default("MONTY_LOGS"), do: Path.expand("~/tbp/results/monty/projects")

  @doc "The directory an environment variable points at, with Monty's default."
  @spec root_path(String.t()) :: Path.t()
  def root_path("MONTY_DATA"), do: env_path("MONTY_DATA", "~/tbp/data")

  def root_path("MONTY_MODELS"),
    do: env_path("MONTY_MODELS", "~/tbp/results/monty/pretrained_models")

  def root_path("MONTY_LOGS"), do: env_path("MONTY_LOGS", "~/tbp/results/monty/projects")

  def root_path(root) when is_binary(root) do
    raise ArgumentError,
          "unknown prerequisite root #{inspect(root)}; expected MONTY_DATA, MONTY_MODELS or MONTY_LOGS"
  end

  @doc "Whether a prerequisite is already in place."
  @spec present?(prerequisite()) :: boolean()
  def present?(prerequisite), do: File.exists?(target_path(prerequisite))

  @doc "The manifest location, overridable for tests and packagers."
  @spec manifest_path() :: Path.t()
  def manifest_path, do: Application.get_env(:ex_tbp_monty, :prerequisites_manifest, @manifest)

  defp env_path(variable, default) do
    variable |> System.get_env(default) |> Path.expand()
  end

  defp stringify(entry) do
    %{
      id: Map.fetch!(entry, "id"),
      title: Map.fetch!(entry, "title"),
      description: Map.get(entry, "description"),
      url: Map.fetch!(entry, "url"),
      root: Map.fetch!(entry, "root"),
      target: Map.fetch!(entry, "target"),
      sha256: Map.get(entry, "sha256")
    }
  end
end
