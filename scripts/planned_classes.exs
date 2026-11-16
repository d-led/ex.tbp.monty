# What is planned, and what that costs a run.
#
#   MIX_ENV=test mix run --no-start scripts/planned_classes.exs
#
# Prints, in order:
#
#   1. the map's counts, and every planned class by file;
#   2. a star beside each class a `_target_` in `priv/monty/conf/` names — a class
#      no config names cannot stop a run;
#   3. every experiment whose recognition strategy does not build (asked through
#      `RecognitionStrategy.from_config/1`, the entry point a run uses), with what
#      `mix monty.readiness` says about it;
#   4. the excluded classes, by file.
#
# Re-run this instead of quoting a number from a page.

entries = Monty.ModuleMap.Data.entries()
classes = for e <- entries, c <- e.classes, do: {e.python, c}
counts = Enum.frequencies_by(classes, fn {_, c} -> c.status end)
planned = for {file, c} <- classes, c.status == :planned, do: {file, c}

IO.puts(
  "module map: #{length(entries)} files, #{length(classes)} classes — " <>
    Enum.map_join([:implemented, :partial, :planned, :excluded], ", ", fn s ->
      "#{counts[s] || 0} #{s}"
    end)
)

targets =
  "priv/monty/conf/**/*.yaml"
  |> Path.wildcard()
  |> Enum.flat_map(fn path ->
    path
    |> File.read!()
    |> then(&Regex.scan(~r/_target_:\s*([^\s]+)/, &1))
    |> Enum.map(fn [_, target] -> target |> String.split(".") |> List.last() end)
  end)
  |> MapSet.new()

named = Enum.filter(planned, fn {_, c} -> MapSet.member?(targets, c.python) end)
file_count = planned |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()

IO.puts(
  "\nplanned: #{length(planned)} in #{file_count} files; " <>
    "#{length(named)} of them named by a `_target_` in conf/: " <>
    Enum.map_join(named, ", ", fn {_, c} -> c.python end)
)

planned
|> Enum.group_by(&elem(&1, 0))
|> Enum.sort_by(&elem(&1, 0))
|> Enum.each(fn {file, pairs} ->
  marks =
    pairs
    |> Enum.map(fn {_, c} ->
      if MapSet.member?(targets, c.python), do: c.python <> " *", else: c.python
    end)
    |> Enum.sort()

  IO.puts("\n  #{length(pairs)}  #{file}\n       #{Enum.join(marks, ", ")}")
end)

IO.puts("\n(* = the class name is the last segment of a `_target_` in conf/)")

# --- what the named ones cost -------------------------------------------------

survey = Monty.Studio.Readiness.catalog(world_simulator: :mujoco)
status = Map.new(survey.entries, &{&1.name, &1.status})
IO.puts("\nreadiness (MuJoCo): #{inspect(Enum.frequencies(Map.values(status)))}")

failures =
  Monty.Studio.Catalog.experiments()
  |> Enum.flat_map(fn %{name: name} ->
    with {:ok, opened} <- Monty.Studio.open(name, world_simulator: :mujoco),
         strategy when not is_nil(strategy) <-
           get_in(opened.config, ["experiment", "config", "recognition_strategy"]),
         {:error, reason} <- Monty.Experiment.RecognitionStrategy.from_config(strategy) do
      [{name, Map.get(status, name), reason}]
    else
      _ -> []
    end
  end)

IO.puts("\nexperiments whose recognition strategy does not build: #{length(failures)}")
IO.puts("  by readiness status: #{inspect(Enum.frequencies(Enum.map(failures, &elem(&1, 1))))}")
IO.puts("  reasons: #{inspect(failures |> Enum.map(&elem(&1, 2)) |> Enum.uniq())}")
Enum.each(failures, fn {name, where, _} -> IO.puts("    #{name}  (#{where})") end)

# --- the classes somebody decided about ---------------------------------------

excluded = for {file, c} <- classes, c.status == :excluded, do: {file, c}

IO.puts("\nexcluded: #{length(excluded)}")

excluded
|> Enum.frequencies_by(&elem(&1, 0))
|> Enum.sort_by(fn {_, n} -> -n end)
|> Enum.each(fn {f, n} -> IO.puts("  #{n}  #{f}") end)

partial = for {file, c} <- classes, c.status == :partial, do: "#{file}: #{c.python}"
IO.puts("\npartial: #{Enum.join(partial, "; ")}")
