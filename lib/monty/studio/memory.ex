defmodule Monty.Studio.Memory do
  @moduledoc """
  Monty's pretrained memory, as a run can load it — and as a run's own training
  can leave it.

  Monty stores a pretrained learning module as a torch pickle;
  `Monty.Studio.Pretrained` turns one into a JSONL of objects, nodes and
  features, this reads one of those back (`load/3`) and writes one (`save/4`).
  That is the bridge between Monty's memory and a run here: the arithmetic on top
  is the port's `EvidenceGraphLM`, which is what a run then recognises with.

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

  Decoding one of these is six seconds of gunzip and graph building, so the built
  memory is kept per path in `:persistent_term` and **handed over, not copied**: a
  term is immutable, so what a run does with it — building a module's state on top,
  learning, writing its own library at the end — makes new data and cannot reach
  what another run reads. Copying it took twenty to forty milliseconds an episode
  and bought nothing: the copy could not have been the thing that changed.

  `:not_found` is not a failure of the port: it is a model whose pickle has not
  been exported here, and the caller says so as a finding.

  `module_index` is which learning module of the pretrained model the caller
  wants. A heterarchy's three modules are three memories — the 3-D child, the 2-D
  child, and the high-level one — and `modules/3` says how many a library holds.
  """
  @spec load(String.t(), String.t(), Path.t()) ::
          {:ok, GraphMemory.t()} | {:error, :not_found | term()}
  def load(name, release, dir \\ libraries_dir()),
    do: load_module(name, release, 0, dir)

  @doc """
  One learning module's memory out of a model's library.

  `module_index` is which module of the pretrained model to read. A heterarchy's
  three modules are three memories — the 3-D child, the 2-D child, and the
  high-level one — and `modules/3` says how many a library holds. A library
  exported before records carried an index holds one memory, which is module 0.
  """
  @spec load_module(String.t(), String.t(), non_neg_integer(), Path.t()) ::
          {:ok, GraphMemory.t()} | {:error, :not_found | term()}
  def load_module(name, release, module_index, dir \\ libraries_dir()) do
    with true <- model_name?(name),
         true <- is_binary(release),
         path = path_for(name, release, dir),
         true <- File.exists?(path) do
      {:ok, built(path, module_index)}
    else
      _absent -> {:error, :not_found}
    end
  end

  @doc """
  How many learning modules' memories a library holds.

  One for a model trained by a single-module run, and one per module for a
  heterarchy. A config that names more modules than its library holds would be
  giving two of them the same memory, so the number is asked for before a run.
  """
  @spec modules(String.t() | nil, String.t() | nil, Path.t()) :: non_neg_integer() | nil
  def modules(name, release, dir \\ libraries_dir()) do
    with true <- model_name?(name),
         true <- is_binary(release),
         path = path_for(name, release, dir),
         true <- File.exists?(path) do
      index_counts(path) |> map_size()
    else
      _absent -> nil
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
  defp built(path, module_index) do
    key = {__MODULE__, :library, path, module_index}

    case :persistent_term.get(key, nil) do
      nil ->
        memory = read!(path, module_index)
        :persistent_term.put(key, memory)
        memory

      memory ->
        memory
    end
  end

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

  @doc """
  Writes `memory` out as the library for `name` in `release`.

  This is the other half of `load/3`: what a training phase learned dies with the
  run that learned it unless it is written down, and the format it is written in
  is the one the pretrained libraries are already in — objects, nodes and
  features, one record a graph.

  Every graph is written as it stands, so reading it back gives the same nodes in
  the same places. What a record does not carry is the memory's own configuration
  — its object model and its `k` — because that belongs to the experiment that
  continues the training, not to the graph (see `Monty.Studio.Setup.memories/1`).
  """
  @spec save(GraphMemory.t(), String.t(), String.t(), Path.t()) :: :ok | {:error, term()}
  def save(%GraphMemory{} = memory, name, release, dir \\ libraries_dir()),
    do: save_all([{0, memory}], name, release, dir)

  @doc """
  Writes several modules' memories as one library — a model, not a module.

  A heterarchy's model *is* five memories, and Monty names the model once: a
  config reads `…/dist_agent_5lm_2obj_train/pretrained/`, a directory holding one
  file per module. A library file here holds the same thing — one record a graph,
  each carrying the index of the module it belongs to — which is what
  `load_module/4` reads one index at a time and `modules/3` counts.

  One file rather than one file per module, because the name a config asks for is
  the *model's*: a training run that filed
  `dist_agent_5lm_2obj_train-learning_module_0` … `_4` left five libraries no
  config asks for, and the evaluation config of the tutorial found none of them.
  """
  @spec save_all([{non_neg_integer(), GraphMemory.t()}], String.t(), String.t(), Path.t()) ::
          :ok | {:error, term()}
  def save_all(indexed, name, release, dir \\ libraries_dir()) do
    with :ok <- check_name(name),
         :ok <- check_release(release) do
      records =
        Enum.flat_map(indexed, fn {index, memory} ->
          Enum.map(records_of(memory), &Map.put(&1, "lm_index", index))
        end)

      write(path_for(name, release, dir), records)
    end
  end

  defp check_name(name) do
    if model_name?(name), do: :ok, else: {:error, {:not_a_model_name, name}}
  end

  defp check_release(release) do
    if model_name?(release), do: :ok, else: {:error, {:not_a_model_name, release}}
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The path is built by `path_for/3` from a directory and two names `check_*`
  # have already held to the shape of a Monty directory name.
  defp write(path, records) do
    body = Enum.map_join(records, "\n", &Jason.encode!/1)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, :zlib.gzip(body <> "\n"))
    end
  end

  # One record a graph, in the shape `graph_of/1` reads back: the object and the
  # channel it belongs to, one position a node, and every node's features under
  # the names the graph gives them. Column order is the reader's to choose, so it
  # is not written.
  #
  # The graph is read through the memory's own object model, because a module that
  # learned into grid models holds those and a pretrained library holds plain
  # graphs: both answer `graph/1`, and what a record is made of is the same either
  # way.
  defp records_of(%GraphMemory{} = memory) do
    for {object_id, channels} <- GraphMemory.state_dict(memory),
        {input_channel, model} <- channels,
        graph <- [memory.object_model.graph(model)],
        graph != nil do
      %{
        "object_id" => object_id,
        "input_channel" => input_channel,
        "positions" => graph.pos,
        "features" => features_of(graph)
      }
    end
  end

  defp features_of(%{x: rows, feature_mapping: mapping}) do
    Map.new(mapping, fn {name, {start, stop}} ->
      {name, Enum.map(rows, &Enum.slice(&1, start, stop - start))}
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The path is a directory from `libraries_dir/0` plus a name `model_name?/1`
  # has checked, so there is no traversal to guard against here.
  defp read!(path, module_index) do
    records =
      path
      |> File.read!()
      |> :zlib.gunzip()
      |> String.split("\n", trim: true)
      |> Enum.map(&decode!/1)
      |> Enum.filter(&(Map.get(&1, "lm_index", 0) == module_index))

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

    # Which features this kernel matches a channel through: the ones it knows,
    # held by the library. A 2-D child's graphs carry coherence and edge strength
    # where an evidence module's carry pose vectors, and asking for a column the
    # graphs do not hold would read absent values as absent evidence — every node
    # would match nothing for a reason nobody could see.
    features_to_use =
      records
      |> Enum.group_by(& &1["input_channel"], &Map.keys(&1["features"]))
      |> Map.new(fn {channel, name_lists} ->
        held = name_lists |> List.flatten() |> MapSet.new()
        {channel, Enum.filter(@features, &MapSet.member?(held, &1))}
      end)

    GraphMemory.new(features_to_use: features_to_use)
    |> GraphMemory.load_state_dict(models)
    |> GraphMemory.initialize_feature_arrays()
  end

  # Which module memories a library holds, counted once per path: the answer is a
  # property of the file, and reading a few hundred kilobytes to answer it on
  # every page render is not.
  # sobelow_skip ["Traversal.FileModule"]
  # Same path as `read!/2` is handed: a library from `libraries_dir/0` plus a name
  # `model_name?/1` has checked, not a request.
  defp index_counts(path) do
    key = {__MODULE__, :module_counts, path}

    case :persistent_term.get(key, nil) do
      nil ->
        counts =
          path
          |> File.read!()
          |> :zlib.gunzip()
          |> String.split("\n", trim: true)
          |> Enum.frequencies_by(&(&1 |> decode!() |> Map.get("lm_index", 0)))

        :persistent_term.put(key, counts)
        counts

      counts ->
        counts
    end
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
