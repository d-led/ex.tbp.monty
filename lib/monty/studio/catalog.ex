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
  @templates [
    "tutorial/first_experiment",
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

    case stamp(conf_dir) do
      nil -> read(conf_dir)
      stamp -> cached({__MODULE__, :experiments, stamp}, fn -> read(conf_dir) end)
    end
  end

  defp read(conf_dir) do
    conf_dir
    |> Source.experiments()
    |> Enum.map(&experiment_from(&1, conf_dir))
    |> Enum.reject(&is_nil/1)
  end

  # When the directory was last written, and how many configs it holds: a copy
  # that is replaced, added to or trimmed moves one of the two.
  defp stamp(conf_dir) do
    directory = Path.join(conf_dir, "experiment")

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(directory, time: :posix),
         names when names != [] <- Path.wildcard(Path.join(directory, "*.yaml")) do
      {mtime, length(names)}
    else
      _missing -> nil
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
  The options a group offers, sorted.

  `monty/learning_module/hypotheses_updater` and its siblings live one level
  below the groups a builder picks, so they are not listed; asking for a name
  that is not a group returns `[]` rather than reaching elsewhere in the tree.
  """
  @spec options(String.t(), keyword()) :: [String.t()]
  def options(group, opts \\ []) do
    if group in @groups do
      Path.join([conf_dir(opts), group, "*.yaml"])
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename(".yaml")))
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

  defp conf_dir(opts), do: Keyword.get_lazy(opts, :conf_dir, fn -> Source.conf_dir() end)
end
