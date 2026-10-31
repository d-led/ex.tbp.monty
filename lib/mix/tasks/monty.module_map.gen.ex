defmodule Mix.Tasks.Monty.ModuleMap.Gen do
  @shortdoc "Regenerates lib/monty/module_map/data.ex from the Monty and teleop checkouts"

  @moduledoc """
  Walks the Python packages this application mirrors and writes the map every
  other tool reads:

      mix monty.module_map.gen
      mix monty.module_map.gen --source ../monty-orig --teleop-source ../tbp.teleop

  Each file becomes an entry with the Elixir module its path maps to, its
  classes, and whether that Elixir module exists yet. The rule is
  `docs/module-map.md`: `Monty.<path>.<Class>` for `tbp/monty`,
  `Teleop.<file>.<Class>` for `tbp/teleop`.

  The map is written as `Monty.ModuleMap.Data`, a literal list compiled in, and
  not as a file read at run time: what the map says decides which modules this
  application claims to implement, so it is code beside the code it describes.

  Statuses survive a regeneration: an entry marked `excluded` with a reason
  stays excluded, and an entry whose module now exists becomes `implemented`.

  `--reset-decisions` recomputes everything from the checkouts and carries
  nothing over. It repairs a map whose decisions were wrong; it is not how the
  map is normally regenerated.
  """

  use Mix.Task

  alias Monty.ModuleMap

  @map_path "lib/monty/module_map/data.ex"

  @impl true
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [source: :string, teleop_source: :string, reset_decisions: :boolean]
      )

    configure_sources(opts)

    decisions = if opts[:reset_decisions], do: %{}, else: read_existing()

    entries =
      ModuleMap.packages()
      |> Enum.flat_map(&entries_for(&1, decisions))
      |> Enum.sort_by(&{&1.package, &1.python})

    File.mkdir_p!(Path.dirname(@map_path))
    File.write!(@map_path, render(entries) |> Code.format_string!())

    summary = ModuleMap.summary(entries)

    Mix.shell().info(
      "#{@map_path}: #{summary.files} files, #{summary.classes} classes, " <>
        "#{summary.implemented} implemented, per package: #{inspect(summary.by_package)}"
    )
  end

  defp configure_sources(opts) do
    if source = opts[:source],
      do: Application.put_env(:ex_tbp_monty, :monty_source, Path.expand(source))

    if source = opts[:teleop_source],
      do: Application.put_env(:ex_tbp_monty, :teleop_source, Path.expand(source))
  end

  defp entries_for(package, existing) do
    Enum.map(ModuleMap.python_files(package), fn relative ->
      elixir = ModuleMap.module_for(package.namespace, relative)
      known = Map.get(existing, {package.name, relative}, %{})

      %{
        package: package.name,
        python: relative,
        elixir: elixir,
        status: status(package.name, known, elixir, relative),
        reason: known[:reason] || default_reason(package.name, relative),
        classes:
          for class <- classes_in(package, relative) do
            class_entry(package.name, known, elixir, class, relative)
          end
      }
    end)
  end

  defp status(package, known, elixir, relative) do
    cond do
      known[:status] == :excluded -> :excluded
      tooling?(package, relative) -> :excluded
      module_exists?(elixir) -> :implemented
      true -> :planned
    end
  end

  defp class_status(package, known, elixir, class, relative) do
    excluded_classes = Map.get(known, :excluded_classes, %{})

    cond do
      Map.has_key?(excluded_classes, class) -> :excluded
      status(package, known, elixir, relative) == :excluded -> :excluded
      module_exists?(ModuleMap.class_module(elixir, class, relative)) -> :implemented
      true -> :planned
    end
  end

  defp class_entry(package, known, elixir, class, relative) do
    %{
      python: class,
      elixir: ModuleMap.class_module(elixir, class, relative),
      status: class_status(package, known, elixir, class, relative)
    }
    |> put_reason(excluded_class_reason(known, class))
  end

  # `reason: nil` on every class of every file would bury the two classes that
  # have one, so the key is written only where it means something.
  defp put_reason(entry, nil), do: entry
  defp put_reason(entry, reason), do: Map.put(entry, :reason, reason)

  defp excluded_class_reason(known, class) do
    known |> Map.get(:excluded_classes, %{}) |> Map.get(class)
  end

  # Hydra's own tooling lives in the Monty package but is not part of the
  # runtime; `Monty.Config` replaces it.
  defp tooling?("monty", relative), do: String.starts_with?(relative, "conf/")
  defp tooling?(_package, _relative), do: false

  # `conf/make_environment.py` sits with the tooling but is not tooling: it
  # computes the grid the sensor mount positions sit on, and only Monty's own
  # unit-test resources call it — no config names it.
  defp default_reason("monty", "conf/make_environment.py") do
    "Sensor-mount grid layout; used only by Monty's unit-test resources, not by a config"
  end

  defp default_reason("monty", relative) do
    if tooling?("monty", relative),
      do: "Hydra config tooling; superseded by Monty.Config",
      else: nil
  end

  defp default_reason(_package, _relative), do: nil

  defp module_exists?(module) do
    module
    |> String.split(".")
    |> Module.concat()
    |> Code.ensure_loaded?()
  end

  defp classes_in(package, relative) do
    dir = Path.join(package.root.(), package.relative)

    dir
    |> Path.join(relative)
    |> File.read!()
    |> then(&Regex.scan(~r/^class\s+([A-Z]\w*)/m, &1))
    |> Enum.map(fn [_, class] -> class end)
  end

  defp read_existing do
    if Code.ensure_loaded?(Monty.ModuleMap.Data),
      do: Monty.ModuleMap.Data.entries() |> carry_decisions(),
      else: %{}
  end

  @doc """
  The decisions a previous map made, keyed by entry.

  Only what a person or an earlier run *decided* is carried: an entry that is
  excluded, why, and which classes are excluded and why. Everything else is
  recomputed from the checkout, so a module that has since been written becomes
  `implemented` on its own.

  Carrying every class as excluded — which an earlier version of this task did
  — poisons the map: one regeneration marks all of a file's classes excluded,
  and the next run treats that as a decision and keeps it.
  """
  def carry_decisions(entries) do
    Map.new(entries, fn entry ->
      package = Map.get(entry, :package, "monty")

      {{package, entry.python},
       %{
         status: entry.status,
         reason: entry[:reason],
         excluded_classes: excluded_class_decisions(entry)
       }}
    end)
  end

  # The name *and* the reason: a class excluded without one is not a decision
  # here, `verify` rejects it.
  defp excluded_class_decisions(entry) do
    for %{status: :excluded, python: class} = excluded <- entry.classes,
        into: %{},
        do: {class, Map.get(excluded, :reason)}
  end

  defp render(entries) do
    """
    defmodule Monty.ModuleMap.Data do
      @moduledoc \"\"\"
      The module map itself: one entry per Python file, generated from the checkouts.

      Generated by `mix monty.module_map.gen`; do not edit by hand, except to mark a
      module `:excluded` with a reason, or to exclude a class and say why.

      It is a literal here rather than a file read at run time: the map is data, and
      the code that mirrors Monty should not be a reader of files it is told about.
      \"\"\"

      @entries #{inspect(entries, pretty: true, limit: :infinity, printable_limit: :infinity)}

      @doc "Every entry, in the order the generator wrote them."
      @spec entries() :: [map()]
      def entries, do: @entries
    end
    """
  end
end
