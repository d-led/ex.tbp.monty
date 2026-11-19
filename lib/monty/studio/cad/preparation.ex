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
  alias Monty.Studio.Cad.Taught
  alias Monty.Studio.{Failure, Memory, Setup}

  @trainer Module.concat(["MontyCad", "Training"])
  @exporter Module.concat(["MontyCad", "Export"])
  @library Module.concat(["MontyCad", "Library"])

  # What a run that names neither a camera nor a stand-off is taught with: the
  # tutorial's `zoom: 10` on a square patch, which reads 11.42°
  # (`2·atan2(tan(45°), 10)`), and the eight millimetres a feature experiment
  # stands off by. A CAD experiment names both, and `optics/1` reads them.
  @default_fov 11.42 * :math.pi() / 180.0
  @default_stand_off 8.0

  @typedoc """
  What preparing a part would write, and from what.

    * `part` and `step` — the first part's name and the file its geometry comes
      from
    * `parts` — every part the plan teaches, as `{object name, STEP file}`: one for
      a memory of one part, and one per object the experiment names for a memory of
      several (`parts_set`)
    * `name` and `release` — the memory's address, as the config names it
    * `labels` — what the memory holds: the part as one object, one object per
      feature it is made of, which is what a `_features` memory promises, or each
      part of a set as itself
    * `optics` — the run's patch: its horizontal field of view in radians and
      the distance it stands off the surface in millimetres, which are the two
      numbers the teaching camera takes
    * `memory` — the library file, whether or not it is there
    * `objects` — the directory the object set is written into
  """
  @type plan :: %{
          part: String.t(),
          step: Path.t(),
          parts: [{String.t(), Path.t()}],
          name: String.t(),
          release: String.t(),
          labels: :part | :features | :set,
          optics: %{fov_x: float(), distance: float()},
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
         {:ok, parts} <- parts_of(setup, name),
         {:ok, objects} <- objects_of(setup) do
      {:ok,
       %{
         part: elem(hd(parts), 0),
         step: elem(hd(parts), 1),
         parts: parts,
         name: name,
         release: release,
         labels: labels_of(name),
         optics: optics(setup),
         memory: Memory.path_for(name, release),
         objects: objects
       }}
    end
  end

  # What the run's patch reads through, and from how far: the two numbers a
  # memory is a record of. Both are the experiment's, not this module's — a run
  # taught through a different lens, or from a different distance, matches a
  # surface it was never shown (`MontyCad.Training` documents the same rule for
  # its own options).
  defp optics(setup) do
    %{fov_x: fov_of(setup), distance: stand_off_of(setup)}
  end

  # Monty's `zoom_fovy/3`: an agent takes a resolution and a zoom over a 90° base,
  # so the patch's vertical field of view is
  # `2·atan2(ratio·tan(hfov/2), zoom)`. A square patch reads the same number
  # across and down, which is the one the teaching camera takes as `:fov_x`.
  defp fov_of(setup) do
    case Map.get(setup.cameras, "patch") do
      [resolution: {width, height}, zoom: zoom, hfov: hfov]
      when is_number(zoom) and zoom > 0 ->
        base = hfov * :math.pi() / 180.0
        2 * :math.atan2(width / height * :math.tan(base / 2), zoom)

      _no_camera ->
        @default_fov
    end
  end

  # The policy's `desired_object_distance`, in metres, is the distance a run
  # stands off the surface; the teaching camera takes millimetres.
  defp stand_off_of(setup) do
    case get_in(setup.motor_system_config, [
           "policy_selector",
           "policy",
           "desired_object_distance"
         ]) do
      metres when is_number(metres) and metres > 0 -> metres * 1000.0
      _unnamed -> @default_stand_off
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

  # The parts a plan teaches, each with the file it comes from.
  #
  # One for a memory of one part. For a memory of several — `parts_set`, which is
  # a name ending in `_set`, the same way `_features` says what it holds — one per
  # object the experiment names, because that list *is* the set. The CAD package
  # takes them in one call and writes one file, which is what makes it a memory of
  # several parts rather than several memories.
  defp parts_of(setup, name) do
    if labels_of(name) == :set,
      do: every_part(setup),
      else: one_part(setup, name)
  end

  defp one_part(setup, name) do
    with {:ok, part} <- part_of(setup, name),
         {:ok, step} <- step_of(part),
         do: {:ok, [{part, step}]}
  end

  defp every_part(setup) do
    setup
    |> Setup.objects()
    |> Enum.reduce_while({:ok, []}, fn object, {:ok, parts} ->
      case step_of(object) do
        {:ok, step} -> {:cont, {:ok, [{object, step} | parts]}}
        {:error, _sentence} = refused -> {:halt, refused}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "this experiment names no object to prepare"}
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, _sentence} = refused -> refused
    end
  end

  # A memory's name says what it holds, because nothing else can: `plate_part`
  # is the plate as one object, `plate_features` is the plate as the features it
  # is made of, and `parts_set` is several parts as themselves. Monty's config has
  # no key for this — what a memory holds is what its producer wrote — so the name
  # is the statement, and this is the one place that reads it.
  defp labels_of(name) do
    cond do
      String.ends_with?(name, "_features") -> :features
      String.ends_with?(name, "_set") -> :set
      true -> :part
    end
  end

  @doc """
  Writes the memory and the object set a plan describes.

  Answers what was written, so a page can say it rather than guess: the memory's
  path, the directory the objects went into, how many objects there are, and
  whether the memory had to be taught — `taught: :before` means the part file,
  the optics and the sampling behind it are the ones it was already written
  from, which is what makes a second Make click cost seconds instead of the
  twelve minutes the first one does (`Monty.Studio.Cad.Taught` keeps that
  record).

  The meshes are always written: they are seconds of work, and they are the half
  of a build a run notices first when it is missing.
  """
  @spec prepare(plan(), keyword()) ::
          {:ok,
           %{
             memory: Path.t(),
             objects: Path.t(),
             written: non_neg_integer(),
             nodes: non_neg_integer(),
             taught: :now | :before
           }}
          | {:error, String.t()}
  def prepare(%{} = plan, options \\ []) do
    trainer = Keyword.get(options, :trainer, @trainer)
    fingerprint = fingerprint(plan, trainer)

    with {:ok, nodes, taught} <- memory(plan, trainer, fingerprint),
         {:ok, written} <- write_objects(plan, Keyword.get(options, :exporter, @exporter)) do
      {:ok,
       %{
         memory: plan.memory,
         objects: plan.objects,
         written: written,
         nodes: nodes,
         taught: taught
       }}
    end
  end

  # A memory the same inputs already produced is left alone; anything else is
  # taught, and what it was taught from is kept beside it — written after the
  # memory itself succeeds, so a failed build never records one.
  defp memory(plan, trainer, fingerprint) do
    case Taught.read(plan.memory) do
      {:ok, %{fingerprint: ^fingerprint, nodes: nodes}} ->
        {:ok, nodes, :before}

      _taught_from_something_else ->
        with {:ok, nodes} <- write_memory(plan, trainer),
             :ok <- Taught.remember(plan.memory, %{fingerprint: fingerprint, nodes: nodes}) do
          {:ok, nodes, :now}
        end
    end
  end

  # What the memory is a function of, as one string: the bytes of every part file
  # it is taught from, the sampler's own answers (spacing, visit cap, lens,
  # stand-off, what is labelled), the writer, and the packages whose code turns
  # those into a file. `@taught_format` is this module's own share of it — a
  # change to *how* a memory is written, or to what is hashed here, has to be able
  # to say so, and no input above would move.
  #
  # The files' *paths* are not in it: `_build/dev` and `_build/test` hold the same
  # bytes under different paths, so a path would make a memory taught by a test
  # read as stale to the page — which is how this was found, on the page, with the
  # note that build had just written.
  @taught_format 2

  @doc """
  Whether the memory on disk was taught from what this plan would teach from now.

  `:none` when there is no memory or no note beside it — absence is
  `Monty.Studio.Setup.memory_findings/1`'s to report — `:current` when the note
  names the fingerprint this plan would write now, and `{:other_inputs, at}` when
  it was written from something else. That last answer is the one a page can act
  on: a config whose stand-off or lens changed after the memory was taught reads
  a surface the memory was never taught, which is a defect no reading of the
  files shows and a comparison does.
  """
  @spec staleness(plan(), module()) :: :none | :current | {:other_inputs, String.t()}
  def staleness(%{} = plan, trainer \\ @trainer) do
    case Taught.read(plan.memory) do
      :none ->
        :none

      {:ok, %{fingerprint: recorded, at: at}} ->
        if recorded == fingerprint(plan, trainer), do: :current, else: {:other_inputs, at}
    end
  end

  defp fingerprint(plan, trainer) do
    inputs = {memory_options(plan), trainer, @taught_format, packages()}
    parts = {Enum.map(plan.parts, fn {object, step} -> {object, digest(step)} end), inputs}

    parts
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A part file that is gone is part of the fingerprint too: the memory cannot be
  # said to match a file nobody can read.
  # sobelow_skip ["Traversal.FileModule"]
  # The path is the one the config names (`step_of/1`), not a request's.
  defp digest(step) do
    case File.read(step) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _reason} -> :absent
    end
  end

  defp packages do
    for app <- [:ex_monty_cad, :ex_quiddity], do: {app, Application.spec(app, :vsn)}
  end

  # The memory is what the config names: one object for the whole part, or one
  # per feature. Both are the CAD package's teaching; what this application adds
  # is the second half of a feature memory's file, below.
  defp write_memory(plan, trainer) do
    if Code.ensure_loaded?(trainer) do
      with {:ok, written} <- taught(plan, trainer), do: names_it_answers_to(plan, written)
    else
      # No module name in the sentence: a person reads "the CAD package is not
      # here and this is how to add it", not `Elixir.MontyCad.Trainer`.
      {:error,
       "the CAD package is not on this node, so a part's memory cannot be written: " <>
         "add `ex_monty_cad` to this build."}
    end
  end

  defp taught(plan, trainer) do
    case trainer.write_library(plan.parts, plan.memory, memory_options(plan)) do
      {:ok, written} ->
        {:ok, written}

      {:error, reason} ->
        {:error, "#{Path.basename(plan.step)} could not be taught: #{Failure.sentence(reason)}"}
    end
  end

  # A memory of features is sampled more finely than the CAD package's dial, and
  # has to be: that dial is sized for a part, and a feature is a fraction of one.
  # At the default the plate's boss keeps 56 nodes and its hole 16, which is a
  # cylinder reproduced as a few rings of quadrilaterals rather than as the
  # surface it is — and a patch on it is as wide as the whole feature. What limits
  # a feature run at this size is scale, not node count; the set's README has the
  # measurement.
  #
  # The finer spacing alone is not enough — the visits are capped at 2 000, and
  # the plate's body and risers alone spend that budget, which deletes the small
  # features from the memory entirely. The cap is the plan's, so it is raised
  # with the spacing; at 1 mm the sampling converges below the raised cap
  # (20 000 and 60 000 teach the same memory), so the build costs a minute a part
  # rather than more.
  @feature_spacing 1.0
  @feature_visits 20_000

  # A part's memory is sampled for the run's patch too, and this is the number
  # that decides it. The CAD package's own dial is thirty samples across the
  # part's largest extent, which is 2 mm on the plate and 9 mm on `blend-big` —
  # and a graph whose nodes are nine millimetres apart cannot be matched by a
  # five-millimetre patch. Measured on this Mac: `blend-big` taught at the
  # package's spacing keeps 35 nodes and its episode reaches evidence 4.37; taught
  # at a third of the patch's width it keeps 1424 and reaches 9.91. The visit cap
  # is raised beside it for the same reason the feature cap is: at a finer spacing
  # the surface has more samples than the package's 2 000.
  @nodes_across_a_patch 3
  @part_visits 20_000

  defp memory_options(%{labels: :features} = plan) do
    [labels: :features, spacing: @feature_spacing, limit: @feature_visits]
    |> Keyword.merge(optics_options(plan))
  end

  defp memory_options(%{labels: labels} = plan) when labels in [:part, :set] do
    [
      # The CAD package names objects after what it teaches and knows two
      # answers: the part as itself, or the features it is made of. A set is the
      # first, applied to every part it was handed — the memory then holds
      # `plate` and `blend` as their own objects, which is what the experiment's
      # `object_names` list.
      labels: :part,
      spacing: patch_width(plan.optics) / @nodes_across_a_patch,
      limit: @part_visits
    ]
    |> Keyword.merge(optics_options(plan))
  end

  # How much surface one percept covers, across: the patch's field of view at the
  # distance it stands off by.
  defp patch_width(%{fov_x: fov_x, distance: distance}),
    do: 2 * distance * :math.tan(fov_x / 2)

  # A part's memory is taught through the same lens and from the same distance as
  # a feature's: it is the *run's* patch either way, and a memory of the plate
  # photographed through the CAD package's own 66° default is a memory of a
  # surface the run never sees in one percept.
  defp optics_options(%{optics: %{fov_x: fov_x, distance: distance}}),
    do: [fov_x: fov_x, distance: distance]

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
  defp names_it_answers_to(%{labels: labels}, written) when labels in [:part, :set],
    do: {:ok, written.nodes}

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
    cond do
      not Code.ensure_loaded?(exporter) ->
        {:error,
         "#{inspect(exporter)} is not on this node: add `ex_monty_cad` to write a part's meshes."}

      plan.labels == :features ->
        feature_objects(plan, exporter)

      plan.labels == :set ->
        set_objects(plan, exporter)

      true ->
        part_object(plan, exporter)
    end
  end

  # One directory per part, each under the name the memory answers with — which
  # for a set is the part's own name, because that is what the experiment lists in
  # `object_names` and what the memory's records already say.
  defp set_objects(plan, exporter) do
    plan.parts
    |> Enum.reduce_while({:ok, 0}, fn {part, step}, {:ok, written} ->
      case exporter.part_mesh(step, name: part) do
        {:ok, mesh} ->
          _written = Objects.write_mesh(mesh, plan.objects)
          {:cont, {:ok, written + 1}}

        {:error, _reason} = refused ->
          {:halt, refused}
      end
    end)
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
