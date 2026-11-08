defmodule Mix.Tasks.Monty.Refresh do
  @shortdoc "Updates everything this repo copies or derives from the Monty checkouts"

  @moduledoc """
  One command for "a new Monty landed — bring this repository up to date".

  Two halves of that used to be two undocumented steps: the **copy** of Monty's
  configs, snapshots and licence (`mix monty.inputs`), and the **map** from each
  Python class to the Elixir module that answers for it, with the censuses that
  say which of those a config actually names (`mix monty.module_map.gen`,
  `mix monty.target_census`). Run them in the wrong order and the map records a
  commit the copy is not from.

      mix monty.refresh
      mix monty.refresh --no-update          # copy the checkout exactly as it stands
      mix monty.refresh --source ../monty-orig --teleop-source ../tbp.teleop

  In order, each of which is also a task of its own:

    1. `mix monty.inputs` — fast-forward the checkout, then copy `conf/`,
       `tests/conf/snapshots/` and `LICENSE` into `priv/monty/`;
    2. `mix monty.module_map.gen` — regenerate `lib/monty/module_map/data.ex`
       from the checkouts, recording the commits it was read from;
    3. `mix monty.target_census` — recompose every experiment and collect the
       `_target_`s, into `priv/monty/target_census.json`;
    4. `mix monty.config.snapshots` — compose every experiment and compare it
       with Monty's own snapshot, which is where a pulled config that means
       something else shows up;
    5. `mix monty.module_map.verify` — coverage, every `implemented` entry
       pointing at a real module, every `excluded` one saying why, and no
       checkout further along than the map says;
    6. `mix monty.readiness` — the numbers, because they moved.

  The chain stops at the first step that refuses, whose own message says what to
  do; a step that failed and let the rest run would leave a `target_census.json`
  that describes a tree the map disagrees with. Nothing here is needed to
  compile or test — every artefact is checked in — so this is a task for when
  you mean to change them, and the diff is the review.
  """

  use Mix.Task

  @switches [source: :string, teleop_source: :string, update: :boolean, warn_only: :boolean]

  @impl Mix.Task
  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: @switches)

    for {task, args} <- steps(options) do
      Mix.Task.reenable(task)
      Mix.Task.run(task, args)
    end
  end

  @doc """
  The chain, in order, as `{task, arguments}`, each task given only the arguments
  it takes — `--source` reaches both halves, `--teleop-source` the map only, and
  `--warn-only` the copy and the check but not the generator.
  """
  @spec steps(keyword()) :: [{String.t(), [String.t()]}]
  def steps(options \\ []) do
    source = pair(options, :source)
    teleop = pair(options, :teleop_source)
    warn = if options[:warn_only], do: ["--warn-only"], else: []
    no_update = if options[:update] == false, do: ["--no-update"], else: []

    [
      {"monty.inputs", source ++ no_update ++ warn},
      {"monty.module_map.gen", source ++ teleop},
      {"monty.target_census", ["--json", "priv/monty/target_census.json"]},
      {"monty.config.snapshots", source},
      {"monty.module_map.verify", source ++ teleop ++ warn},
      {"monty.readiness", []}
    ]
  end

  defp pair(options, key) do
    case options[key] do
      nil -> []
      value -> ["--" <> dash(key), value]
    end
  end

  defp dash(key), do: key |> Atom.to_string() |> String.replace("_", "-")
end
