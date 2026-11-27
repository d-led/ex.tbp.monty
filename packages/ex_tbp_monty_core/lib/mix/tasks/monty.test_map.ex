defmodule Mix.Tasks.Monty.TestMap do
  @shortdoc "Which of Monty's unit cases this port's tests translate"

  @moduledoc """
  The test half of the rewrite map: every Monty unit case, and where — if
  anywhere — a port test names it.

      mix monty.test_map                  # the per-file table
      mix monty.test_map --missing        # every untranslated case, by name
      mix monty.test_map --write docs/test-map.md
      mix monty.test_map --check          # names a port test uses that Monty lacks
      mix monty.test_map --refresh        # rewrite the committed case table

  `--source` points at a Monty checkout (default `../monty-orig`), and
  `--port-root` at this repository (default the working directory).

  A case is *named* when it appears on a `# test_...` comment or in a test's
  title. Naming is the record of a translation, not proof of one: the test says
  whether it asserts the same behaviour.

  `--check` is the gate: every name a port test attributes has to exist in
  Monty's suite, so a typo or a renamed case is caught rather than counted.
  """

  use Mix.Task

  alias Monty.ModuleMap.TestMap

  @switches [
    source: :string,
    port_root: :string,
    missing: :boolean,
    write: :string,
    check: :boolean,
    refresh: :boolean
  ]

  @impl true
  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: @switches)

    port_root = Keyword.get(options, :port_root, File.cwd!())
    checkout = Keyword.get(options, :source, Path.join(port_root, "../monty-orig"))

    # `nil` is "no checkout beside this repository": the committed case table is
    # the record then, which is what `--check` reads on a runner that has no Monty
    # to look at. Writing that table (`--refresh`) is the one thing that needs a
    # real checkout, and it says so.
    source = if File.dir?(Path.join(checkout, "tests/unit")), do: checkout

    monty = TestMap.monty_cases(source)

    if monty == %{} do
      Mix.raise(
        "#{Path.join(checkout, "tests/unit")} is not there and no case table is committed: " <>
          "point --source at a Monty checkout, or write the table with --refresh where one is"
      )
    end

    attributions = TestMap.attributions(port_root)

    # A case of a module this port excludes is excluded with that module's
    # reason: the case asks about a module that is not here.
    by_module = TestMap.excluded_by_module(monty, Monty.ModuleMap.load())

    excluded =
      TestMap.excluded_cases(port_root) |> MapSet.union(MapSet.new(Map.keys(by_module)))

    coverage = TestMap.coverage(monty, attributions, excluded)

    cond do
      Keyword.get(options, :refresh, false) -> refresh(port_root, checkout)
      Keyword.get(options, :check, false) -> check(port_root, coverage, source)
      path = Keyword.get(options, :write) -> write(port_root, path, monty, coverage, by_module)
      Keyword.get(options, :missing, false) -> missing(coverage)
      true -> table(monty, coverage)
    end
  end

  defp table(monty, coverage) do
    Mix.shell().info(
      "#{coverage.named} of #{coverage.total} unit cases named in this port's tests, " <>
        "#{coverage.excluded} excluded with a reason, #{outstanding(coverage)} to translate"
    )

    for {file, names} <- Enum.sort(monty) do
      Mix.shell().info("  #{named(file, names, coverage)}/#{length(names)}  #{file}")
    end
  end

  defp missing(coverage) do
    for {file, names} <- Enum.sort(coverage.missing) do
      Mix.shell().info("  #{file}")

      Enum.each(names, &Mix.shell().info("        #{&1}"))
    end
  end

  defp check(port_root, coverage, source) do
    # The gate reads every test Monty has (an integration case is a case this
    # port may translate) and only the names a port test *leads* with, so a
    # comment that mentions `test_helper.exs` is not a claim about a case.
    # `source` is `nil` where the committed table is the record.
    all = TestMap.all_cases(source)
    led = TestMap.led_cases(port_root)
    unknown = TestMap.unknown_cases(all, led)

    for problem <- unknown do
      Mix.shell().error("#{problem.port}: #{problem.case} is not a case in Monty's suite")
    end

    misplaced = TestMap.exclusion_problems(all, led, TestMap.exclusions(port_root))

    for problem <- misplaced do
      Mix.shell().error(
        "#{problem.port}: #{problem.case} #{exclusion_complaint(problem.problem)}"
      )
    end

    if unknown == [] and misplaced == [] do
      Mix.shell().info(
        "test map: #{coverage.named} of #{coverage.total} cases named, " <>
          "#{coverage.excluded} excluded with a reason, #{outstanding(coverage)} to translate, " <>
          "and every name is one Monty defines"
      )
    else
      Mix.raise(
        "#{length(unknown)} attributed name(s) Monty does not define, " <>
          "#{length(misplaced)} exclusion(s) that do not stand"
      )
    end
  end

  defp exclusion_complaint(:unknown), do: "is not a case in Monty's suite"

  defp exclusion_complaint(:also_named), do: "is excluded and also named as translated"

  defp outstanding(coverage), do: coverage.total - coverage.named - coverage.excluded

  defp write(port_root, path, monty, coverage, by_module) do
    full = Path.expand(path, port_root)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, page(monty, coverage, TestMap.exclusions(port_root), by_module))
    Mix.shell().info("#{path}: written")
  end

  # The page a person reads: Monty's files down the side, and for each the
  # number of its cases a port test names, then the cases that cannot exist here
  # with the reason each one cannot — the ones a port test recorded, and the ones
  # a module the port excludes accounts for.
  defp page(monty, coverage, exclusions, by_module) do
    rows =
      for {file, names} <- Enum.sort(monty) do
        "| #{named(file, names, coverage)}/#{length(names)} | #{excluded_count(names, exclusions)} | `#{file}` |"
      end

    """
    # The test map

    Generated by `mix monty.test_map --write docs/test-map.md`; do not edit it by
    hand, and never quote its numbers anywhere else — run the command for them.

    A case is **named** when a port test carries its name on a `# test_...`
    comment or in its title. Naming is the record of a translation, not proof of
    one: the test itself says whether it asserts the same behaviour.

    #{accounted_for(coverage)}

    ## By Monty's file

    | named/total | excluded | Monty file |
    |---:|---:|---|
    #{Enum.join(rows, "\n")}
    #{excluded_section(exclusions)}

    #{module_excluded_section(by_module)}
    """
  end

  # A finished ledger says so in one sentence; an unfinished one also names the
  # work left, because that number is the list to translate.
  defp accounted_for(%{named: named, excluded: excluded, total: total})
       when named + excluded == total do
    "Every one of Monty's #{total} unit cases is accounted for: #{named} are named\n" <>
      "here, and #{excluded} more the port cannot have are excluded, each with its\n" <>
      "reason below."
  end

  defp accounted_for(coverage) do
    "#{coverage.named} of #{coverage.total} of Monty's unit cases are named here,\n" <>
      "#{coverage.excluded} more the port cannot have are excluded, each with its\n" <>
      "reason below, and #{coverage.total - coverage.named - coverage.excluded} are\n" <>
      "still to translate."
  end

  # The exclusions a module map entry already made, grouped by its reason: a case
  # asks about the module beside it, so an excluded module excludes its cases.
  defp module_excluded_section(by_module) when by_module == %{}, do: ""

  defp module_excluded_section(by_module) do
    groups =
      by_module
      |> Enum.group_by(fn {_name, reason} -> reason end, fn {name, _reason} -> name end)
      |> Enum.sort_by(fn {_reason, names} -> length(names) end, :desc)
      |> Enum.map_join("\n", fn {reason, names} ->
        cases = names |> Enum.sort() |> Enum.map_join(", ", &"`#{&1}`")
        "- **#{reason}** — #{cases}"
      end)

    "## Cases of modules the port excludes\n\n#{groups}"
  end

  defp excluded_count(names, exclusions) do
    all = exclusions |> Map.values() |> List.flatten() |> MapSet.new(& &1.case)
    Enum.count(names, &MapSet.member?(all, &1))
  end

  # Every excluded case, with why, grouped by the reason so that one mechanism
  # reads as one entry.
  defp excluded_section(exclusions) do
    entries =
      for {port_file, list} <- Enum.sort(exclusions), entry <- list do
        {entry.reason, port_file, entry.case}
      end

    if entries == [] do
      ""
    else
      groups =
        entries
        |> Enum.group_by(&elem(&1, 0))
        |> Enum.sort_by(fn {_reason, list} -> length(list) end, :desc)
        |> Enum.map_join("\n", fn {reason, list} ->
          cases =
            list
            |> Enum.map(fn {_r, _port, name} -> "`#{name}`" end)
            |> Enum.sort()
            |> Enum.join(", ")

          "- **#{reason}** — #{cases}"
        end)

      "## Cases the port cannot have\n\n#{groups}"
    end
  end

  # Writes the snapshot the gate reads when there is no checkout beside this
  # repository. Deliberate, and diffed like any other file. It needs a real
  # checkout — there is nothing to write down otherwise.
  defp refresh(port_root, checkout) do
    if not File.dir?(Path.join(checkout, "tests/unit")) do
      Mix.raise(
        "--refresh reads the cases from a Monty checkout, and " <>
          "#{Path.join(checkout, "tests/unit")} is not there: point --source at one"
      )
    end

    path = Path.join(port_root, TestMap.snapshot())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, TestMap.data_source(checkout))
    Mix.shell().info("#{TestMap.snapshot()}: written")
  end

  defp named(file, names, coverage) do
    name_set = MapSet.new(names)
    missing = length(Map.get(coverage.missing, file, []))
    excluded = MapSet.intersection(coverage.excluded_cases, name_set) |> MapSet.size()
    length(names) - missing - excluded
  end
end
