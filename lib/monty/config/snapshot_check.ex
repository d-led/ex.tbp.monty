defmodule Monty.Config.SnapshotCheck do
  @moduledoc """
  Compares composed configs against Monty's committed snapshots.

  `tests/conf/snapshots/*.yaml` in a Monty checkout is the oracle: each file is
  the config Hydra composed when it was written. If our composer produces the
  same tree, an experiment config means the same thing here as it does there.

  Used by both `mix monty.config.snapshots` and the parity test, so the number a
  contributor sees in the terminal is the number CI asserts on.
  """

  alias Monty.Config.{Composer, Source}

  @type difference :: %{
          experiment: String.t(),
          path: String.t(),
          snapshot: term() | :absent,
          composed: term() | :absent
        }

  @doc """
  Checks every snapshot in the checkout.

  Returns the number of experiments compared, or the differences found.
  """
  @spec run(keyword()) :: {:ok, non_neg_integer()} | {:error, [difference()] | term()}
  def run(opts \\ []) do
    root = Keyword.get_lazy(opts, :source, fn -> Source.root() end)
    conf_dir = Source.conf_dir(root)
    snapshots_dir = Path.join([root, "tests", "conf", "snapshots"])

    with :ok <- ensure_directory(conf_dir),
         :ok <- ensure_directory(snapshots_dir) do
      names = snapshot_names(snapshots_dir)

      differences =
        Enum.flat_map(names, fn name ->
          compare(name, Path.join(snapshots_dir, name <> ".yaml"), conf_dir)
        end)

      case differences do
        [] -> {:ok, length(names)}
        differences -> {:error, differences}
      end
    end
  end

  @doc "Checks one experiment against its snapshot."
  @spec compare(String.t(), Path.t(), Path.t()) :: [difference()]
  def compare(name, snapshot_path, conf_dir) do
    {:ok, expected} = YamlElixir.read_from_file(snapshot_path)

    case Composer.compose(name, conf_dir: conf_dir) do
      {:ok, composed} ->
        differences(name, expected, composed)

      {:error, reason} ->
        [%{experiment: name, path: "<compose>", snapshot: :ok, composed: reason}]
    end
  end

  defp differences(name, expected, composed) do
    diff_paths(expected, composed, [])
    |> Enum.map(fn {path, left, right} ->
      %{experiment: name, path: Enum.join(path, "."), snapshot: left, composed: right}
    end)
  end

  defp diff_paths(left, right, path) when is_map(left) and is_map(right) do
    keys = Enum.uniq(Map.keys(left) ++ Map.keys(right))

    Enum.flat_map(keys, fn key ->
      case {Map.fetch(left, key), Map.fetch(right, key)} do
        {{:ok, same}, {:ok, same}} ->
          []

        {{:ok, left_value}, {:ok, right_value}} ->
          diff_paths(left_value, right_value, path ++ [key])

        {{:ok, left_value}, :error} ->
          [{path ++ [key], left_value, :absent}]

        {:error, {:ok, right_value}} ->
          [{path ++ [key], :absent, right_value}]
      end
    end)
  end

  defp diff_paths(left, right, path) do
    if left == right, do: [], else: [{path, left, right}]
  end

  defp snapshot_names(snapshots_dir) do
    snapshots_dir
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.trim_trailing(".yaml")))
    |> Enum.sort()
  end

  defp ensure_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, {:missing_directory, path}}
  end
end
