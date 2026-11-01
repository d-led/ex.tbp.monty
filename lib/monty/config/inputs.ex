defmodule Monty.Config.Inputs do
  @moduledoc """
  The copy of Monty that this repository ships, and the one way it changes.

  What the application reads from Monty is data — its Hydra config tree and the
  snapshots that tree was composed into — so the data lives here, in `priv/monty`,
  and is copied from a checkout on purpose rather than read at run time. That is
  what lets the image build, the suite and CI run with no Monty checkout at all.

  Copied verbatim, `*.yaml` only: Monty's `conf/` also holds the Python that runs
  Hydra (`update_snapshots.py`, `__pycache__`), which nothing here reads. A file
  upstream deleted is deleted here too — a config that no longer exists must not
  linger in the studio and be run against nothing.

  ## The MuJoCo connector

  `priv/monty_py` is the second half of the same idea: the Python that talks to
  MuJoCo — `simulators/mujoco/` and the modules it imports — copied so a run
  steps *Monty's* world without a checkout and without installing `tbp.monty`.
  It is written by this task too, from the same checkout and at the same
  revision, so the two copies cannot disagree about which Monty they are. The
  list below is a contract and not a glob: it is the import closure of
  `tbp.monty.simulators.mujoco`, and every package directory on the way travels
  with it, because a package without `__init__.py` does not import.

  Every path below is one of two, and both are fixed by configuration: the
  checkout root a caller passed in, and `priv/monty`. Neither is a request —
  this runs in a Mix task — so the file operations carry `sobelow_skip` instead
  of a guard that would only be defending against a value nobody supplies.
  """

  alias Monty.Config.Source

  @conf ["src", "tbp", "monty", "conf"]
  @snapshots ["tests", "conf", "snapshots"]
  @package ["src", "tbp", "monty"]

  # Where the copied Python lives, beside `priv/monty` rather than inside it:
  # Monty's own data tree is YAML, this is code, and the two are reviewed
  # separately.
  @python_root "monty_py"

  # The import closure of `tbp.monty.simulators.mujoco`, relative to `src/`.
  @python [
    "tbp/monty/cmp.py",
    "tbp/monty/context.py",
    "tbp/monty/experiment/learning_module.py",
    "tbp/monty/experiment/monty.py",
    "tbp/monty/experiment/recognition_status.py",
    "tbp/monty/experiment/sensor_module.py",
    "tbp/monty/frameworks/actions/actions.py",
    "tbp/monty/frameworks/agents.py",
    "tbp/monty/frameworks/environments/environment.py",
    "tbp/monty/frameworks/experiments/mode.py",
    "tbp/monty/frameworks/models/abstract_monty_classes.py",
    "tbp/monty/frameworks/models/motor_system_state.py",
    "tbp/monty/frameworks/sensors.py",
    "tbp/monty/geometry.py",
    "tbp/monty/math.py",
    "tbp/monty/memento.py",
    "tbp/monty/observations.py",
    "tbp/monty/sensor_modules/sensor_module.py",
    "tbp/monty/simulators/mujoco/__init__.py",
    "tbp/monty/simulators/mujoco/agents.py",
    "tbp/monty/simulators/mujoco/objects.py",
    "tbp/monty/simulators/mujoco/simulator.py"
  ]

  @typedoc """
  What a sync did, so the caller can show it instead of saying "done".

  `monty` is the checkout's revision, `added`/`updated`/`removed` are file counts.
  """
  @type summary :: %{
          monty: String.t(),
          conf_files: non_neg_integer(),
          snapshot_files: non_neg_integer(),
          python_files: non_neg_integer(),
          added: non_neg_integer(),
          updated: non_neg_integer(),
          removed: non_neg_integer()
        }

  @doc """
  Copies Monty's configs and snapshots from `monty_root` into `destination`.

  Answers the summary and writes `inputs.json` beside the copy, so what is here
  can always be traced to a commit. The only way it can fail is a checkout that
  does not hold the two directories Monty's configs live in.
  """
  @spec sync(Path.t(), Path.t()) :: {:ok, summary()} | {:error, {:missing, String.t(), Path.t()}}
  def sync(monty_root, destination \\ Source.inputs_root()) do
    with :ok <- ensure_directories(monty_root) do
      changes =
        copy(monty_root, destination, "conf", @conf) ++
          copy(monty_root, destination, "snapshots", @snapshots) ++
          copy_licence(monty_root, destination) ++ copy_python(monty_root, destination)

      summary = summarise(monty_root, destination, changes)
      write_manifest(destination, summary)

      {:ok, summary}
    end
  end

  @doc """
  Whether the copy is what the checkout would produce, without writing anything.

  Answers `{:ok, :current}`, `{:ok, {:stale, counts}}` or `{:error, reason}`.
  """
  @spec check(Path.t(), Path.t()) ::
          {:ok, :current | {:stale, map()}} | {:error, {:missing, String.t(), Path.t()}}
  def check(monty_root, destination \\ Source.inputs_root()) do
    with :ok <- ensure_directories(monty_root) do
      wanted = wanted_files(monty_root)
      have = destination_files(destination)

      stale =
        for {path, content} <- wanted,
            Map.get(have, path) != content,
            do: path

      missing = Enum.reject(Map.keys(wanted), &Map.has_key?(have, &1))
      unexpected = Enum.reject(Map.keys(have), &Map.has_key?(wanted, &1))

      case stale ++ missing ++ unexpected do
        [] ->
          {:ok, :current}

        _paths ->
          {:ok,
           {:stale,
            %{stale: length(stale), missing: length(missing), unexpected: length(unexpected)}}}
      end
    end
  end

  defp ensure_directories(monty_root) do
    [
      {"config tree", Path.join([monty_root | @conf])},
      {"snapshots", Path.join([monty_root | @snapshots])},
      {"Monty's package", Path.join([monty_root | @package])}
    ]
    |> Enum.find(fn {_name, dir} -> not File.dir?(dir) end)
    |> case do
      nil -> :ok
      {name, dir} -> {:error, {:missing, name, dir}}
    end
  end

  # Every file the copy should hold, keyed by its path relative to the copy.
  # sobelow_skip ["Traversal.FileModule"]
  defp wanted_files(monty_root) do
    conf = yaml_files(Path.join([monty_root | @conf]), "conf")
    snapshots = yaml_files(Path.join([monty_root | @snapshots]), "snapshots")
    licence = %{"LICENSE" => File.read!(Path.join(monty_root, "LICENSE"))}

    Map.merge(Map.merge(Map.merge(conf, snapshots), licence), wanted_python(monty_root))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp yaml_files(dir, prefix) do
    dir
    |> Path.join("**/*.yaml")
    |> Path.wildcard()
    |> Map.new(fn path ->
      {Path.join(prefix, Path.relative_to(path, dir)), File.read!(path)}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp destination_files(destination) do
    for prefix <- ["conf", "snapshots"] do
      destination
      |> Path.join("#{prefix}/**/*.yaml")
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, destination), File.read!(&1)})
    end
    |> then(fn [conf, snapshots] ->
      Map.merge(Map.merge(conf, snapshots), licence_file(destination) |> with_python(destination))
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp licence_file(destination) do
    path = Path.join(destination, "LICENSE")

    if File.exists?(path), do: %{"LICENSE" => File.read!(path)}, else: %{}
  end

  defp copy(monty_root, destination, prefix, segments) do
    source_dir = Path.join([monty_root | segments])

    written =
      for {relative, content} <- yaml_files(source_dir, prefix) do
        write(destination, relative, content)
      end

    written ++ prune(destination, prefix, Map.keys(yaml_files(source_dir, prefix)))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp copy_licence(monty_root, destination) do
    case write(destination, "LICENSE", File.read!(Path.join(monty_root, "LICENSE"))) do
      :unchanged -> []
      change -> [change]
    end
  end

  # -- the MuJoCo connector ---------------------------------------------------

  # What the Python copy should hold, keyed `monty_py/<path>` so that a check
  # compares the two copies with one map rather than two roots.
  # sobelow_skip ["Traversal.FileModule"]
  defp wanted_python(monty_root) do
    source = Path.join(monty_root, "src")

    modules =
      for relative <- @python, into: %{} do
        {Path.join(@python_root, relative), File.read!(Path.join(source, relative))}
      end

    modules
    |> Map.merge(package_files(monty_root))
    |> Map.put(
      Path.join(@python_root, "LICENSE"),
      File.read!(Path.join(monty_root, "LICENSE"))
    )
  end

  # The copy's own Python, keyed the same way, so `check/2` can compare them.
  # Only `tbp/` is Monty's: the files at the root of `priv/monty_py` are ours —
  # the glue that drives the copied classes — and are not this task's business.
  # sobelow_skip ["Traversal.FileModule"]
  defp with_python(files, destination) do
    directory = python_destination(destination)

    modules =
      directory
      |> Path.join("tbp/**/*.py")
      |> Path.wildcard()
      |> Map.new(&{Path.join(@python_root, Path.relative_to(&1, directory)), File.read!(&1)})

    licence = %{Path.join(@python_root, "LICENSE") => File.read!(Path.join(directory, "LICENSE"))}

    files |> Map.merge(modules) |> Map.merge(licence)
  end

  # Copies the closure, every package `__init__.py` on the way, and the licence.
  # A file upstream deleted is deleted here too: a module the simulator no
  # longer imports must not linger and be importable by accident.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_python(monty_root, destination) do
    wanted = wanted_python(monty_root)
    directory = python_destination(destination)

    written =
      for {relative, content} <- wanted do
        relative |> relative() |> then(&write(directory, &1, content))
      end

    written ++ prune_python(directory, wanted |> Map.keys() |> Enum.map(&relative/1))
  end

  # A package directory without `__init__.py` does not import, so every one on
  # the way travels with the modules it contains.
  # sobelow_skip ["Traversal.FileModule"]
  defp package_files(monty_root) do
    source = Path.join(monty_root, "src")

    @python
    |> Enum.flat_map(&ancestors/1)
    |> Enum.uniq()
    |> Enum.map(&Path.join(&1, "__init__.py"))
    |> Enum.filter(&File.exists?(Path.join(source, &1)))
    |> Map.new(fn relative ->
      {Path.join(@python_root, relative), File.read!(Path.join(source, relative))}
    end)
  end

  # Every directory above a file, up to the package root but not above it.
  defp ancestors(relative) do
    relative
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(nil, fn segment, acc -> if acc, do: Path.join(acc, segment), else: segment end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp prune_python(directory, keep) do
    wanted = MapSet.new(keep)

    for path <- Path.wildcard(Path.join(directory, "tbp/**/*.py")),
        relative = Path.relative_to(path, directory),
        not MapSet.member?(wanted, relative) do
      File.rm!(path)
      {:removed, Path.join(@python_root, relative)}
    end
    |> tap(fn _removed -> prune_empty_directories(Path.join(directory, "tbp")) end)
  end

  defp relative(path), do: String.replace_prefix(path, @python_root <> "/", "")

  defp python_destination(destination), do: Path.join(Path.dirname(destination), @python_root)

  # sobelow_skip ["Traversal.FileModule"]
  defp write(destination, relative, content) do
    path = Path.join(destination, relative)

    case File.read(path) do
      {:ok, ^content} ->
        :unchanged

      {:ok, _other} ->
        File.write!(path, content)
        {:updated, relative}

      {:error, :enoent} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        {:added, relative}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp prune(destination, prefix, keep) do
    wanted = MapSet.new(keep)

    for path <- Path.wildcard(Path.join([destination, prefix, "**/*.yaml"])),
        relative = Path.relative_to(path, destination),
        not MapSet.member?(wanted, relative) do
      File.rm!(path)
      {:removed, relative}
    end
    |> tap(fn _removed -> prune_empty_directories(Path.join(destination, prefix)) end)
  end

  defp prune_empty_directories(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.each(fn path ->
      if File.ls!(path) == [], do: File.rmdir!(path)
    end)
  end

  defp summarise(monty_root, destination, changes) do
    conf = Path.wildcard(Path.join([destination, "conf", "**/*.yaml"])) |> length()
    snapshots = Path.wildcard(Path.join([destination, "snapshots", "**/*.yaml"])) |> length()

    python =
      Path.wildcard(Path.join([python_destination(destination), "tbp/**/*.py"])) |> length()

    %{
      monty: revision(monty_root),
      conf_files: conf,
      snapshot_files: snapshots,
      python_files: python,
      added: Enum.count(changes, &match?({:added, _}, &1)),
      updated: Enum.count(changes, &match?({:updated, _}, &1)),
      removed: Enum.count(changes, &match?({:removed, _}, &1))
    }
  end

  defp revision(monty_root) do
    case System.cmd("git", ["-C", monty_root, "rev-parse", "--short=8", "HEAD"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _no_git_or_not_a_checkout -> "unknown"
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_manifest(destination, summary) do
    manifest = %{
      "monty" => summary.monty,
      "conf_files" => summary.conf_files,
      "snapshot_files" => summary.snapshot_files,
      "python_files" => summary.python_files
    }

    File.write!(
      Path.join(destination, "inputs.json"),
      Jason.encode!(manifest, pretty: true) <> "\n"
    )
  end
end
