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
  """

  alias Monty.Config.Source

  @conf ["src", "tbp", "monty", "conf"]
  @snapshots ["tests", "conf", "snapshots"]

  @typedoc """
  What a sync did, so the caller can show it instead of saying "done".

  `monty` is the checkout's revision, `added`/`updated`/`removed` are file counts.
  """
  @type summary :: %{
          monty: String.t(),
          conf_files: non_neg_integer(),
          snapshot_files: non_neg_integer(),
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
          copy_licence(monty_root, destination)

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
      {"snapshots", Path.join([monty_root | @snapshots])}
    ]
    |> Enum.find(fn {_name, dir} -> not File.dir?(dir) end)
    |> case do
      nil -> :ok
      {name, dir} -> {:error, {:missing, name, dir}}
    end
  end

  # Every file the copy should hold, keyed by its path relative to the copy.
  defp wanted_files(monty_root) do
    conf = yaml_files(Path.join([monty_root | @conf]), "conf")
    snapshots = yaml_files(Path.join([monty_root | @snapshots]), "snapshots")
    licence = %{"LICENSE" => File.read!(Path.join(monty_root, "LICENSE"))}

    Map.merge(Map.merge(conf, snapshots), licence)
  end

  defp yaml_files(dir, prefix) do
    dir
    |> Path.join("**/*.yaml")
    |> Path.wildcard()
    |> Map.new(fn path ->
      {Path.join(prefix, Path.relative_to(path, dir)), File.read!(path)}
    end)
  end

  defp destination_files(destination) do
    for prefix <- ["conf", "snapshots"] do
      destination
      |> Path.join("#{prefix}/**/*.yaml")
      |> Path.wildcard()
      |> Map.new(&{Path.relative_to(&1, destination), File.read!(&1)})
    end
    |> then(fn [conf, snapshots] ->
      Map.merge(Map.merge(conf, snapshots), licence_file(destination))
    end)
  end

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

  defp copy_licence(monty_root, destination) do
    case write(destination, "LICENSE", File.read!(Path.join(monty_root, "LICENSE"))) do
      :unchanged -> []
      change -> [change]
    end
  end

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

    %{
      monty: revision(monty_root),
      conf_files: conf,
      snapshot_files: snapshots,
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

  defp write_manifest(destination, summary) do
    manifest = %{
      "monty" => summary.monty,
      "conf_files" => summary.conf_files,
      "snapshot_files" => summary.snapshot_files
    }

    File.write!(
      Path.join(destination, "inputs.json"),
      Jason.encode!(manifest, pretty: true) <> "\n"
    )
  end
end
