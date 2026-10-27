defmodule Monty.ModuleMap do
  @moduledoc """
  The contract that keeps this rewrite *module for module*.

  One namespace per TBP package, and one rule inside each:

      tbp/monty/<path>/<file>.py::Class  ->  Monty.<Path>.<File>.<Class>
      tbp/teleop/<file>.py::Class        ->  Teleop.<File>.<Class>

  with a repeated segment collapsed and the class dropped when it repeats the
  file name. A Monty developer should be able to take a Python file, apply the
  rule, and find the Elixir module that holds it — for the runtime *and* for
  the teleop tooling this application replaces with LiveView.

  A module that exists here is `implemented`; one that does not is `planned`;
  one that will never exist (Hydra's own tooling) is `excluded` with a reason.
  """

  alias Monty.Config.Source

  @map_path "priv/monty/module_map.exs"

  @packages [
    %{
      name: "monty",
      namespace: "Monty",
      relative: "src/tbp/monty",
      root: &Source.root/0
    },
    %{
      name: "teleop",
      namespace: "Teleop",
      relative: "src/tbp/teleop",
      root: &Source.teleop_root/0
    }
  ]

  @type entry :: %{
          required(:package) => String.t(),
          required(:python) => String.t(),
          required(:elixir) => String.t(),
          required(:status) => :implemented | :planned | :excluded,
          optional(:reason) => String.t() | nil,
          required(:classes) => [
            %{
              required(:python) => String.t(),
              required(:elixir) => String.t(),
              required(:status) => atom()
            }
          ]
        }

  @doc "The Python packages this application mirrors."
  @spec packages() :: [map()]
  def packages, do: @packages

  @doc "One package by name."
  @spec package(String.t()) :: map() | nil
  def package(name), do: Enum.find(@packages, &(&1.name == name))

  @doc "The generated map."
  @spec load(Path.t()) :: [entry()]
  def load(path \\ @map_path) do
    # Generated in-repo by `mix monty.module_map.gen`: data, not something
    # fetched at runtime. Reviewed in .sobelow-skips.
    {entries, _binding} = Code.eval_file(path)
    entries
  end

  @doc "The Elixir module a Python file maps to, within a package namespace."
  @spec module_for(String.t(), String.t()) :: String.t()
  def module_for(namespace, relative_python_path) do
    segments =
      relative_python_path
      |> String.trim_trailing(".py")
      |> String.split("/", trim: true)
      |> Enum.map(&camelize/1)
      |> collapse_repeats()

    Module.concat([namespace | segments]) |> inspect()
  end

  @doc "The Elixir module a class maps to, given its file's module."
  @spec class_module(String.t(), String.t(), String.t()) :: String.t()
  def class_module(file_module, class, relative_python_path) do
    file_base = relative_python_path |> Path.basename(".py") |> camelize()

    if class == file_base, do: file_module, else: file_module <> "." <> class
  end

  @doc "Python files of a package, or `[]` when the checkout is absent."
  @spec python_files(map()) :: [String.t()]
  def python_files(package) do
    dir = Path.join(package.root.(), package.relative)

    if File.dir?(dir) do
      dir
      |> Path.join("**/*.py")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "__init__.py"))
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  Checks the map against every checkout and against the compiled code.

  Returns a summary on success and the list of problems otherwise — the mix
  task prints them, the test asserts them empty.
  """
  @spec verify(keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def verify(opts \\ []) do
    entries = load(Keyword.get(opts, :map, @map_path))
    packages = Keyword.get(opts, :packages, @packages)
    mapped = Map.new(entries, &{{&1.package, &1.python}, &1})

    problems =
      Enum.flat_map(packages, &coverage_problems(&1, mapped)) ++
        missing_modules(entries) ++
        missing_reasons(entries)

    case problems do
      [] -> {:ok, summary(entries)}
      problems -> {:error, problems}
    end
  end

  @doc "Counts by status."
  @spec summary([entry()]) :: map()
  def summary(entries) do
    counts = Enum.frequencies_by(entries, & &1.status)

    %{
      modules: length(entries),
      implemented: Map.get(counts, :implemented, 0),
      planned: Map.get(counts, :planned, 0),
      excluded: Map.get(counts, :excluded, 0),
      by_package: Enum.frequencies_by(entries, & &1.package)
    }
  end

  defp coverage_problems(package, mapped) do
    dir = Path.join(package.root.(), package.relative)

    if File.dir?(dir) do
      for file <- python_files(package),
          not Map.has_key?(mapped, {package.name, file}) do
        "unmapped #{package.name} file: #{file}"
      end
    else
      ["#{package.name} checkout not found at #{dir}"]
    end
  end

  defp missing_modules(entries) do
    for entry <- entries,
        entry.status == :implemented,
        not exists?(entry.elixir) do
      "implemented entry points at a module that does not exist: #{entry.elixir} (#{entry.package}:#{entry.python})"
    end
  end

  defp missing_reasons(entries) do
    for entry <- entries, entry.status == :excluded, entry[:reason] in [nil, ""] do
      "excluded entry has no reason: #{entry.package}:#{entry.python}"
    end
  end

  defp exists?(module) do
    module |> String.split(".") |> Module.concat() |> Code.ensure_loaded?()
  end

  defp collapse_repeats([a, a | rest]), do: collapse_repeats([a | rest])
  defp collapse_repeats([first | rest]), do: [first | collapse_repeats(rest)]
  defp collapse_repeats([]), do: []

  defp camelize(segment), do: segment |> String.split("_") |> Enum.map_join(&String.capitalize/1)
end
