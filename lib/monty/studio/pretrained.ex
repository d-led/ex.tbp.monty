defmodule Monty.Studio.Pretrained do
  @moduledoc """
  Monty's pretrained memory, written out as the libraries a run reads.

  A run recognises with graphs, and Monty's graphs arrive inside a torch pickle
  (`pretrained_ycb_v14/<model>/pretrained/model.pt`). `Monty.Studio.Pretrained`
  turns those pickles into the JSONL libraries `Monty.Studio.Memory` reads, and
  nothing else: what a model *is* here is a position per node and a row of
  features per node, and both are plain numbers.

  ## Why it is not a script

  The libraries are derived data, so they are not in git: they are produced on
  the machine that needs them, from the archive the prerequisite fetch already
  unpacked. That fetch ends by calling `sync/2`, which exports what is missing
  and leaves what is current — so the first run of an experiment has its memory,
  and a second visit to `/prerequisites` does no work at all.

  ## What is exported

  Each line is one object and input channel:

      {"object_id": "mug", "input_channel": "patch",
       "positions": [[x, y, z], …],
       "features": {"hsv": [[h, s, v], …], …}}

  Features are the ones the learning module compares — `hsv`, `pose_vectors`,
  `pose_fully_defined` and `principal_curvatures_log` — because a graph that is
  only ever matched against does not need the rest. Every number is written at
  full precision: at six decimals a node a millionth of a metre off picks a
  different node when a sphere makes many of them match equally well.

  The pretrained models in `pretrained_ycb_v10` were trained with the older
  feature-graph learning module, so they store `GraphObjectModel`s; the evidence
  module loads them as they are (`use_original_graph`), which is why the stored
  graph is exported rather than a rebuilt one.
  """

  alias Monty.Prerequisites
  alias Monty.Studio.Memory
  alias Monty.Studio.Pretrained.Tensor
  alias Monty.Studio.Pretrained.Torch
  alias Unpickler.Object

  # What the evidence-based learning module matches on, which is the only part of
  # a pretrained model a graph is matched through.
  @features ["hsv", "pose_vectors", "pose_fully_defined", "principal_curvatures_log"]

  @model_file Path.join(["pretrained", "model.pt"])

  @typedoc """
  What a sync did: which libraries it wrote, which were already current, and
  which it could not read.
  """
  @type outcome :: %{
          exported: [String.t()],
          current: [String.t()],
          failed: [{String.t(), term()}]
        }

  @doc "Where Monty's pretrained models are unpacked."
  @spec models_root() :: Path.t()
  def models_root, do: Prerequisites.root_path("MONTY_MODELS")

  @doc """
  Exports every model under a root whose library is missing or out of date.

  Given no arguments, that is Monty's own models directory and the libraries
  this installation reads. A model whose library is newer than the pickle it
  came from is left alone: a second sync does nothing, which is what makes it
  safe to run on every visit to `/prerequisites`.

  `:on_progress` is called once per model, before that model is read, with
  `%{model: "release/name", index: n, total: m}` — the export is minutes of
  reading with nothing on the wire to measure, and this is what a page can show
  while it runs.
  """
  @spec sync() :: outcome
  def sync, do: sync(models_root(), Memory.libraries_dir())

  # Options on their own, as their own arity: with defaults on all three
  # parameters `sync(on_progress: fun)` would fill the *first* one, and read a
  # keyword list as a models root.
  @spec sync(keyword()) :: outcome
  def sync(opts) when is_list(opts), do: sync(models_root(), Memory.libraries_dir(), opts)

  @spec sync(Path.t(), Path.t()) :: outcome
  def sync(root, libraries), do: sync(root, libraries, [])

  @spec sync(Path.t(), Path.t(), keyword()) :: outcome
  def sync(root, libraries, opts) do
    on_progress = Keyword.get(opts, :on_progress)
    models = models(root)
    total = length(models)

    models
    |> Enum.with_index(1)
    |> Enum.map(fn {model, index} ->
      announce(on_progress, model, index, total)
      one(model, libraries)
    end)
    |> Enum.reduce(%{exported: [], current: [], failed: []}, &collect/2)
    |> Map.new(fn {kind, values} -> {kind, Enum.reverse(values)} end)
  end

  defp announce(nil, _model, _index, _total), do: :ok

  defp announce(on_progress, {release, name, _pickle}, index, total) do
    on_progress.(%{model: label(release, name), index: index, total: total})
  end

  # One model: left alone when its library is newer than the pickle, written
  # when it is not, and named when it cannot be read at all.
  defp one({release, name, pickle}, libraries) do
    out = Memory.path_for(name, release, libraries)

    if current?(out, pickle) do
      {:current, label(release, name)}
    else
      case export(pickle, out) do
        :ok -> {:exported, label(release, name)}
        {:error, reason} -> {:failed, {label(release, name), reason}}
      end
    end
  end

  defp collect({kind, value}, outcome), do: Map.update!(outcome, kind, &[value | &1])

  @doc """
  The models under a root, as `{release, name, pickle}`.

  Two layouts are asked about, and both mean "the models here":

    * a **root of releases** — `pretrained_models/<release>/<name>/pretrained/model.pt`
      — which is what `MONTY_MODELS` is, and what `sync/0` walks;
    * a **release directory** — `pretrained_ycb_v14/<name>/pretrained/model.pt` —
      which is what an archive unpacks to, and therefore what a fetch of that
      archive should export.

  The second one was missing, and it failed silently: a scoped export looked one
  directory deeper than the archive had unpacked, found no models, and reported
  a memory "exported" by exporting nothing. A released archive's own name is the
  release its libraries belong under.
  """
  @spec models(Path.t()) :: [{String.t(), String.t(), Path.t()}]
  def models(root) do
    (Path.wildcard(Path.join(root, "*/*/" <> @model_file)) ++
       Path.wildcard(Path.join(root, "*/" <> @model_file)))
    |> Enum.uniq()
    |> Enum.map(&describe(&1, root))
    |> Enum.sort()
  end

  defp describe(pickle, root) do
    case pickle |> Path.relative_to(root) |> Path.split() |> Enum.reverse() do
      [_file, "pretrained", name, release | _rest] ->
        {release, name, pickle}

      [_file, "pretrained", name] ->
        {Path.basename(root), name, pickle}

      _not_a_model ->
        {Path.basename(root), Path.basename(Path.dirname(Path.dirname(pickle))), pickle}
    end
  end

  @doc """
  Writes one model's memory to a library file.

  The file is written beside its destination and moved into place, so a reader
  never sees half an export and a failed one leaves the previous library alone.
  """
  # sobelow_skip ["Traversal.FileModule"]
  # `out` is a directory from `Memory.libraries_dir/0` plus a name
  # `Memory.model_name?/1` has checked, and `partial` is that path with a fixed
  # suffix; neither comes from a request.
  @spec export(Path.t(), Path.t()) :: :ok | {:error, term()}
  def export(pickle, out) do
    partial = out <> ".part"

    with :ok <- File.mkdir_p(Path.dirname(out)),
         :ok <- write(pickle, partial),
         :ok <- File.rename(partial, out) do
      :ok
    else
      {:error, reason} ->
        File.rm(partial)
        {:error, reason}
    end
  rescue
    # A pickle this build cannot read is one model the run can go ahead without:
    # `sync/2` collects these into its `failed` list and names them, which is
    # better than the export stopping at the first one and writing nothing.
    error -> {:error, Exception.message(error)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Same path as `export/2` hands over: a library path, not a request.
  defp write(pickle, partial) do
    # Written one record at a time into a gzip stream. Building the list of
    # records, then a binary per record, then one `:zlib.gzip/1` over all of
    # them holds the model four times over — hundreds of megabytes for a release
    # of ten objects — and a machine that starts swapping makes every open page
    # crawl while it does. Streaming keeps one record at a time.
    file = File.open!(partial, [:write, :binary, :raw])
    gzip = :zlib.open()

    try do
      :ok = :zlib.deflateInit(gzip, :default, :deflated, 31, 8, :default)

      pickle
      |> Torch.load!()
      |> stream_records()
      |> Enum.each(fn record ->
        IO.binwrite(file, :zlib.deflate(gzip, [Jason.encode!(record), "\n"]))
      end)

      IO.binwrite(file, :zlib.deflate(gzip, [], :finish))
      :ok
    after
      :zlib.deflateEnd(gzip)
      :zlib.close(gzip)
      File.close(file)
    end
  end

  @doc """
  The objects and channels in a pretrained model, as one record each.

  A record is keyed the way the line it becomes is keyed, so what a reader of
  the library sees is what was built here — no translation in between.

  Monty keeps pretrained learning modules in `lm_dict`, one per module, and the
  graphs of the first are the memory a single-module run recognises with.
  """
  @spec records(term()) :: [map()]
  def records(term), do: term |> stream_records() |> Enum.to_list()

  @doc """
  The same records, produced one at a time.

  The export writes each of them as it arrives, so a model is never held as a
  list of records, a list of encodings and a gzip of both.
  """
  @spec stream_records(term()) :: Enumerable.t()
  def stream_records(term) do
    term
    |> module_memory()
    |> Enum.sort()
    |> Stream.flat_map(fn {object_id, channels} ->
      channels
      |> Enum.sort()
      |> Stream.map(fn {channel, model} -> record(object_id, channel, model) end)
    end)
  end

  defp record(object_id, channel, model) do
    graph = graph_of(model)

    %{
      "object_id" => object_id,
      "input_channel" => channel,
      "positions" => graph |> Map.fetch!("pos") |> Tensor.rows(),
      "features" =>
        Map.new(@features, fn name ->
          [first, last] = graph |> Map.fetch!("feature_mapping") |> Map.fetch!(name)
          {name, Tensor.columns(Map.fetch!(graph, "x"), first, last)}
        end)
    }
  end

  defp module_memory(%{"lm_dict" => modules}) when is_list(modules),
    do: module_memory(hd(modules))

  defp module_memory(%{"lm_dict" => %{0 => module}}), do: module_memory(module)
  defp module_memory(%{"graph_memory" => memory}), do: memory

  # A model keeps its graph in `_graph`, a torch_geometric `Data`, whose
  # attributes live in a `GlobalStorage`'s mapping. Each layer may also already
  # be the thing we want, which is how a pickle written by another torch version
  # arrives — so the walk stops as soon as it has a map with `x` in it.
  defp graph_of(%Object{state: %{} = state}) when is_map_key(state, "_graph"),
    do: state |> Map.fetch!("_graph") |> graph_of()

  defp graph_of(%Object{state: %{} = state}) when is_map_key(state, "_store"),
    do: state |> Map.fetch!("_store") |> graph_of()

  defp graph_of(%Object{state: %{} = state}) when is_map_key(state, "_mapping"),
    do: state |> Map.fetch!("_mapping") |> graph_of()

  # Some releases hand the graph over already unwrapped: the object's own state
  # is the mapping, with no `_graph` or `_store` around it. A struct does not
  # match the plain-map clause below, so without this the whole export stops on
  # the first model written that way.
  defp graph_of(%Object{state: %{} = state}) when is_map_key(state, "x"), do: state

  defp graph_of(%{} = mapping) when is_map_key(mapping, "x"), do: mapping

  @doc "How a library is named in a report: the release, then the model."
  @spec label(String.t(), String.t()) :: String.t()
  def label(release, name), do: release <> "/" <> name

  @doc """
  Whether anything under `root` still has to be read.

  The question a page asks before it offers the work again, and a boot asks
  before it spends a minute exporting nothing: an extracted release whose
  libraries are here and newer than their pickles has nothing to do. A volume
  restored from a backup, or an archive unpacked by an older version of this
  application, is the case this exists for — the pickles are there and the
  memory a run reads is not, and nothing about the download said so.
  """
  @spec pending?(Path.t(), Path.t()) :: boolean()
  def pending?(root \\ models_root(), libraries \\ Memory.libraries_dir()) do
    Enum.any?(models(root), fn {release, name, pickle} ->
      not current?(Memory.path_for(name, release, libraries), pickle)
    end)
  end

  defp current?(out, pickle) do
    with {:ok, %File.Stat{mtime: written}} <- File.stat(out, time: :posix),
         {:ok, %File.Stat{mtime: exported}} <- File.stat(pickle, time: :posix) do
      written >= exported
    else
      _absent -> false
    end
  end
end
