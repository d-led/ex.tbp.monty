defmodule Mix.Tasks.Monty.TargetCensus do
  @shortdoc "Says which planned classes Monty's own configs actually name"

  @moduledoc """
  Step two of the porting plan: what the configs ask for.

  `mix monty.port_census` says what kind of thing each planned class is. This says
  which of them a run of one of Monty's experiments would actually build, by
  composing every experiment Monty ships a snapshot for and collecting every
  `_target_` in the tree — Hydra's own way of naming a class to instantiate.

      mix monty.target_census
      mix monty.target_census --json priv/monty/target_census.json

  Two answers come out, and they are the ones that order the backlog:

    * **named by configs and still planned** — a run of an experiment that names
      it builds it, so it is on the path whether or not anything calls it yet;
    * **has behaviour but no config names it** — no experiment asks for it by
      name, so porting it does not change what a standard run does. That is not
      the same as dead: another class may build it in code.

  The second answer uses `priv/monty/port_census.json` (what each planned class
  is) when it is there, so the two censuses read as one statement: this class has
  behaviour *and* a config names it.
  """

  use Mix.Task

  alias Monty.Config.{Composer, SnapshotCheck, Source}
  alias Monty.ModuleMap

  @port_census "priv/monty/port_census.json"

  @impl Mix.Task
  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: [json: :string])
    root = Source.root()
    conf_dir = Source.conf_dir(root)
    names = SnapshotCheck.names(root)

    counts = count_targets(names, conf_dir)

    report(counts, names, options[:json])
  end

  # One number per target: how many experiments name it. A class named by twelve
  # experiments is on the path of twelve experiments; one named by none is only
  # reachable from code.
  defp count_targets(names, conf_dir) do
    names
    |> Enum.flat_map(fn name ->
      case Composer.compose(name, conf_dir: conf_dir) do
        {:ok, tree} -> targets(tree) |> Enum.uniq() |> Enum.map(&{&1, name})
        {:error, _reason} -> []
      end
    end)
    |> Enum.group_by(fn {target, _name} -> target end, fn {_target, name} -> name end)
    |> Map.new(fn {target, experiments} -> {target, Enum.sort(experiments)} end)
  end

  defp targets(tree), do: tree |> walk([]) |> Enum.reverse()

  defp walk(map, found) when is_map(map) do
    Enum.reduce(map, found, fn
      {"_target_", target}, found when is_binary(target) -> [target | found]
      {_key, value}, found -> walk(value, found)
    end)
  end

  defp walk(list, found) when is_list(list), do: Enum.reduce(list, found, &walk/2)
  defp walk(_other, found), do: found

  defp report(counts, names, json_out) do
    resolved =
      Map.new(counts, fn {target, experiments} -> {target, resolve(target, experiments)} end)

    if json_out do
      File.mkdir_p!(Path.dirname(json_out))
      File.write!(json_out, Jason.encode!(resolved, pretty: true))
      Mix.shell().info("wrote #{json_out}")
    end

    planned = for {_target, entry} <- resolved, entry.status == :planned, do: entry

    Mix.shell().info("#{map_size(resolved)} target(s) named by #{length(names)} experiment(s)")
    Mix.shell().info("#{length(planned)} of them are still planned here")

    Mix.shell().info("\nnamed by configs, still planned: what a run would build")

    planned
    |> Enum.sort_by(&{-&1.snapshots, &1.class})
    |> Enum.take(20)
    |> Enum.each(fn entry ->
      Mix.shell().info(
        "  #{entry.snapshots |> Integer.to_string() |> String.pad_leading(3)}  #{entry.class}"
      )
    end)

    unclaimed = with_behaviour_named_by_nothing(resolved)
    Mix.shell().info("\nhas behaviour, no config names it: not on a config's path")
    unclaimed |> Enum.sort() |> Enum.each(&Mix.shell().info("       #{&1}"))
  end

  defp resolve(target, experiments) do
    class = target |> String.split(".") |> List.last()

    case ModuleMap.resolve(target) do
      {:ok, entry} ->
        %{
          class: class,
          target: target,
          elixir: entry.elixir,
          status: entry.status,
          snapshots: length(experiments),
          experiments: experiments
        }

      :error ->
        %{
          class: class,
          target: target,
          elixir: nil,
          status: :unknown,
          snapshots: length(experiments),
          experiments: experiments
        }
    end
  end

  # A planned class that Monty's code implements but no config names. Not named
  # by a config is not the same as dead: another class can build it, so read this
  # as "no experiment asks for it by name", which is what decides whether porting
  # it changes what a standard run does.
  defp with_behaviour_named_by_nothing(resolved) do
    named =
      resolved
      |> Map.values()
      |> Enum.map(& &1.class)
      |> MapSet.new()

    @port_census
    |> File.read()
    |> case do
      {:ok, body} ->
        body
        |> Jason.decode!()
        |> Enum.filter(fn {_key, entry} -> entry["behaviour"] == "some" end)
        |> Enum.map(fn {_key, entry} -> entry["class"] end)
        |> Enum.reject(&MapSet.member?(named, &1))

      {:error, _reason} ->
        ["(no #{@port_census}: run `mix monty.port_census --json #{@port_census}` first)"]
    end
  end
end
