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
              required(:status) => atom(),
              optional(:reason) => String.t() | nil
            }
          ]
        }

  @doc "The Python packages this application mirrors."
  @spec packages() :: [map()]
  def packages, do: @packages

  @doc "One package by name."
  @spec package(String.t()) :: map() | nil
  def package(name), do: Enum.find(@packages, &(&1.name == name))

  @doc """
  The generated map.

  It is compiled in by `mix monty.module_map.gen`, not read from a file: the map
  is data, and a file read at run time is a path whose contents decide what this
  application does next.
  """
  @spec load() :: [entry()]
  def load, do: Monty.ModuleMap.Data.entries()

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
    entries = Keyword.get_lazy(opts, :entries, &load/0)
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

  @doc """
  The commit each package was at when the map was generated.

  The map describes a checkout at a moment, and checkouts move: the map carries
  that moment so a regenerated map shows it in the diff, and so a stale map can
  be recognised rather than trusted.
  """
  @spec sources() :: %{optional(String.t()) => map()}
  def sources, do: Monty.ModuleMap.Data.sources()

  @doc """
  Packages whose checkout has moved away from the commit the map names.

  Answers `{package, recorded_commit, current_commit}`, empty when the map is
  current or when a checkout cannot be asked — a package unpacked from an archive
  has no commit, and that is not a drift.
  """
  @spec moved() :: [{String.t(), String.t() | nil, String.t()}]
  def moved do
    for {name, %{"commit" => recorded}} <- sources(),
        package = package(name),
        current = commit(package.root.()),
        current != nil,
        current != recorded,
        do: {name, recorded, current}
  end

  defp commit(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _no_git_or_not_a_checkout -> nil
    end
  end

  @doc """
  Counts by status, of the classes and of the files that hold them.

  The count that answers "how much of Monty is ported" is the classes': a file is
  ported when the classes a config can name in it are, and most of Monty's files
  hold several. `files` is there too, because a file is what a reader opens, and
  the two numbers are different questions rather than two spellings of one.
  """
  @spec summary([entry()]) :: map()
  def summary(entries) do
    classes = Enum.flat_map(entries, & &1.classes)
    counts = Enum.frequencies_by(classes, & &1.status)

    %{
      files: length(entries),
      classes: length(classes),
      implemented: Map.get(counts, :implemented, 0),
      planned: Map.get(counts, :planned, 0),
      excluded: Map.get(counts, :excluded, 0),
      by_package: classes_by_package(entries)
    }
  end

  defp classes_by_package(entries) do
    Enum.reduce(entries, %{}, fn entry, counts ->
      Map.update(counts, entry.package, length(entry.classes), &(&1 + length(entry.classes)))
    end)
  end

  @doc """
  Resolves a Python dotted class path to its entry in the map.

  Monty's configs name classes the way Python imports them
  (`tbp.monty.frameworks.models.sensor_modules.CameraSM`), so this is how a
  composed config is read back as "which modules does this experiment use, and
  are they ported?".

  A class the map does not list is reported as `:unknown` rather than guessed
  at: the map is generated from the Python source, so a missing class means the
  target names something the generator did not see.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, map()} | :error
  def resolve(dotted, opts \\ []) do
    entries = Keyword.get_lazy(opts, :entries, &load/0)

    with {:ok, package, file, class} <- split_target(dotted) do
      case find_entry(entries, package, file) do
        {:ok, entry} -> {:ok, describe_target(entry, class)}
        :error -> resolve_exported(entries, package, class)
      end
    end
  end

  # A config may name a class where Python *exports* it rather than where it is
  # defined. `MuJoCoSimulator` is defined in `simulators/mujoco/simulator.py` and
  # re-exported by the package's `__init__.py`, and Monty's own env configs name
  # it `tbp.monty.simulators.mujoco.MuJoCoSimulator` — a path with no file behind
  # it. So a path that is not a file is asked again by class name, and answered
  # only when exactly one entry in that package defines the class: two classes
  # sharing a name is a reason to say "unknown", not to pick one.
  defp resolve_exported(entries, package, class) do
    entries
    |> Enum.filter(&(&1.package == package and has_class?(&1, class)))
    |> case do
      [entry] -> {:ok, describe_target(entry, class)}
      _none_or_several -> :error
    end
  end

  defp has_class?(entry, class), do: Enum.any?(entry.classes, &(&1.python == class))

  @doc "Whether a target resolves to a module that exists here."
  @spec implemented?(String.t(), keyword()) :: boolean()
  def implemented?(dotted, opts \\ []) do
    case resolve(dotted, opts) do
      {:ok, %{status: :implemented}} -> true
      _planned_or_unknown -> false
    end
  end

  defp split_target(dotted) do
    case String.split(dotted, ".", trim: true) do
      ["tbp", package | rest] when rest != [] ->
        {class, path} = List.pop_at(rest, -1)
        {:ok, package, Enum.join(path, "/") <> ".py", class}

      _not_a_target ->
        :error
    end
  end

  defp find_entry(entries, package, file) do
    case Enum.find(entries, &(&1.package == package and &1.python == file)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp describe_target(entry, class) do
    case Enum.find(entry.classes, &(&1.python == class)) do
      nil ->
        %{
          package: entry.package,
          python: entry.python,
          class: class,
          elixir: entry.elixir,
          status: :unknown
        }

      class_entry ->
        %{
          package: entry.package,
          python: entry.python,
          class: class,
          elixir: class_entry.elixir,
          status: class_entry.status
        }
    end
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
    entry_problems =
      for entry <- entries, entry.status == :excluded, unexplained?(entry) do
        "excluded entry has no reason: #{entry.package}:#{entry.python}"
      end

    # A file-level exclusion covers its classes. Only a class excluded inside a
    # file this port does write has to say why on its own.
    class_problems =
      for entry <- entries,
          entry.status != :excluded,
          class <- entry.classes,
          class.status == :excluded,
          unexplained?(class) do
        "excluded class has no reason: #{entry.package}:#{entry.python}::#{class.python}"
      end

    entry_problems ++ class_problems
  end

  defp unexplained?(map), do: Map.get(map, :reason) in [nil, ""]

  defp exists?(module) do
    module |> String.split(".") |> Module.concat() |> Code.ensure_loaded?()
  end

  defp collapse_repeats([a, a | rest]), do: collapse_repeats([a | rest])
  defp collapse_repeats([first | rest]), do: [first | collapse_repeats(rest)]
  defp collapse_repeats([]), do: []

  defp camelize(segment), do: segment |> String.split("_") |> Enum.map_join(&String.capitalize/1)
end
