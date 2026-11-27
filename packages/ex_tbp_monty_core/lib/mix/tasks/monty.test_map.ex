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
    source = Keyword.get(options, :source, Path.join(port_root, "../monty-orig"))

    monty = TestMap.monty_cases(source)

    if monty == %{} do
      Mix.raise(
        "#{Path.join(source, "tests/unit")} is not there: point --source at a Monty checkout"
      )
    end

    attributions = TestMap.attributions(port_root)
    coverage = TestMap.coverage(monty, attributions, TestMap.excluded_cases(port_root))

    cond do
      Keyword.get(options, :refresh, false) -> refresh(port_root, source)
      Keyword.get(options, :check, false) -> check(port_root, coverage)
      path = Keyword.get(options, :write) -> write(port_root, path, monty, coverage)
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

  defp check(port_root, coverage) do
    # The gate reads every test Monty has (an integration case is a case this
    # port may translate) and only the names a port test *leads* with, so a
    # comment that mentions `test_helper.exs` is not a claim about a case.
    all = TestMap.all_cases(source(port_root))
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

  defp write(port_root, path, monty, coverage) do
    full = Path.expand(path, port_root)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, page(monty, coverage, TestMap.exclusions(port_root)))
    Mix.shell().info("#{path}: written")
  end

  # The page a person reads: Monty's files down the side, and for each the
  # number of its cases a port test names, then the cases that cannot exist here
  # with the reason each one cannot.
  defp page(monty, coverage, exclusions) do
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

    #{coverage.named} of #{coverage.total} of Monty's unit cases are named here, and
    #{coverage.excluded} more the port cannot have are excluded, each with its reason
    below.

    ## By Monty's file

    | named/total | excluded | Monty file |
    |---:|---:|---|
    #{Enum.join(rows, "\n")}
    #{excluded_section(exclusions)}
    """
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

  defp source(port_root), do: Path.join(port_root, "../monty-orig")

  # Writes the snapshot the gate reads when there is no checkout beside this
  # repository. Deliberate, and diffed like any other file.
  defp refresh(port_root, source) do
    path = Path.join(port_root, TestMap.snapshot())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, TestMap.data_source(source))
    Mix.shell().info("#{TestMap.snapshot()}: written")
  end

  defp named(file, names, coverage),
    do: length(names) - length(Map.get(coverage.missing, file, []))
end
