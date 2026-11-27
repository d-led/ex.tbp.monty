defmodule Monty.Studio.Catalog do
  @moduledoc """
  What Monty offers an experiment builder: the experiments it ships, the
  choices each group has, and a few honest starting points.

  Nothing here invents a component. Every suggestion is a group option that
  exists in Monty's `conf/` tree, so a config built from the studio composes
  against Monty's own groups and could be run by Monty unchanged.

  Only the file headers are read — a defaults list, not a composed tree — so
  listing every experiment is cheap enough to do on a page load.
  """

  alias ExTbpMonty.Cluster.Nodes
  alias Monty.Config.Source

  # The groups that shape *what runs*: the model's modules and the corpus it is
  # trained on. Monty's `env_interface`, `positioning_procedures` and
  # `transform` groups are experiment plumbing; a builder picks them from the
  # base experiment rather than inventing them.
  @groups ~w(
    environment
    monty
    monty/sensor_module
    monty/learning_module
    monty/connectivity
    monty/motor_system_config
    termination
    telemetry
  )

  # Starting points are experiments Monty ships, named as Monty names them. The
  # list is a list of names and nothing else: a card built from these shows the
  # config's own `defaults:` list, because that is what the source says about it.
  # Anything else — "the shape most benchmarks use", "the simplest one" — is this
  # studio's opinion, and it has no business being on a page about Monty's own
  # configurations.
  # Every name here has to run in this application *and* in the world it steps by
  # default: a template is a suggestion, and suggesting one that is refused would
  # be suggesting a run that does not start. `tutorial/first_experiment` is
  # Monty's own first tutorial and its classes are written here now, but it is
  # supervised and the stand-in scene cannot state a target — so it belongs in
  # the list, where its readiness is shown, and not in a starting point that has
  # to work wherever this page is served.
  @templates [
    "base_config_10distinctobj_dist_agent",
    "randrot_noise_10distinctobj_5lms_dist_agent"
  ]

  @type experiment :: %{
          name: String.t(),
          groups: %{optional(String.t()) => String.t()},
          experiment_class: String.t() | nil,
          config: map()
        }

  @doc "The groups a builder chooses between."
  @spec groups() :: [String.t()]
  def groups, do: @groups

  @doc "Experiments to start from, named as Monty names them."
  @spec templates() :: [String.t()]
  def templates, do: @templates

  @doc """
  Every config root this studio reads, in the order that decides who wins.

  Monty's mirror and the sets the application ships, then the sets a person
  generated — under the data root, because they are the application's output and
  the source tree holds sources. A generated name therefore never shadows a
  shipped experiment, which is the order `Monty.Studio.Cad.Generate` refuses to
  create a collision for anyway.

  Everything that lists or opens an experiment defaults to this list, so a
  generated part's run appears on `/experiments` and its page opens, without
  either one knowing that generated sets exist.
  """
  @spec conf_dirs() :: [Path.t()]
  def conf_dirs, do: Source.conf_dirs() ++ generated()

  # A generated set is written to the data folder (`Monty.Studio.Cad.Generate`),
  # so this asks the data root rather than listing the source tree.
  defp generated do
    Monty.Paths.data()
    |> Path.join("sets/*/conf")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
  end

  @doc """
  Every experiment Monty ships, with the choices its defaults list made and the
  few `experiment.config` values a list needs.

  Reading the file rather than composing it means a name that fails to compose
  still appears here, and that listing a hundred experiments is a hundred small
  reads; composing is what the setup view does, one experiment at a time.

  Those reads cost 210 YAML parses, and a LiveView mounts twice for one page —
  the static render, then the socket join — so the list is answered from a
  cache. It is a snapshot of a Monty checkout: the only thing that changes it is
  `mix monty.inputs`, which moves the stamp below.
  """
  @spec experiments(keyword()) :: [experiment()]
  def experiments(opts \\ []) do
    conf_dir = conf_dir(opts)

    case directory_stamp(conf_dir) do
      nil -> read(conf_dir)
      stamp -> cached({__MODULE__, :experiments, stamp}, fn -> read(conf_dir) end)
    end
  end

  @doc """
  The experiments this **cluster** offers that no config here defines: what the
  plugin hosts bring.

  A plugin experiment is defined by the plugin, so nothing about it is copied into
  this catalogue: `Monty.Studio.PluginExperiment.open/2` asks the host that
  defined it, and a plugin that changes its definition is never a stale entry
  here. This list says *what exists and where*, which is what a page needs to show
  it and what a person needs to find it instead of knowing its name beforehand.

  The names arrive free with the cluster poll — a plugin host answers
  `MontyPlugin.Registry.identity/0` from its own `:pg` (`ExTbpMonty.Cluster.Nodes`
  carries `plugins` per entry) — so listing them costs no message and no registry
  of our own. An experiment this node's own configs define wins over a plugin's:
  two things of one name is one experiment, and the config here is the one a
  reader can read.
  """
  @spec plugin_experiments(keyword()) :: [%{name: String.t(), host: String.t(), node: node()}]
  def plugin_experiments(opts \\ []) do
    ours = MapSet.new(experiments(opts), & &1.name)

    Nodes.snapshot()
    |> Enum.flat_map(fn entry ->
      for %{"kind" => "experiment", "name" => name} <- entry.plugins,
          not MapSet.member?(ours, name),
          do: %{name: name, host: entry.name, node: entry.node}
    end)
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  What a cache of anything derived from the catalogue must be keyed on: when the
  experiment directory was last written, and how many configurations it holds.
  `nil` when there is no directory to read.
  """
  @spec stamp(keyword()) :: term() | nil
  def stamp(opts \\ []), do: directory_stamp(conf_dir(opts))

  defp read(conf_dir) do
    conf_dir
    |> Source.experiments()
    |> Enum.map(&experiment_from(&1, conf_dir))
    |> Enum.reject(&(is_nil(&1) or fragment?(&1)))
  end

  # A file under `conf/experiment` is not always an experiment. Monty's own tests
  # compose the environment, sensor-module and learning-module groups from files
  # that live there and name no experiment class — seven of them. A configuration
  # with no class to run is a piece of one, so it is not counted, offered or
  # refused: refusing it would be inventing an experiment to say it cannot run,
  # which is what `epochs_not_a_count` used to say about a file that has no
  # epochs because it has no experiment.
  defp fragment?(%{experiment_class: nil}), do: true
  defp fragment?(_experiment), do: false

  # When a root was last written, and how many configs it holds: a copy that is
  # replaced, added to or trimmed moves one of the two. Every root is stamped,
  # because a list of roots is an overlay — adding an experiment of ours has to
  # invalidate the cache as surely as a `mix monty.inputs` does, and a stamp of
  # Monty's tree alone would serve the list from before our file existed.
  #
  # Recursive, because an experiment's name is its path relative to `experiment`
  # (`dogs/inference_paired`), so a new one is often a file in a directory that
  # already existed — a stamp of bare `*.yaml` would not see it.
  defp directory_stamp(conf_dirs) do
    stamps = conf_dirs |> Source.roots() |> Enum.flat_map(&stamp_of/1)

    if stamps == [], do: nil, else: stamps
  end

  defp stamp_of(root) do
    names = Path.join(root, "experiment/**/*.yaml") |> Path.wildcard()

    case names do
      [] ->
        []

      names ->
        written_at =
          names
          |> Enum.map(fn name ->
            {:ok, %File.Stat{mtime: mtime}} = File.stat(name, time: :posix)
            mtime
          end)
          |> Enum.max()

        [{root, written_at, length(names)}]
    end
  end

  defp cached(key, fun) do
    case :persistent_term.get(key, nil) do
      nil ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  @doc "One experiment's choices, or `nil` when the file cannot be read."
  @spec experiment(String.t(), keyword()) :: experiment() | nil
  def experiment(name, opts \\ []) do
    experiment_from(name, conf_dir(opts))
  end

  @doc """
  The experiment that writes the memory of this name, if the catalogue has it.

  A training run files what it learned under its own `run_name` (see
  `Monty.Studio.Learned`), so a config that reads `surf_agent_1lm_2obj_train` is
  waiting for the run named `surf_agent_1lm_2obj_train` — `tutorial/surf_agent_2obj_train`,
  whose file is not called that. Matching the *file* name against the memory
  would answer "nothing trains this" about a memory one press would produce.

  The run name is the evidence, and it is the only evidence a catalogue entry
  can offer: what makes an experiment train is its composed phases, and a list of
  two hundred entries does not compose two hundred configs to answer one
  question. A name two experiments share answers with the first of them, which is
  what a reader pressing the button would have chosen anyway.
  """
  @spec trainer_for(String.t() | nil, keyword()) :: String.t() | nil
  def trainer_for(name, opts \\ [])

  def trainer_for(nil, _opts), do: nil
  def trainer_for(name, _opts) when not is_binary(name), do: nil

  def trainer_for(name, opts) do
    experiments(opts)
    |> Enum.find(&(run_name(&1) == name))
    |> then(&(&1 && &1.name))
  end

  defp run_name(%{config: config}) do
    case Map.get(config, "logging") do
      %{"run_name" => name} when is_binary(name) and name != "" -> name
      _unnamed -> nil
    end
  end

  @doc """
  The options a group offers, sorted.

  `monty/learning_module/hypotheses_updater` and its siblings live one level
  below the groups a builder picks, so they are not listed; asking for a name
  that is not a group returns `[]` rather than reaching elsewhere in the tree.
  """
  @spec options(String.t(), keyword()) :: [String.t()]
  def options(group, opts \\ []) do
    if group in @groups do
      # Every root, deduped: a group an experiment of ours adds an option to is a
      # choice the builder must offer, and one both trees hold is one choice.
      conf_dir(opts)
      |> Source.roots()
      |> Enum.flat_map(fn root -> Path.wildcard(Path.join([root, group, "*.yaml"])) end)
      |> Enum.map(&Path.basename(&1, ".yaml"))
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  defp experiment_from(name, conf_dir) do
    case Source.load(conf_dir, "experiment", name) do
      {:ok, config} ->
        experiment_body = Map.get(config.body, "experiment", %{})

        %{
          name: name,
          groups: choices(config.defaults),
          experiment_class: Map.get(experiment_body, "_target_"),
          config: Map.get(experiment_body, "config", %{})
        }

      {:error, _reason} ->
        nil
    end
  end

  defp choices(defaults) do
    for {:group, group, option, _package} <- defaults,
        is_binary(option),
        into: %{} do
      {String.trim_leading(group, "/"), option}
    end
  end

  # Every root this node composes from, which is `Source.conf_dirs/0` and not
  # `Source.conf_dir/0`: Monty's mirror alone answers "what does Monty ship",
  # and a catalogue that answered that was a catalogue which could not find the
  # experiment that trains a model this node offers — `trainer_for/2` said "no
  # experiment here trains it" about an experiment one page away.
  defp conf_dir(opts), do: Keyword.get_lazy(opts, :conf_dir, fn -> conf_dirs() end)
end
