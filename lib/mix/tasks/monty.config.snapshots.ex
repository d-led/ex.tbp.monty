defmodule Mix.Tasks.Monty.Config.Snapshots do
  @shortdoc "Composes every Monty experiment and compares it to Monty's snapshots"

  @moduledoc """
  The compatibility gate for experiment configs:

      mix monty.config.snapshots                 # against the shipped copy
      mix monty.config.snapshots --source ../monty-orig   # against a checkout

  Monty ships `tests/conf/snapshots/<experiment>.yaml` — the tree Hydra
  composed. This task composes the same experiment from the same YAML files and
  reports any difference, path by path. Both a missing key and an extra one are
  differences; "close enough" is how a config silently means something else.

  The config tree and the snapshots are copied verbatim into `priv/monty` by
  `mix monty.inputs`, so this runs with no Monty checkout at all.
  `--source` points both halves at a checkout instead, which is what a person
  reviewing an upstream pull wants.
  """

  use Mix.Task

  alias Monty.Config.{SnapshotCheck, Source}

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [source: :string])

    case SnapshotCheck.run(check_opts(opts)) do
      {:ok, count} ->
        Mix.shell().info("config: #{count} snapshot(s) match")

      {:error, differences} when is_list(differences) ->
        Enum.each(Enum.take(differences, 10), fn difference ->
          Mix.shell().error(
            "#{difference.experiment} #{difference.path}: " <>
              "snapshot #{inspect(difference.snapshot, limit: 8)} " <>
              "vs composed #{inspect(difference.composed, limit: 8)}"
          )
        end)

        Mix.raise("#{length(differences)} difference(s) from Monty's snapshots")

      {:error, reason} ->
        Mix.raise("cannot check snapshots: #{inspect(reason)}")
    end
  end

  defp check_opts(opts) do
    case opts[:source] do
      nil ->
        []

      source ->
        root = Path.expand(source)
        [conf_dir: Source.conf_dir(root), snapshots_dir: Source.snapshots_dir(root)]
    end
  end
end
