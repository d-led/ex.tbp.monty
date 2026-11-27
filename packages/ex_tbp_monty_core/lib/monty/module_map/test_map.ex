defmodule Monty.ModuleMap.TestMap do
  @moduledoc """
  Which of Monty's unit cases this port's tests translate — the module map's
  other half.

  `Monty.ModuleMap` answers "where did this Python module go"; this answers "where
  did this test case go", and the answer is a many-to-many relation:

  - one Monty test file's cases may be translated in several port files (a
    module's cases split by behaviour, or one file's cases land beside the two
    modules they test);
  - one port file names cases from several Monty files.

  So the table is `%{monty_file => %{case_name => [port_file]}}`, and the reverse
  index — `%{port_file => [%{monty_file, case_name}]}` — is what a reader of a
  port test wants.

  ## What counts as an attribution

  A name is attributed when it appears on a comment line (`# test_foo`) or in a
  test's own title. Prose does not count: a list of the cases that could not be
  translated must not read as translations.

  What this does **not** claim: an attributed name is a translation that is
  faithful. It says the case was read and named; the test itself says whether it
  asserts the same behaviour.
  """

  @case_definition ~r/def (test_[A-Za-z0-9_]+)/
  @name ~r/\btest_[A-Za-z0-9_]+/

  @typedoc "Monty's cases by the file that defines them."
  @type cases :: %{optional(String.t()) => [String.t()]}

  @typedoc "The M×N relation: a Monty file, a case, and the port files naming it."
  @type mapping :: %{optional(String.t()) => %{optional(String.t()) => [String.t()]}}

  @doc """
  Every unit case in a Monty checkout, by file, relative to `tests/unit`.

  Monty names a test module `<thing>_test.py`; older releases used
  `test_<thing>.py`, so both are read.
  """
  @spec monty_cases(Path.t() | nil) :: cases()
  def monty_cases(nil), do: Monty.ModuleMap.TestMap.Data.unit_cases()
  def monty_cases(monty_root), do: cases_under(monty_root, "tests/unit")

  @doc """
  Every case Monty defines anywhere under `tests/`, the unit suite and the
  integration one.

  The coverage above is the unit suite — that is what a port translates — but a
  port may translate an integration case, and the gate that asks "is this a case
  Monty has" has to know about both.
  """
  @spec all_cases(Path.t() | nil) :: cases()
  def all_cases(nil), do: Monty.ModuleMap.TestMap.Data.all_cases()
  def all_cases(monty_root), do: cases_under(monty_root, "tests")

  defp cases_under(monty_root, directory) do
    root = Path.join(monty_root, directory)

    if File.dir?(root) do
      root
      |> Path.join("**/*.py")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "__pycache__"))
      |> Enum.filter(&test_module?/1)
      |> Map.new(fn path ->
        {Path.relative_to(path, root), names_in(path, @case_definition)}
      end)
      |> Enum.reject(fn {_file, names} -> names == [] end)
      |> Map.new()
    else
      %{}
    end
  end

  @doc """
  Every case a port test file attributes, by file.

  An attribution is a **line** that is a comment, or one that declares a test —
  and the case names on it. Lines rather than the whole file, because a name in
  prose is not a translation: a moduledoc that lists the cases which could not
  be translated would otherwise count them, and the count would flatter the port
  by exactly the cases it is honest about. A line may name more than one case.
  """
  @spec attributions(Path.t()) :: cases()
  def attributions(port_root) do
    port_root
    |> Path.join("test/**/*.exs")
    |> Path.wildcard()
    |> Map.new(fn path -> {Path.relative_to(path, port_root), attributed_in(path)} end)
    |> Enum.reject(fn {_file, names} -> names == [] end)
    |> Map.new()
  end

  @doc """
  The M×N relation, in both directions.

  `:monty` maps a Monty file to its cases and, for each, the port files that
  name it; `:port` maps a port file to the Monty cases it names, each with the
  Monty file it came from.
  """
  @spec mapping(Path.t(), Path.t()) :: %{monty: mapping(), port: mapping()}
  def mapping(port_root, monty_root) do
    monty = monty_cases(monty_root)
    port = attributions(port_root)

    monty =
      Map.new(monty, fn {monty_file, names} ->
        cases =
          Map.new(names, fn name ->
            {name,
             port
             |> Enum.filter(fn {_file, attributed} -> name in attributed end)
             |> Enum.map(&elem(&1, 0))
             |> Enum.sort()}
          end)

        {monty_file, cases}
      end)

    port =
      Map.new(port, fn {port_file, names} ->
        cases =
          for name <- names,
              {monty_file, monty_cases} <- monty,
              name in Map.keys(monty_cases),
              do: %{monty_file: monty_file, case: name}

        {port_file, Enum.uniq(cases)}
      end)

    %{monty: monty, port: port}
  end

  @doc """
  How many of a Monty case table's names are attributed, and which are not.
  """
  @spec coverage(cases(), cases()) :: %{
          named: non_neg_integer(),
          total: non_neg_integer(),
          missing: cases()
        }
  def coverage(monty_cases, attributions) do
    attributed = attributions |> Map.values() |> List.flatten() |> MapSet.new()

    missing =
      Map.new(monty_cases, fn {file, names} ->
        {file, Enum.reject(names, &MapSet.member?(attributed, &1))}
      end)
      |> Enum.reject(fn {_file, names} -> names == [] end)
      |> Map.new()

    total = monty_cases |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    absent = missing |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    %{named: total - absent, total: total, missing: missing}
  end

  @doc """
  The problems a mapping can have: a case named here that Monty does not
  define.

  A name that Monty's suite does not contain is a defect of the port's record —
  a typo, or a case that was renamed upstream — and it is what a gate can check
  without a judgement about faithfulness.
  """
  @spec unknown_cases(cases(), cases()) :: [%{port: String.t(), case: String.t()}]
  def unknown_cases(monty_cases, attributions) do
    known = monty_cases |> Map.values() |> List.flatten() |> MapSet.new()

    for {port_file, names} <- attributions,
        name <- names,
        not MapSet.member?(known, name),
        do: %{port: port_file, case: name}
  end

  @doc """
  The names a port test *leads* with: a comment that opens `# test_...`, or a
  test's own title.

  This is the stricter reading of an attribution, and the one the gate uses. A
  comment that mentions a Monty file — `tests/unit/resources/test_custom_objects`
  — or a helper (`test_helper.exs`) contains a name that is not a case, and it
  is not a claim about a translation either. Coverage still counts every name on
  a comment line, because a line may name its case after a word.
  """
  @spec led_cases(Path.t()) :: cases()
  def led_cases(port_root) do
    port_root
    |> Path.join("test/**/*.exs")
    |> Path.wildcard()
    |> Map.new(fn path -> {Path.relative_to(path, port_root), led_in(path)} end)
    |> Enum.reject(fn {_file, names} -> names == [] end)
    |> Map.new()
  end

  defp led_in(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      trimmed = String.trim(line)

      cond do
        Regex.match?(~r/^#\s*test_/, trimmed) ->
          names_in_line(trimmed)

        String.contains?(line, ~s(test ")) or String.contains?(line, "test '") ->
          names_in_line(line)

        true ->
          []
      end
    end)
    |> Enum.uniq()
  end

  @snapshot "packages/ex_tbp_monty_core/lib/monty/module_map/test_map/data.ex"

  @doc "Where the committed snapshot of Monty's case tables lives."
  @spec snapshot() :: Path.t()
  def snapshot, do: @snapshot

  @doc """
  The source of that snapshot, from a Monty checkout.

  The snapshot is what lets the gate run without a checkout beside the
  repository — in CI, and on a machine that has only this tree — so it is
  regenerated deliberately (`mix monty.test_map --refresh`) and diffed like any
  other file.
  """
  @spec data_source(Path.t()) :: String.t()
  def data_source(monty_root) do
    [
      "defmodule Monty.ModuleMap.TestMap.Data do",
      "  @moduledoc \"\"\"",
      "  Monty's cases, by file — a snapshot of the checkout at the time",
      "  `mix monty.test_map --refresh` last ran.",
      "",
      "  Generated; do not edit. It is the test half of the rewrite map in the",
      "  form that needs no Monty checkout beside this repository: the gate",
      "  reads it when `--source` is not there.",
      "  \"\"\"",
      "",
      "  @unit " <> literal(monty_cases(monty_root)),
      "",
      "  @all " <> literal(all_cases(monty_root)),
      "",
      "  @doc \"Every case under `tests/unit`, by file relative to it.\"",
      "  def unit_cases, do: @unit",
      "",
      "  @doc \"Every case under `tests/`, by file relative to it.\"",
      "  def all_cases, do: @all",
      "end",
      ""
    ]
    |> Enum.join("\n")
  end

  # A map as Elixir source a person can read: one file a line.
  defp literal(map) do
    body =
      map
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {file, names} ->
        "    #{inspect(file)} => #{inspect(Enum.sort(names), limit: :infinity)}"
      end)

    "%{\n" <> body <> "\n  }"
  end

  defp test_module?(path) do
    name = Path.basename(path)
    String.ends_with?(name, "_test.py") or String.starts_with?(name, "test_")
  end

  defp names_in(path, regex) do
    path
    |> File.read!()
    |> then(&Regex.scan(regex, &1, capture: :all_but_first))
    |> List.flatten()
  end

  # A comment line, or a line that declares a test: the two places a translation
  # records which case it is.
  defp attributed_in(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "#") or String.contains?(line, ~s(test ")) or
        String.contains?(line, "test '")
    end)
    |> Enum.flat_map(&names_in_line/1)
    |> Enum.uniq()
  end

  defp names_in_line(line), do: Regex.scan(@name, line) |> List.flatten()
end
