defmodule Monty.Studio.Memory do
  @moduledoc """
  Monty's pretrained memory, as a run can load it.

  Monty stores a pretrained learning module as a torch pickle;
  `scripts/export_monty_pretrained.py` turns one into a JSONL of objects, nodes
  and features, and this reads one of those back. That is the bridge between
  Monty's memory and a run here: the arithmetic on top is the port's
  `EvidenceGraphLM`, which is what a run then recognises with.

  ## Where the libraries live

  `priv/monty/libraries/<release>/<name>.jsonl.gz`, where `<name>` is the last
  meaningful segment of the `model_name_or_path` a config names — Monty's own
  directory name for that model (`surf_agent_1lm_10distinctobj`) — and
  `<release>` is the directory Monty keeps models of that release in
  (`pretrained_ycb_v13`), which is the segment just before it in that path.

  The release is part of the address because it is part of the model: the same
  name in two releases is two different memories, trained differently. A config
  that names `${constants.pretrained_dir}/surf_agent_1lm_10similarobj/pretrained/`
  means whatever release its `pretrained_dir` resolves to, and a run that
  recognised with another release's graphs would be answering a question nobody
  asked.

  A config that names a model with no library — or a release with no library for
  it — is not an error: the run gets an empty memory, or one from a release the
  setup warns about, which is what "this run has nothing to recognise with"
  should look like.
  """

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel

  @library_extension ".jsonl.gz"

  # What the evidence-based learning module matches on, which is the only part of
  # a pretrained model a graph is matched through.
  @features ["hsv", "pose_vectors", "pose_fully_defined", "principal_curvatures_log"]

  @doc "The directory the libraries are read from."
  @spec libraries_dir() :: Path.t()
  def libraries_dir do
    Application.get_env(
      :ex_tbp_monty,
      :monty_libraries_dir,
      Path.join(:code.priv_dir(:ex_tbp_monty), "monty/libraries")
    )
  end

  @doc """
  The library name a config's `model_name_or_path` refers to.

  Monty's path ends at the model's own directory
  (`…/surf_agent_1lm_10distinctobj/pretrained/`), so the name is the segment
  before `pretrained`, or the last one when there is none.
  """
  @spec name_of(String.t() | nil) :: String.t() | nil
  def name_of(nil), do: nil

  def name_of(path) do
    case segments(path) do
      ["pretrained", name | _rest] -> name
      [name | _rest] -> name
      [] -> nil
    end
  end

  @doc """
  The release a config's `model_name_or_path` refers to, if it names one.

  In `…/pretrained_ycb_v13/surf_agent_1lm_10similarobj/pretrained/` the release
  is the directory the model sits in, `pretrained_ycb_v13` — the same directory
  Monty's own `pretrained_ycb_v*` archive unpacks to. A path that names only a
  model gives `nil`: there is nothing to match a library against, and guessing
  one would be the quiet substitution this keying exists to prevent.
  """
  @spec release_of(String.t() | nil) :: String.t() | nil
  def release_of(nil), do: nil

  def release_of(path) do
    case segments(path) do
      ["pretrained", _name, release | _rest] -> release
      [_name, release | _rest] -> release
      _alone -> nil
    end
  end

  defp segments(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 in ["", "."]))
    |> Enum.reverse()
  end

  @doc """
  Does a library exist for this model, from this release?

  The directory is an argument rather than only a setting so that a caller —
  a test, or a page showing what is installed — can ask about a directory
  without changing what the rest of the application sees.
  """
  @spec available?(String.t() | nil, String.t() | nil, Path.t()) :: boolean()
  def available?(name, release, dir \\ libraries_dir()),
    do: is_binary(name) and is_binary(release) and File.exists?(path_for(name, release, dir))

  @doc "Where the library for a model and release lives, whether or not it is there."
  @spec path_for(String.t(), String.t(), Path.t()) :: Path.t()
  def path_for(name, release, dir \\ libraries_dir()),
    do: Path.join([dir, release, name <> @library_extension])

  @doc """
  The releases this directory holds a library for `name` in.

  A model exported from one release but named by a config of another is worth
  saying out loud: the run can go ahead with the memory that is here, but it is
  not the memory Monty would have loaded.
  """
  @spec releases_for(String.t() | nil, Path.t()) :: [String.t()]
  def releases_for(name, dir \\ libraries_dir()) do
    with true <- model_name?(name),
         {:ok, releases} <- File.ls(dir) do
      releases
      |> Enum.filter(fn release -> File.exists?(path_for(name, release, dir)) end)
      |> Enum.sort()
    else
      _none -> []
    end
  end

  @doc """
  Loads a model's library from a release into a memory, or says it is not there.

  Decoding one of these is six seconds of gunzip and graph building, and a run
  gets its own copy of the memory anyway — learning writes to it, so two runs
  must not share one. So the built memory is kept per path and each caller is
  handed a copy, which costs about twenty milliseconds instead.

  `:not_found` is not a failure of the port: it is a model whose pickle has not
  been exported here, and the caller says so as a finding.
  """
  @spec load(String.t(), String.t(), Path.t()) ::
          {:ok, GraphMemory.t()} | {:error, :not_found | term()}
  def load(name, release, dir \\ libraries_dir()) do
    with true <- model_name?(name),
         true <- is_binary(release),
         path = path_for(name, release, dir),
         true <- File.exists?(path) do
      {:ok, copy(built(path))}
    else
      _absent -> {:error, :not_found}
    end
  end

  # A model name is a directory name from Monty's own tree: letters, digits,
  # underscores and dashes. Anything else — a path, a `..`, a nested directory —
  # is not a model, and never becomes one.
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

  @doc "Whether a string is a model name this module will build a path from."
  @spec model_name?(term()) :: boolean()
  def model_name?(name), do: is_binary(name) and Regex.match?(@name_format, name)

  # The decoded memory, built once per path for the life of the node. The key is
  # the path, so pointing `:monty_libraries_dir` somewhere else (as a test that
  # wants no libraries does) is a different cache entry rather than a stale hit.
  defp built(path) do
    key = {__MODULE__, :library, path}

    case :persistent_term.get(key, nil) do
      nil ->
        memory = read!(path)
        :persistent_term.put(key, memory)
        memory

      memory ->
        memory
    end
  end

  defp copy(memory), do: memory |> :erlang.term_to_binary() |> :erlang.binary_to_term()

  @doc "The libraries that are present, as `release/name`, one per file."
  @spec available_libraries(Path.t()) :: [String.t()]
  def available_libraries(dir \\ libraries_dir()) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn release ->
          files =
            case File.ls(Path.join(dir, release)) do
              {:ok, files} -> files
              # A README beside the releases is not a release.
              {:error, _reason} -> []
            end

          for file <- files, String.ends_with?(file, @library_extension) do
            release <> "/" <> model_of(file)
          end
        end)
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp model_of(file), do: file |> Path.rootname() |> Path.rootname()

  # sobelow_skip ["Traversal.FileModule"]
  # The path is a directory from `libraries_dir/0` plus a name `model_name?/1`
  # has checked, so there is no traversal to guard against here.
  defp read!(path) do
    records =
      path
      |> File.read!()
      |> :zlib.gunzip()
      |> String.split("\n", trim: true)
      |> Enum.map(&decode!/1)

    # A memory holds graphs by object and channels under each object, and says
    # which features it matches on per channel. Both come from the export.
    models =
      records
      |> Enum.group_by(& &1["object_id"], fn %{"input_channel" => channel} = record ->
        {:ok, model} =
          record["object_id"]
          |> GraphObjectModel.new()
          |> GraphObjectModel.set_graph(graph_of(record))

        {channel, model}
      end)
      |> Map.new(fn {object_id, channels} -> {object_id, Map.new(channels)} end)

    features_to_use =
      records
      |> Enum.map(& &1["input_channel"])
      |> Enum.uniq()
      |> Map.new(&{&1, @features})

    GraphMemory.new(features_to_use: features_to_use)
    |> GraphMemory.load_state_dict(models)
    |> GraphMemory.initialize_feature_arrays()
  end

  # A graph is positions and one row per node; the column order is the export's
  # own choice, so it is alphabetical and never assumed by anyone.
  defp graph_of(%{"positions" => positions, "features" => features}) do
    names = features |> Map.keys() |> Enum.sort()

    {mapping, _offset} =
      Enum.map_reduce(names, 0, fn name, offset ->
        width = features |> Map.fetch!(name) |> hd() |> length()
        {{name, {offset, offset + width}}, offset + width}
      end)

    %{
      pos: positions,
      x:
        names
        |> Enum.map(&Map.fetch!(features, &1))
        |> Enum.zip_with(&Enum.concat/1),
      feature_mapping: Map.new(mapping)
    }
  end

  defp decode!(line) do
    case Jason.decode(line) do
      {:ok, value} -> value
      {:error, reason} -> raise "cannot read a pretrained library: #{inspect(reason)}"
    end
  end
end
