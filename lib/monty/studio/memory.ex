defmodule Monty.Studio.Memory do
  @moduledoc """
  Monty's pretrained memory, as a run can load it.

  Monty stores a pretrained learning module as a torch pickle;
  `scripts/export_monty_pretrained.py` turns one into a JSONL of objects, nodes
  and features, and this reads one of those back. That is the bridge between
  Monty's memory and a run here: the arithmetic on top is the port's
  `EvidenceGraphLM`, which is what a run then recognises with.

  ## Where the libraries live

  `priv/monty/libraries/<name>.jsonl.gz`, where `<name>` is the last meaningful
  segment of the `model_name_or_path` a config names — Monty's own directory name
  for that model (`surf_agent_1lm_10distinctobj`). A config that names a model
  with no library is not an error: the run gets an empty memory and a finding
  says so, which is what "this run has nothing to recognise with" should look
  like.
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
    segments = path |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))

    case Enum.reverse(segments) do
      ["pretrained" | [name | _rest]] -> name
      [name | _rest] -> name
      [] -> nil
    end
  end

  @doc """
  Does a library exist for this config's model?

  The directory is an argument rather than only a setting so that a caller —
  a test, or a page showing what is installed — can ask about a directory
  without changing what the rest of the application sees.
  """
  @spec available?(String.t() | nil, Path.t()) :: boolean()
  def available?(name, dir \\ libraries_dir()),
    do: is_binary(name) and File.exists?(path_for(name, dir))

  @doc "Where the library for a name lives, whether or not it is there."
  @spec path_for(String.t(), Path.t()) :: Path.t()
  def path_for(name, dir \\ libraries_dir()),
    do: Path.join(dir, name <> @library_extension)

  @doc """
  Loads the library for a name into a memory, or says it is not there.

  Decoding one of these is six seconds of gunzip and graph building, and a run
  gets its own copy of the memory anyway — learning writes to it, so two runs
  must not share one. So the built memory is kept per path and each caller is
  handed a copy, which costs about twenty milliseconds instead.

  `:not_found` is not a failure of the port: it is a model whose pickle has not
  been exported here, and the caller says so as a finding.
  """
  @spec load(String.t(), Path.t()) :: {:ok, GraphMemory.t()} | {:error, :not_found | term()}
  def load(name, dir \\ libraries_dir()) do
    with true <- model_name?(name),
         path = path_for(name, dir),
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

  @doc "The libraries that are present, by name."
  @spec available_libraries(Path.t()) :: [String.t()]
  def available_libraries(dir \\ libraries_dir()) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, @library_extension))
        |> Enum.map(&Path.rootname(Path.rootname(&1)))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

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
