defmodule Monty.Studio.Cad.Preparation do
  @moduledoc """
  A CAD part's two inputs, written from the part file the experiment names.

  Both are Monty's own formats, because both are read by Monty's own code: the
  memory is the library format (`<libraries>/<release>/<name>.jsonl.gz`) and the
  object set is the MuJoCo object directory
  (`<data_path>/<object>/{textured.obj,texture_map.png,metadata.json}`). Nothing
  here invents a format — the part file is the one input, and the same part
  answers both, which is what makes a memory and a mesh comparable at all.

  The geometry belongs to another package (`ex_monty_cad`), named at the call
  rather than aliased: a node without it says so instead of failing to compile,
  and a test drives the writer it is given.

  This is what `/prerequisites` runs as a build (`Monty.Prerequisites.Build`):
  the plan comes from the experiment — its `object_names`, its
  `model_name_or_path` and its environment's `data_path` — so a new part is a
  new config and no code.
  """

  alias ExTbpMonty.Cad.Objects
  alias Monty.Studio.{Memory, Setup}

  @trainer Module.concat(["MontyCad", "Training"])
  @exporter Module.concat(["MontyCad", "Export"])
  @library Module.concat(["MontyCad", "Library"])

  @typedoc """
  What preparing a part would write, and from what.

    * `part` — the object name the experiment steps (`object_names: [plate]`)
    * `step` — the file the geometry comes from
    * `name` and `release` — the memory's address, as the config names it
    * `labels` — what the memory holds: the part as one object, or one object
      per feature it is made of, which is what a `_features` memory promises
    * `memory` — the library file, whether or not it is there
    * `objects` — the directory the object set is written into
  """
  @type plan :: %{
          part: String.t(),
          step: Path.t(),
          name: String.t(),
          release: String.t(),
          labels: :part | :features,
          memory: Path.t(),
          objects: Path.t()
        }

  @doc """
  What `setup` needs writing, or the sentence that says why it cannot be.

  Reads only the experiment: its `object_names` say which object a run steps,
  `model_name_or_path` says which memory it loads, and the environment's
  `data_path` says where its objects live. A run of another world has nothing to
  plan, and says so.
  """
  @spec plan(Setup.t()) :: {:ok, plan()} | {:error, String.t()}
  def plan(%Setup{} = setup) do
    with {:ok, name, release} <- memory_of(setup),
         {:ok, part} <- part_of(setup, name),
         {:ok, step} <- step_of(part),
         {:ok, objects} <- objects_of(setup) do
      {:ok,
       %{
         part: part,
         step: step,
         name: name,
         release: release,
         labels: labels_of(name),
         memory: Memory.path_for(name, release),
         objects: objects
       }}
    end
  end

  # The part this plan is about, said by the memory's name. A memory of the whole
  # part is named after the object the run steps — `object_names: [plate]` — so
  # the experiment says it. A memory of the features is named `<part>_features`
  # and its objects are `<part>_<feature>`, so the part is the name without the
  # suffix: it is the thing the objects are made of, not one of them.
  defp part_of(setup, name) do
    case labels_of(name) do
      :features -> {:ok, String.replace_suffix(name, "_features", "")}
      :part -> object_of(setup)
    end
  end

  # A memory's name says what it holds, because nothing else can: `plate_part`
  # is the plate as one object, `plate_features` is the plate as the features it
  # is made of. Monty's config has no key for this — what a memory holds is what
  # its producer wrote — so the name is the statement, and this is the one place
  # that reads it.
  defp labels_of(name) do
    if String.ends_with?(name, "_features"), do: :features, else: :part
  end

  @doc """
  Writes the memory and the object set a plan describes.

  Answers what was written, so a page can say it rather than guess: the memory's
  path, the directory the objects went into, and how many objects there are.
  """
  @spec prepare(plan(), keyword()) ::
          {:ok, %{memory: Path.t(), objects: Path.t(), written: non_neg_integer()}}
          | {:error, String.t()}
  def prepare(%{} = plan, options \\ []) do
    with {:ok, nodes} <- write_memory(plan, Keyword.get(options, :trainer, @trainer)),
         {:ok, written} <- write_objects(plan, Keyword.get(options, :exporter, @exporter)) do
      {:ok, %{memory: plan.memory, objects: plan.objects, written: written, nodes: nodes}}
    end
  end

  # The memory is what the config names: one object for the whole part, or one
  # per feature. Both are the CAD package's teaching; what this application adds
  # is the second half of a feature memory's file, below.
  defp write_memory(plan, trainer) do
    if Code.ensure_loaded?(trainer) do
      with {:ok, written} <- taught(plan, trainer), do: names_it_answers_to(plan, written)
    else
      {:error,
       "#{inspect(trainer)} is not on this node: add `ex_monty_cad` to write a part's memory."}
    end
  end

  defp taught(plan, trainer) do
    case trainer.write_library([{plan.part, plan.step}], plan.memory, memory_options(plan)) do
      {:ok, written} -> {:ok, written}
      {:error, reason} -> {:error, "#{plan.step} could not be taught: #{inspect(reason)}"}
    end
  end

  # A memory of features is sampled much more finely than a memory of a part,
  # and has to be: the CAD package's default spacing is sized for a part, and a
  # feature is a fraction of one. At the default the plate's boss keeps 56 nodes
  # and its hole 16, which is a cylinder reproduced as a few rings of
  # quadrilaterals rather than as the surface it is — and a patch on it is as
  # wide as the whole feature. What limits a feature run at this size is scale,
  # not node count; the set's README has the measurement.
  #
  # The finer spacing alone is not enough — the visits are capped at 2 000, and
  # the plate's body and risers alone spend that budget, which deletes the small
  # features from the memory entirely. The cap is the plan's, so it is raised
  # with the spacing; at 1 mm the sampling converges below the raised cap
  # (20 000 and 60 000 teach the same memory), so the build costs a minute a part
  # rather than more.
  @feature_spacing 1.0
  @feature_visits 20_000

  defp memory_options(%{labels: :features}),
    do: [labels: :features, spacing: @feature_spacing, limit: @feature_visits]

  defp memory_options(%{labels: :part}), do: [labels: :part]

  # A part's memory is one object called `plate`, which a world steps as the
  # directory `plate`, so its file is written as the teaching left it. A memory
  # of features is one object per feature, and the CAD package names those
  # `plate/bosses/0` — the part, then the feature. A world steps one *directory*
  # per object, so the name a run answers with is that one with the separators
  # flattened, `plate_bosses_0`; the memory has to say the same, or a run steps
  # an object its memory has never heard of and finds nothing.
  #
  # The records written are the ones the teaching answered with: this is the
  # same file, with the one field a directory cannot carry renamed.
  defp names_it_answers_to(%{labels: :part}, written), do: {:ok, written.nodes}

  defp names_it_answers_to(%{memory: path}, written) do
    records =
      written.objects
      |> Enum.flat_map(& &1.records)
      |> Enum.map(&Map.update!(&1, "object_id", fn id -> Objects.object_name(id) end))

    case @library.write_records(records, path) do
      :ok -> {:ok, written.nodes}
      {:error, reason} -> {:error, "#{path} could not be written: #{inspect(reason)}"}
    end
  end

  # The object set is the same part as triangles, written where the config's
  # `data_path` looks — one directory per object the memory holds.
  defp write_objects(plan, exporter) do
    if Code.ensure_loaded?(exporter) do
      if plan.labels == :features,
        do: feature_objects(plan, exporter),
        else: part_object(plan, exporter)
    else
      {:error,
       "#{inspect(exporter)} is not on this node: add `ex_monty_cad` to write a part's meshes."}
    end
  end

  defp part_object(plan, exporter) do
    with {:ok, mesh} <- exporter.part_mesh(plan.step, name: plan.part) do
      _written = Objects.write_mesh(mesh, plan.objects)
      {:ok, 1}
    end
  end

  # One object per feature, under the name the memory answers to: the exporter
  # calls the plate's first boss `bosses/0`, and its object is
  # `plate_bosses_0`.
  defp feature_objects(plan, exporter) do
    with {:ok, meshes} <- exporter.feature_meshes(plan.step) do
      {:ok, length(Enum.map(meshes, &Objects.write_mesh(named_for_part(plan, &1), plan.objects)))}
    end
  end

  defp named_for_part(plan, mesh), do: %{mesh | name: "#{plan.part}/#{mesh.name}"}

  defp object_of(setup) do
    case Setup.objects(setup) do
      [part | _rest] when is_binary(part) and part != "" -> {:ok, part}
      _none -> {:error, "this experiment names no object to prepare"}
    end
  end

  # The part file is named for the object, the way Monty's object sets are named
  # for the objects they hold; the parts directory is where the file lives.
  defp step_of(part) do
    case Enum.find(Setup.cad_parts(), &(Path.rootname(&1) == part)) do
      nil ->
        {:error,
         "there is no part #{inspect(part)}: #{Enum.join(Setup.parts_dirs(), " and ")} hold " <>
           inspect(Setup.cad_parts())}

      file ->
        {:ok, path_of(file)}
    end
  end

  defp path_of(file) do
    Enum.find_value(Setup.parts_dirs(), fn dir -> regular(Path.join(dir, file)) end) ||
      Path.expand(file)
  end

  defp regular(path), do: if(File.regular?(path), do: path)

  defp memory_of(setup) do
    case setup.model_name_or_path do
      path when is_binary(path) and path != "" ->
        {:ok, Path.basename(path), path |> Path.dirname() |> Path.basename()}

      _none ->
        {:error, "this experiment names no memory to write: `model_name_or_path` is empty"}
    end
  end

  defp objects_of(%Setup{environment: %{data_path: path}}) when is_binary(path), do: {:ok, path}
  defp objects_of(_setup), do: {:error, "this experiment's environment has no data path"}
end
