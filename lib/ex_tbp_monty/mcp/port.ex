defmodule ExTbpMonty.Mcp.Port do
  @moduledoc """
  Where a piece of Monty's Python lives here — or does not, yet.

  `Monty.ModuleMap` is the contract that keeps this rewrite module for module;
  this module is the same contract asked a question. Given a class Monty's configs
  name, the file a doc page links to, or an Elixir module someone is looking at,
  it answers with the pair and the verdict: implemented, planned, or excluded
  with the reason.

  The answer is the map's, not this module's. Nothing is guessed: a class the
  generated map does not list comes back `:unknown`, because a missing class
  means the generator did not see it, and inventing a target for it would make
  "is this ported?" answer yes for code nobody wrote.
  """

  alias Monty.ModuleMap

  @file_reference ~r/src\/tbp\/(?:monty|teleop)\/[A-Za-z0-9_\/]+\.py/
  @target_reference ~r/tbp\.(?:monty|teleop)\.[A-Za-z0-9_.]+/

  @doc """
  The place a target has here.

  Accepts the three ways the same module gets named: a Python dotted path as a
  Hydra config writes it (`tbp.monty.frameworks.models.sensor_modules.CameraSM`),
  a path in the checkout (`src/tbp/monty/frameworks/models/sensor_modules.py`),
  or the Elixir module it becomes (`Monty.Frameworks.Models.SensorModules.CameraSM`).
  """
  @spec lookup(String.t()) :: {:ok, map()} | {:error, String.t()}
  def lookup(target) when is_binary(target) do
    target = String.trim(target)

    cond do
      String.starts_with?(target, "tbp.") ->
        from_target(target)

      String.ends_with?(target, ".py") ->
        from_file(target)

      String.starts_with?(target, ["Monty.", "Teleop."]) ->
        from_elixir(target)

      true ->
        {:error,
         "`#{target}` is not a Monty target. Give a Python class " <>
           "(`tbp.monty.frameworks.models.sensor_modules.CameraSM`), a file " <>
           "(`src/tbp/monty/...py`) or an Elixir module (`Monty.…`)."}
    end
  end

  def lookup(_target), do: {:error, "The target must be a string."}

  @doc """
  How much of Monty is ported, and which files are not.

  The counts are `Monty.ModuleMap.summary/1`'s, so the studio's ported ratios
  and this answer are the same arithmetic.
  """
  @spec status() :: map()
  def status do
    entries = ModuleMap.load()

    %{
      summary: ModuleMap.summary(entries),
      planned: for(entry <- entries, entry.status == :planned, do: brief(entry)),
      excluded: for(entry <- entries, entry.status == :excluded, do: brief(entry))
    }
  end

  @doc """
  The modules a piece of text names, resolved.

  Monty's docs point at source constantly — "see
  `frameworks/models/evidence_matching/learning_module.py`" — and that pointer is
  the shortest path from a paragraph of theory to the code that implements it.
  Both spellings are picked up: a path in the checkout and a dotted class.
  """
  @spec referenced(String.t()) :: [map()]
  def referenced(text) when is_binary(text) do
    references =
      Regex.scan(@file_reference, text, capture: :first)
      |> List.flatten()
      |> Enum.concat(Regex.scan(@target_reference, text, capture: :first) |> List.flatten())

    references
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.uniq()
    |> Enum.flat_map(fn reference ->
      case lookup(reference) do
        {:ok, entry} -> [Map.put(entry, :reference, reference)]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq_by(&{&1.python, &1.elixir})
    |> Enum.sort_by(&{&1.elixir, &1.python})
  end

  def referenced(_text), do: []

  # -- the three ways in -----------------------------------------------------

  defp from_target(target) do
    case ModuleMap.resolve(target) do
      {:ok, entry} -> {:ok, describe(entry)}
      :error -> {:error, "The module map does not list `#{target}`."}
    end
  end

  defp from_file(path) do
    with {:ok, package, relative} <- split_path(path) do
      entries = ModuleMap.load()

      case Enum.find(entries, &(&1.package == package and &1.python == relative)) do
        nil -> {:error, "The module map does not list `#{package}:#{relative}`."}
        entry -> {:ok, describe(entry)}
      end
    end
  end

  defp split_path(path) do
    case Regex.run(~r/tbp\/(monty|teleop)\/(.+\.py)\z/, path) do
      [_whole, package, relative] -> {:ok, package, relative}
      nil -> {:error, "`#{path}` is not a file in a Monty checkout."}
    end
  end

  defp from_elixir(module) do
    entries = ModuleMap.load()

    case Enum.find(entries, &(&1.elixir == module)) do
      nil -> from_class_module(entries, module)
      entry -> {:ok, describe(entry)}
    end
  end

  defp from_class_module(entries, module) do
    found =
      Enum.find_value(entries, fn entry ->
        case Enum.find(entry.classes, &(&1.elixir == module)) do
          nil -> nil
          class -> {entry, class}
        end
      end)

    case found do
      nil ->
        {:error, "`#{module}` is not in the module map — it may be this application's own code."}

      {entry, class} ->
        {:ok,
         describe(%{
           package: entry.package,
           python: entry.python,
           elixir: class.elixir,
           status: class.status,
           class: class.python,
           classes: entry.classes
         })}
    end
  end

  # -- shapes ----------------------------------------------------------------

  defp describe(entry) do
    %{
      package: entry.package,
      python: entry.python,
      elixir: entry[:elixir],
      class: entry[:class],
      status: entry.status,
      reason: entry[:reason],
      classes: Enum.map(entry[:classes] || [], &brief_class/1)
    }
  end

  defp brief_class(class) do
    %{python: class.python, elixir: class.elixir, status: class.status}
  end

  defp brief(entry) do
    %{package: entry.package, python: entry.python, elixir: entry.elixir, reason: entry[:reason]}
  end
end
