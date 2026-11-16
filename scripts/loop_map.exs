# Where the main loops stand, function by function.
#
#   MIX_ENV=test mix run --no-start scripts/loop_map.exs [--source ../monty-orig]
#
# The module map pairs Monty's *classes* with this port's modules. This script
# pairs the functions inside the classes the loops are made of, because a loop is
# 1:1 with Monty's only if its steps are. A method with no counterpart on one
# side is one of two things:
#
#   * a rename this port should not have made — fix the port;
#   * a piece Monty has that this port has not reached yet — say so and stop.
#
# Monty's leading underscores are dropped and a predicate's trailing `?` too, so
# `_sample_count` pairs with `sample_count`. The dunders pair with the lifecycle
# functions this port uses: `__init__` is `new`, `__enter__` is `begin_step`,
# `__exit__` is `end_step`.
#
# Output, per loop class: how many methods and functions it has, then the names
# that are on one side only — with the nearest name on the other side, so a
# rename reads as a near miss instead of as two unrelated words.

defmodule LoopMap do
  alias Monty.ModuleMap.Data

  # The files a step is made of: the experiment's loop, the model that drives the
  # modules, the learning module, and the updaters and displacer it calls.
  @loops [
    "frameworks/experiments/monty_experiment.py",
    "frameworks/models/monty_base.py",
    "frameworks/models/evidence_matching/model.py",
    "frameworks/models/evidence_matching/learning_module.py",
    "frameworks/models/evidence_matching/hypotheses_updater.py",
    "frameworks/models/evidence_matching/burst_sampling.py",
    "frameworks/models/evidence_matching/hypotheses_displacer.py"
  ]

  @lifecycle %{"__init__" => "new", "__enter__" => "begin_step", "__exit__" => "end_step"}

  def run(source) do
    IO.puts("monty: #{source}")
    IO.puts("module map read from: #{inspect(Data.sources(), limit: :infinity)}\n")

    for entry <- Data.entries(), entry.python in @loops do
      for class <- entry.classes, class.status == :implemented, class[:file] do
        report(
          entry.python,
          class.python,
          class.elixir,
          methods(source, entry.python, class.python),
          functions(class.file)
        )
      end
    end

    pairless =
      for file <- @loops,
          not Enum.any?(Data.entries(), fn entry ->
            entry.python == file and Enum.any?(entry.classes, &(&1.status == :implemented))
          end),
          do: file

    if pairless != [] do
      IO.puts("not paired in the map, so not checked here:")

      Enum.each(pairless, fn file ->
        exists? = File.exists?(Path.join(source, "src/tbp/monty/" <> file))
        IO.puts("  #{file}#{if exists?, do: "", else: " (not in this checkout)"}")
      end)
    end
  end

  defp report(python_file, python_class, elixir_module, python, elixir) do
    {paired, python_only} = pair(python, elixir)
    elixir_only = elixir -- Enum.map(paired, fn {_python, elixir} -> elixir end)

    IO.puts("#{python_file}::#{python_class} -> #{elixir_module}")

    IO.puts(
      "  #{length(python)} methods, #{length(elixir)} functions, " <>
        "#{length(paired)} paired by name"
    )

    for {name, nearest} <- python_only, do: IO.puts("  monty only: #{name} (nearest: #{nearest})")
    for name <- elixir_only, do: IO.puts("  port only:  #{name}")

    IO.puts("")
  end

  # Pairs both sides, and names the nearest Elixir function for a Monty method
  # that has no counterpart, so a rename is visible as a near miss.
  defp pair(python, elixir) do
    Enum.reduce(python, {[], []}, fn name, {paired, missing} ->
      case nearest(name, elixir) do
        {:exact, counterpart} -> {paired ++ [{name, counterpart}], missing}
        {:near, counterpart} -> {paired, missing ++ [{name, counterpart}]}
        :none -> {paired, missing ++ [{name, "—"}]}
      end
    end)
  end

  defp nearest(name, elixir) do
    case Enum.find(elixir, &(&1 == name)) do
      nil ->
        case Enum.map(elixir, &{&1, String.jaro_distance(name, &1)}) do
          [] ->
            :none

          scored ->
            {closest, similarity} = Enum.max_by(scored, &elem(&1, 1))
            if similarity > 0.75, do: {:near, closest}, else: :none
        end

      counterpart ->
        {:exact, counterpart}
    end
  end

  # Similarity is `String.jaro_distance/2`, which is a hint for a human — it
  # names the function a rename most probably became — and not a decision.

  # Monty's methods of one class: `    def name(` at that indent, from the class
  # line to the next one.
  defp methods(source, python_file, class) do
    path = Path.join(source, "src/tbp/monty/" <> python_file)

    case File.read(path) do
      {:ok, text} -> text |> String.split("\n") |> methods_of(class)
      {:error, _reason} -> []
    end
  end

  defp methods_of(lines, class) do
    lines
    |> Enum.drop_while(&(not Regex.match?(~r/^class #{Regex.escape(class)}\b/, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not Regex.match?(~r/^class /, &1)))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^    def ([a-zA-Z_0-9]+)\(/, line) do
        [_, name] -> [name |> then(&Map.get(@lifecycle, &1, &1)) |> String.trim_leading("_")]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  # This port's functions in one file, without the keyword and without arities: a
  # loop pairs by name, and an arity difference is a different question.
  defp functions(file) do
    case File.read(file) do
      {:ok, text} ->
        ~r/^  defp? ([a-z_0-9]+[?]?)/m
        |> Regex.scan(text)
        |> Enum.map(fn [_, name] -> String.trim_trailing(name, "?") end)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end
end

{options, _argv} = OptionParser.parse!(System.argv(), strict: [source: :string])
source = Keyword.get(options, :source) || System.get_env("MONTY_ROOT", "../monty-orig")

LoopMap.run(Path.expand(source))
