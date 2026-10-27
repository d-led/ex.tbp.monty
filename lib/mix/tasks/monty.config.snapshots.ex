defmodule Mix.Tasks.Monty.Config.Snapshots do
  @shortdoc "Composes every Monty experiment and compares it to Monty's snapshots"

  @moduledoc """
  The compatibility gate for experiment configs:

      mix monty.config.snapshots
      mix monty.config.snapshots --source ../monty-orig

  Monty ships `tests/conf/snapshots/<experiment>.yaml` — the tree Hydra
  composed. This task composes the same experiment from the same YAML files and
  reports any difference, path by path. Both a missing key and an extra one are
  differences; "close enough" is how a config silently means something else.
  """

  use Mix.Task

  alias Monty.Config.SnapshotCheck

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [source: :string])

    case SnapshotCheck.run(opts) do
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
end
