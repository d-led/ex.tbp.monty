defmodule Monty.ModuleMap do
  @moduledoc """
  The contract that keeps this rewrite *module for module*.

  Monty's team should be able to take a Python file, apply one rule, and find
  the Elixir module that holds it. This module owns that rule and the map
  generated from it (`priv/monty/module_map.exs`), and verifies that neither
  has drifted from the checkout.

  The rule: `Monty.<CamelCase dirs>.<CamelCase file>.<Class>`, with a repeated
  segment collapsed and the class dropped when it repeats the file name.

      frameworks/models/evidence_matching/learning_module.py::EvidenceGraphLM
        -> Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM

      actions/actions.py::MoveForward
        -> Monty.Frameworks.Actions.MoveForward

      cmp.py::Message
        -> Monty.Cmp.Message

  A module that exists here is `implemented`; one that does not is `planned`;
  one that will never exist (Hydra's own tooling) is `excluded` with a reason.
  """

  alias Monty.Config.Source

  @map_path "priv/monty/module_map.exs"

  @type entry :: %{
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

  @doc "The generated map."
  @spec load(Path.t()) :: [entry()]
  def load(path \\ @map_path) do
    # Generated in-repo by `mix monty.module_map.gen`: data, not something
    # fetched at runtime. Reviewed in .sobelow-skips.
    {entries, _binding} = Code.eval_file(path)
    entries
  end

  @doc "The Elixir module a Python file maps to."
  @spec module_for(String.t()) :: String.t()
  def module_for(relative_python_path) do
    segments =
      relative_python_path
      |> String.trim_trailing(".py")
      |> String.split("/", trim: true)
      |> Enum.map(&camelize/1)
      |> collapse_repeats()

    Module.concat(["Monty" | segments]) |> inspect()
  end

  @doc "The Elixir module a class maps to, given its file's module."
  @spec class_module(String.t(), String.t(), String.t()) :: String.t()
  def class_module(file_module, class, relative_python_path) do
    file_base = relative_python_path |> Path.basename(".py") |> camelize()

    if class == file_base, do: file_module, else: file_module <> "." <> class
  end

  @doc "Python files in a checkout that the map must cover."
  @spec python_files(Path.t()) :: [String.t()]
  def python_files(root \\ Source.root()) do
    package = Path.join([root, "src", "tbp", "monty"])

    package
    |> Path.join("**/*.py")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "__init__.py"))
    |> Enum.map(&Path.relative_to(&1, package))
    |> Enum.sort()
  end

  @doc """
  Checks the map against the checkout and against the compiled code.

  Returns a summary on success and the list of problems otherwise — the mix
  task prints them, the test asserts them empty.
  """
  @spec verify(keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def verify(opts \\ []) do
    entries = load(Keyword.get(opts, :map, @map_path))
    root = Keyword.get_lazy(opts, :source, fn -> Source.root() end)
    mapped = Map.new(entries, &{&1.python, &1})

    problems =
      unmapped_python_files(mapped, root) ++
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
      excluded: Map.get(counts, :excluded, 0)
    }
  end

  defp unmapped_python_files(mapped, root) do
    if File.dir?(Path.join([root, "src", "tbp", "monty"])) do
      for file <- python_files(root), not Map.has_key?(mapped, file) do
        "unmapped python file: #{file}"
      end
    else
      ["Monty checkout not found at #{root}"]
    end
  end

  defp missing_modules(entries) do
    for entry <- entries,
        entry.status == :implemented,
        not exists?(entry.elixir) do
      "implemented entry points at a module that does not exist: #{entry.elixir} (#{entry.python})"
    end
  end

  defp missing_reasons(entries) do
    for entry <- entries, entry.status == :excluded, entry[:reason] in [nil, ""] do
      "excluded entry has no reason: #{entry.python}"
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
