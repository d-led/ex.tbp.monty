defmodule Mix.Tasks.Monty.ModuleMap.Gen do
  @shortdoc "Regenerates the core package's module map from the Monty and teleop checkouts"

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
  alias Monty.ModuleMap.StandIns

  @map_path "packages/ex_tbp_monty_core/lib/monty/module_map/data.ex"

  @impl true
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          source: :string,
          teleop_source: :string,
          reset_decisions: :boolean,
          best_effort: :boolean
        ]
      )

    configure_sources(opts)

    decisions = if opts[:reset_decisions], do: %{}, else: read_existing()

    case entries(decisions, opts[:best_effort]) do
      :skip ->
        Mix.shell().info("#{@map_path}: left as it is — no checkout to regenerate it from")

      {entries, generated} ->
        entries = Enum.sort_by(entries, &{&1.package, &1.python})
        write(entries, sources(generated))

        summary = ModuleMap.summary(entries)

        Mix.shell().info(
          "#{@map_path}: #{summary.files} files, #{summary.classes} classes, " <>
            "#{summary.implemented} implemented, per package: #{inspect(summary.by_package)}"
        )
    end
  end

  # Every package that has a checkout is regenerated; one that does not keeps
  # the entries the committed map already holds. `--best-effort` — what `mix
  # test` passes — leaves the map alone entirely rather than failing over a
  # neighbour the suite does not need: CI has no checkout at all.
  #
  # `generated` is only the packages this run read: a kept package's entry is
  # the one the map already had, commit and all, and asking a checkout that is
  # not there for its commit would replace a fact with nil.
  defp entries(decisions, best_effort) do
    ModuleMap.packages()
    |> Enum.reduce_while({[], []}, fn package, {entries, generated} ->
      case entries_for(package, decisions, best_effort) do
        {:ok, entries_of_package, :generated} ->
          {:cont, {entries ++ entries_of_package, [package.name | generated]}}

        {:ok, entries_of_package, :kept} ->
          {:cont, {entries ++ entries_of_package, generated}}

        :skip ->
          {:halt, :skip}
      end
    end)
    |> case do
      :skip -> :skip
      {entries, generated} -> {entries, Enum.reverse(generated)}
    end
  end

  # A map that reads the same is not rewritten: the file's mtime is what makes
  # Mix recompile `Monty.ModuleMap.Data`, and `mix test` asks for this on every
  # run.
  defp write(entries, sources) do
    # `Code.format_string!/1` does not end a file with a newline; `mix format`
    # does, and a map the formatter would rewrite fails the lint gate.
    content = IO.iodata_to_binary([Code.format_string!(render(entries, sources)), "\n"])

    case File.read(@map_path) do
      {:ok, ^content} ->
        :ok

      _changed_or_absent ->
        File.mkdir_p!(Path.dirname(@map_path))
        # Written beside the map and renamed onto it: `mix test --partitions`
        # starts several processes that all ask for this, and a half-written map
        # is a compilation error for the next one.
        temporary = @map_path <> ".tmp"
        File.write!(temporary, content)
        File.rename!(temporary, @map_path)
    end
  end

  defp configure_sources(opts) do
    if source = opts[:source],
      do: Application.put_env(:ex_tbp_monty, :monty_source, Path.expand(source))

    if source = opts[:teleop_source],
      do: Application.put_env(:ex_tbp_monty, :teleop_source, Path.expand(source))
  end

  defp entries_for(package, existing, best_effort) do
    if File.dir?(Path.join(package.root.(), package.relative)) do
      {:ok, generated_entries(package, existing), :generated}
    else
      keep_previous(package, best_effort)
    end
  end

  # A machine without the checkout cannot regenerate that package. What the map
  # already holds is the best answer available here, so it is carried over
  # unchanged — and when there is nothing to carry, an explicit regeneration
  # says so instead of writing a map with a package missing.
  defp keep_previous(package, best_effort) do
    case previous_entries(package) do
      [] when best_effort ->
        :skip

      [] ->
        Mix.raise(
          "no checkout for #{package.name} at #{package.root.()}: regenerating " <>
            "would erase its entries. Pass --source, or --best-effort to leave the map alone"
        )

      entries ->
        Mix.shell().info(
          "module map: no checkout for #{package.name}; keeping the #{length(entries)} " <>
            "entries the map already holds"
        )

        {:ok, entries, :kept}
    end
  end

  defp previous_entries(package) do
    if Code.ensure_loaded?(Monty.ModuleMap.Data) do
      Monty.ModuleMap.Data.entries()
      |> Enum.filter(&(Map.get(&1, :package, "monty") == package.name))
    else
      []
    end
  end

  defp generated_entries(package, existing) do
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
    |> put_file()
    |> put_stand_ins(StandIns.for_class(class, relative))
  end

  # Where a written class lives, asked of the compiled module rather than
  # derived from its name: the port is not obliged to keep one module per file,
  # and `sensor_modules/camera_sm.ex` holds `CameraSM` beside a
  # `sensor_modules.ex` that never existed. The beam knows its own source, so
  # the map carries the answer and a page's link is data, not a guess.
  defp put_file(%{status: :implemented} = entry) do
    case source_file(entry.elixir) do
      nil -> entry
      file -> Map.put(entry, :file, file)
    end
  end

  defp put_file(entry), do: entry

  defp source_file(module) do
    name = Module.concat(String.split(module, "."))

    with true <- Code.ensure_loaded?(name),
         beam when is_list(beam) <- :code.which(name),
         {:ok, {_module, chunks}} <- :beam_lib.chunks(beam, [:compile_info]),
         source when is_list(source) <- chunks[:compile_info][:source] do
      Path.relative_to(List.to_string(source), File.cwd!())
    else
      _unknown -> nil
    end
  end

  # What runs instead, where anything does — the fact a reader of the map needs
  # to tell "not written yet" from "replaced on purpose". Written only where
  # there is one, so 358 empty lists do not bury the two answers.
  #
  # A class this build has is standing in for nothing: the note answers "what
  # runs if you do not have it", and a written class makes that question
  # meaningless. It also made the map look as if the class were still missing
  # after it was ported.
  defp put_stand_ins(%{status: :implemented} = entry, _stand_ins), do: entry

  defp put_stand_ins(entry, []), do: entry

  defp put_stand_ins(entry, stand_ins),
    do: Map.put(entry, :stand_in, Enum.map(stand_ins, &with_file/1))

  # A stand-in module's file, for the same reason a class's is recorded.
  defp with_file(%{kind: :module, name: module} = stand_in) do
    case source_file(inspect_module(module)) do
      nil -> stand_in
      file -> Map.put(stand_in, :file, file)
    end
  end

  defp with_file(stand_in), do: stand_in

  defp inspect_module(module) when is_atom(module), do: inspect(module)
  defp inspect_module(module), do: to_string(module)

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

  # What the map was generated from, per package. The checkouts move under us —
  # `git pull` in the Monty checkout once changed 297 files — so the map carries
  # the commit it describes: a regenerated map then *says* upstream moved, in the
  # diff, instead of leaving a stale map to be discovered by a failing test.
  defp sources(generated) do
    previous = previous_sources()

    Map.new(ModuleMap.packages(), fn package ->
      # A package with no checkout keeps the commit the map already names: the
      # map describes the code it was read from, and this run did not read it.
      if package.name in generated,
        do: {package.name, current_source(package)},
        else: {package.name, Map.get(previous, package.name) || current_source(package)}
    end)
  end

  defp current_source(package) do
    root = package.root.()

    %{
      "commit" => git(root, ~w(rev-parse HEAD)),
      "date" => git(root, ~w(show -s --format=%cI HEAD))
    }
  end

  defp previous_sources do
    if Code.ensure_loaded?(Monty.ModuleMap.Data), do: Monty.ModuleMap.Data.sources(), else: %{}
  end

  defp git(root, arguments) do
    case System.cmd("git", ["-C", root | arguments], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _no_git_or_not_a_checkout -> nil
    end
  end

  defp render(entries, sources) do
    """
    defmodule Monty.ModuleMap.Data do
      @moduledoc \"\"\"
      The module map itself: one entry per Python file, generated from the checkouts.

      Generated by `mix monty.module_map.gen`; do not edit by hand, except to mark a
      module `:excluded` with a reason, or to exclude a class and say why.

      It is a literal here rather than a file read at run time: the map is data, and
      the code that mirrors Monty should not be a reader of files it is told about.

      `sources/0` says which commit of each package these entries were read from.
      A map generated before a checkout moved is a map of the commits it names, not
      of the code beside it, and `mix monty.module_map.verify` says so.
      \"\"\"

      @sources #{inspect(sources, pretty: true, limit: :infinity)}

      @entries #{inspect(entries, pretty: true, limit: :infinity, printable_limit: :infinity)}

      @doc "The commit each package was at when this map was generated."
      @spec sources() :: %{optional(String.t()) => %{optional(String.t()) => String.t() | nil}}
      def sources, do: @sources

      @doc "Every entry, in the order the generator wrote them."
      @spec entries() :: [map()]
      def entries, do: @entries
    end
    """
  end
end
