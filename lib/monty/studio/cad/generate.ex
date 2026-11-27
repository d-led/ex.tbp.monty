defmodule Monty.Studio.Cad.Generate do
  @moduledoc """
  A part a person brought, written down as the experiment that runs it.

  This is the second half of bringing a part: `Monty.Studio.Cad.Parts` puts the
  file where the worlds look, and this writes the two config files that make it
  runnable — an `env_interface` naming the part's own object, and an experiment
  whose memory is `<part>_part`, the name the Make click teaches
  (`Monty.Prerequisites.Build` plans from the experiments it can read, and
  `Monty.Studio.Cad.Preparation` reads this one exactly as it reads a shipped
  set's).

  Nothing here invents a config. The experiment is the studio's own
  `Monty.Studio.Blueprint` on top of `cad/plate_part_eval` — the shipped
  experiment whose answer is known (three of three episodes, part-level) — with
  three choices changed: its name, its memory, and the interface that names the
  object. The world, the sensors, the policy and the termination stay the base's,
  because a generated run that differs in anything else would not be comparable
  with the one it was generated from.

  A generated set is a directory under the sets root, `brought/conf`, so it is a
  config root like every other set (`Monty.Config.Source.extra_conf_dirs/0`
  globs them) — the experiment appears on `/experiments` and in the builder with
  no further wiring. Nothing is written outside it, and writing the same part
  again produces the same two files.
  """

  alias Monty.Config.Source
  alias Monty.Studio.Blueprint
  alias Monty.Studio.Cad.Parts
  alias Monty.Studio.Catalog
  alias Monty.Studio.Memory

  # What a memory can hold, and the shipped experiment each arm is modelled on.
  # Two answers because the pipeline has two: the whole part as one object (the
  # arm whose answer is known), and one object per feature the recognition found
  # (the arm the compositional question needs). A run that differs from its arm in
  # anything else would not be comparable with the one it was generated from.
  @labels [:part, :features]
  @bases %{
    part: "cad/plate_part_eval",
    features: "cad/plate_features_eval"
  }

  # The folder a generated section's experiments sit in, which is the same one
  # the shipped CAD experiments use: the address and the file are one name.
  @folder "cad"

  # What a generated set is called, in the sets root.
  @set "brought"

  @doc "The folder a set's CAD experiments sit in, which is part of their name."
  @spec folder() :: String.t()
  def folder, do: @folder

  @typedoc """
  The experiment a part became, and the files it was written as.

  `files` has the experiment first, which is the one a person would open.
  """
  @type generated :: %{
          experiment: String.t(),
          part: String.t(),
          labels: :part | :features,
          objects: pos_integer(),
          files: [Path.t()]
        }

  @doc "The root the CAD sets live in: the shipped ones and the generated ones."
  @spec sets_dir() :: Path.t()
  def sets_dir do
    Application.get_env(:ex_tbp_monty, :cad_sets_dir) ||
      Path.join(Monty.Paths.data(), "sets")
  end

  @doc """
  The config roots a generated set is read through.

  A generated experiment composes against its own set first and the shipped tree
  behind it, which is the overlay every set is read with
  (`Monty.Config.Source.load/3`). The same list is what a page opens the
  experiment with, so "generated" and "openable" are one question.
  """
  @spec conf_dirs(Path.t()) :: [Path.t()]
  def conf_dirs(sets \\ sets_dir()), do: [Path.join([sets, @set, "conf"]) | Source.conf_dirs()]

  @doc """
  Writes the part's experiment and the interface that names its objects.

  `labels` is what the memory holds, and there are two answers because the
  pipeline has two: `:part` is the whole part as one object (the arm whose answer
  is known), `:features` is one object per feature the recognition found (the arm
  the compositional question needs). A label this module does not have is refused
  here, where the option arrives, so nothing further has to re-check it.

  Refuses — before writing anything — a part no file answers, an arm that already
  has an experiment (a generated set is read *before* the shipped ones, so a
  second one would shadow a measured experiment with a copy of itself), and a
  config the studio would not compose: a config this module cannot read back is
  not one a person should be given.
  """
  @spec generate(String.t(), keyword()) :: {:ok, generated()} | {:error, String.t()}
  def generate(part, opts \\ []) do
    labels = Keyword.get(opts, :labels, :part)

    if labels in @labels do
      write_experiment(part, labels, Keyword.get_lazy(opts, :sets, &sets_dir/0))
    else
      {:error, "a run of a part is :part or :features, not #{inspect(labels)}"}
    end
  end

  defp write_experiment(part, labels, sets) do
    blueprint = blueprint(part, labels)

    with {:ok, _named} <- Parts.find(part),
         :ok <- unclaimed(part, labels, sets),
         {:ok, interface, objects} <- interface(part, labels),
         :ok <- write(environment_path(part, labels, sets), interface),
         :ok <- nothing_wrong(blueprint, conf_dirs(sets)),
         {:ok, _composed} <- Blueprint.compose(blueprint, conf_dir: conf_dirs(sets)),
         :ok <- write(experiment_path(part, labels, sets), Blueprint.to_yaml(blueprint)) do
      {:ok,
       %{
         experiment: blueprint.name,
         part: part,
         labels: labels,
         objects: length(objects),
         files: [experiment_path(part, labels, sets), environment_path(part, labels, sets)]
       }}
    end
  end

  @doc """
  The experiment a part already runs, or `nil`.

  A page asks this before it offers to generate one: a part with a run is a link
  to that run, not a second experiment of the same name.
  """
  @spec experiment_for(String.t(), :part | :features, Path.t()) :: String.t() | nil
  def experiment_for(part, labels \\ :part, sets \\ sets_dir()) do
    name = experiment_name(part, labels)

    case Catalog.experiment(name, conf_dir: conf_dirs(sets)) do
      nil -> nil
      _experiment -> name
    end
  end

  @doc """
  The memories the parts a person brought need, by path.

  One file per brought part, each naming its own memory; a page that says "the
  same Make writes these" needs the names and not a composed plan, so this is one
  small read per part rather than a compose of every experiment on the machine.
  """
  @spec memories(Path.t()) :: [Path.t()]
  def memories(sets \\ sets_dir()) do
    Path.join([sets, "*", "conf", "experiment", @folder, "*.yaml"])
    |> Path.wildcard()
    |> Enum.flat_map(&memory_in/1)
  end

  # The memory is the one thing a generated experiment always names (the part had
  # to exist for it to be written), so a file without one is not one of ours. The
  # path is `Monty.Studio.Memory`'s, which is the one the build writes to; the
  # config names the last two segments (release and memory) and the deployment
  # supplies the root.
  defp memory_in(file) do
    with {:ok, config} <- Source.load_file(file),
         value when is_binary(value) <-
           get_in(config.body, ["experiment", "config", "model_name_or_path"]),
         [release, name] <- value |> String.split("/", trim: true) |> Enum.take(-2) do
      [Memory.path_for(name, release)]
    else
      _no_memory -> []
    end
  end

  # The generated file is this module's own: a second click rewrites it, which is
  # the same state. Anything else of that name is a shipped experiment and a
  # generated copy would be read before it.
  defp unclaimed(part, labels, sets) do
    case {File.exists?(experiment_path(part, labels, sets)), experiment_for(part, labels, sets)} do
      {true, _ours} ->
        :ok

      {false, nil} ->
        :ok

      {false, name} ->
        {:error,
         "#{name} is already an experiment here — #{part} already has this run. " <>
           "Open that one instead of making a second."}
    end
  end

  # The arm's shipped experiment with the three choices a part decides: its own
  # name, the memory a build teaches for it, and the interface that steps its
  # objects. The memory keeps the base's resolver — where libraries live is the
  # deployment's answer, not a generated file's.
  defp blueprint(part, labels) do
    base = Blueprint.from_experiment(@bases[labels])

    base
    |> Blueprint.put_name(experiment_name(part, labels))
    # The address has a folder in it; a run's name is one file name, as the
    # shipped experiments' are (`run_name: cad_plate_part_eval`).
    |> Blueprint.put_config(
      "logging",
      Map.put(base.config["logging"], "run_name", "#{part}_#{labels}_eval")
    )
    |> Blueprint.put_group("env_interface", interface_name(part, labels))
    |> Blueprint.put_config("model_name_or_path", memory_of(base, part, labels))
  end

  defp experiment_name(part, labels), do: "#{@folder}/#{part}_#{labels}_eval"
  defp interface_name(part, labels), do: "cad_#{part}_#{labels}_eval"

  # `Monty.Studio.Cad.Preparation` reads what a memory holds off its name
  # (`<part>_part`, `<part>_features`), so the suffix is the statement.
  defp memory_of(blueprint, part, labels) do
    blueprint.config["model_name_or_path"]
    |> Path.dirname()
    |> Path.join("#{part}_#{labels}")
  end

  defp experiment_path(part, labels, sets) do
    path(sets, ["experiment", @folder], "#{part}_#{labels}_eval")
  end

  defp environment_path(part, labels, sets) do
    path(sets, "env_interface", interface_name(part, labels))
  end

  # The objects the run steps, from the same place the build gets them: the
  # part's own name, or one object per feature (`Monty.Studio.Cad.Parts`).
  defp interface(part, labels) do
    case Parts.objects(part, labels) do
      {:ok, objects} -> {:ok, env_interface(part, labels, objects), objects}
      {:error, _sentence} = refused -> refused
    end
  end

  defp env_interface(part, labels, objects) do
    """
    # @package experiment.config
    # #{part}, as #{what(labels)}, in the world the memory taught from its STEP
    # file is compared against. Written by the CAD page from the recognition's own
    # objects; `object_names` is what the memory answers with.
    do_eval: true
    eval_env_interface_args:
      object_names:
    #{Enum.map_join(objects, "\n", &"    - #{&1}")}
      object_init_sampler:
        _target_: tbp.monty.frameworks.environments.object_init_samplers.Predefined
        rotations: ${constants.rotations_3}
    eval_env_interface_class: ${monty.class:tbp.monty.experiment.environment.OneObjectPerEpisodeInterface}
    """
  end

  defp what(:part), do: "the mesh the build writes from it"
  defp what(:features), do: "one mesh per feature the recognition found"

  defp nothing_wrong(blueprint, conf) do
    blueprint
    |> Blueprint.findings(conf_dir: conf)
    # The name is the part's own, checked where the part came in, and it is this
    # module that names the file — an experiment's *address* carries a folder
    # (`cad/bracket_part_eval`), which a draft's file name may not.
    |> Enum.reject(&(&1.where == "name"))
    |> Enum.filter(&(&1.level == :error))
    |> case do
      [] -> :ok
      errors -> {:error, Enum.map_join(errors, " ", & &1.message)}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The path is `path/3`'s, built from the sets root and a part name
  # `Monty.Studio.Cad.Parts` already checked; nothing here is a request's.
  defp write(path, text) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, text) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{path} could not be written: #{:file.format_error(reason)}"}
    end
  end

  # A file's name under the generated set's `conf/`: the group's folders as a
  # list, so `experiment/cad` stays two segments rather than a name with a slash
  # in it. (`Path.join/1` does not descend into a nested list — it would build
  # `experimentcad` — so the segments are spliced, not wrapped.)
  defp path(sets, group, name) do
    ([sets, @set, "conf"] ++ List.wrap(group) ++ ["#{name}.yaml"])
    |> Path.join()
  end
end
