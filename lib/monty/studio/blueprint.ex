defmodule Monty.Studio.Blueprint do
  @moduledoc """
  An experiment described by the few choices a person actually makes.

  The rule for this module is *minimal input*: a name is enough to get a
  complete, runnable experiment, because everything else is inherited from a
  Monty experiment that already works. A blueprint is the base experiment's
  defaults list with the learner's choices substituted in place, plus the
  handful of `experiment.config` values that make a run a run (seed, epochs,
  where the trained model goes).

  It stays a config, not a struct with opinions: `to_yaml/1` writes the same
  text Monty's own experiment files contain, and `compose/1` composes that text
  through `Monty.Config.Source` and `Monty.Config.Composer`. So "preview" and
  "run" cannot disagree, because there is only one artefact.

  `findings/1` checks the choices a person made — an option that does not exist,
  a name that is not a name, epochs that are not epochs — before anything is
  composed or written.
  """

  alias Monty.Config.{Composer, Source}
  alias Monty.Studio.{Catalog, ConfigText, Finding}

  @enforce_keys [:name, :base, :defaults, :experiment_class, :config]
  defstruct [:name, :base, :defaults, :experiment_class, :config, groups: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          base: String.t(),
          defaults: [{String.t(), String.t()}],
          experiment_class: String.t(),
          config: map(),
          groups: %{optional(String.t()) => String.t()}
        }

  @default_base "tutorial/first_experiment"

  # The `experiment.config` values a builder owns. Everything else in that map
  # (measured constants, logging handlers, match criterion) belongs to the base
  # experiment and is carried through untouched.
  @builder_config_keys ~w(seed n_train_epochs n_eval_epochs supervised_lm_ids model_name_or_path)

  @doc """
  A blueprint from the least a person can say.

  Accepted keys (string or atom): `:name`, `:base`, any group of
  `Monty.Studio.Catalog.groups/0` by its name (`"monty/learning_module"`), and
  the config keys in `builder_config_keys/0`.
  """
  @spec new(map()) :: t()
  def new(attributes) do
    attributes = normalize_keys(attributes)
    base = Map.get(attributes, "base") || @default_base
    experiment = experiment(base)

    %__MODULE__{
      name: Map.get(attributes, "name") || Path.basename(base),
      base: base,
      defaults: experiment.defaults,
      groups: group_choices(experiment.defaults),
      experiment_class: experiment.experiment_class,
      config: Map.merge(experiment.config, config_choices(attributes))
    }
    |> apply_group_choices(attributes)
  end

  @doc """
  A blueprint that reproduces an existing experiment exactly.

  Useful as a starting point ("this one, but for two objects") and as a check
  on this module: composing such a blueprint must equal composing the
  experiment it came from.
  """
  @spec from_experiment(String.t(), keyword()) :: t()
  def from_experiment(name, opts \\ []) do
    new(Map.merge(Keyword.get(opts, :attributes, %{}), %{"base" => name, "name" => name}))
  end

  @doc "The `experiment.config` keys a builder sets."
  @spec builder_config_keys() :: [String.t()]
  def builder_config_keys, do: @builder_config_keys

  @doc "The group choices, in composition order."
  @spec groups(t()) :: [{String.t(), String.t()}]
  def groups(%__MODULE__{defaults: defaults, groups: groups}) do
    Enum.map(defaults, fn {group, option} -> {group, Map.get(groups, group, option)} end)
  end

  @doc """
  Chooses a different option for a group.

  A group the base experiment does not use is appended, which is what Hydra
  does when a config adds a group the base leaves out.
  """
  @spec put_group(t(), String.t(), String.t()) :: t()
  def put_group(%__MODULE__{} = blueprint, group, option) do
    defaults =
      if Enum.any?(blueprint.defaults, fn {existing, _option} -> existing == group end) do
        blueprint.defaults
      else
        blueprint.defaults ++ [{group, option}]
      end

    %{blueprint | defaults: defaults, groups: Map.put(blueprint.groups, group, option)}
  end

  @doc "Sets one `experiment.config` value."
  @spec put_config(t(), String.t(), term()) :: t()
  def put_config(%__MODULE__{config: config} = blueprint, key, value) do
    %{blueprint | config: Map.put(config, key, value)}
  end

  @doc "Since the config carries its own run name, renaming has to reach into it."
  @spec put_name(t(), String.t()) :: t()
  def put_name(%__MODULE__{} = blueprint, name) do
    blueprint
    |> Map.put(:name, name)
    |> put_config("logging", Map.put(logging(blueprint), "run_name", name))
  end

  @doc "What is wrong with the choices, if anything."
  @spec findings(t(), keyword()) :: [Finding.t()]
  def findings(%__MODULE__{} = blueprint, opts \\ []) do
    conf_dir = Keyword.get_lazy(opts, :conf_dir, fn -> Source.conf_dir() end)

    name_findings(blueprint) ++
      base_findings(blueprint, conf_dir) ++
      group_findings(blueprint, conf_dir) ++
      config_findings(blueprint)
  end

  @doc "The config as text, ready to be a file in Monty's `conf/experiment/`."
  @spec to_yaml(t()) :: String.t()
  def to_yaml(%__MODULE__{} = blueprint) do
    ConfigText.render(%{
      comments: [summary(blueprint)],
      defaults: to_yaml_defaults(groups(blueprint)),
      experiment: %{"_target_" => blueprint.experiment_class, "config" => blueprint.config}
    })
  end

  @doc """
  Composes the blueprint into Monty's config tree.

  The text is the input, so a preview of an unsaved blueprint is composed from
  exactly the bytes that would be written.
  """
  @spec compose(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compose(%__MODULE__{} = blueprint, opts \\ []) do
    blueprint
    |> to_yaml()
    |> Composer.compose_yaml(Keyword.take(opts, [:conf_dir]))
  end

  defp to_yaml_defaults(groups) do
    Enum.map(groups, fn {group, option} -> {absolute(group), option} end)
  end

  # Monty writes its group names from the config root; a group it names
  # relatively (a nested `hypotheses_updater` choice) is not one a blueprint
  # adds.
  defp absolute(group), do: if(String.starts_with?(group, "/"), do: group, else: "/" <> group)

  defp summary(%__MODULE__{name: name, base: base}) do
    "#{name}, from the Monty studio on top of #{base}. Composes with Monty's own conf groups."
  end

  defp name_findings(%__MODULE__{name: name}) do
    cond do
      String.trim(to_string(name)) == "" ->
        [Finding.new(:error, :name_missing, "An experiment needs a name.", "name")]

      String.contains?(name, ["/", "\\", " ", ".."]) ->
        [
          Finding.new(
            :error,
            :name_not_a_file_name,
            "The name becomes a run name and a directory, so it takes letters, digits, `-` and `_`.",
            "name"
          )
        ]

      true ->
        []
    end
  end

  defp base_findings(%__MODULE__{base: base}, conf_dir) do
    if File.exists?(Source.path_for(conf_dir, "experiment", base)) do
      []
    else
      [
        Finding.new(
          :error,
          :unknown_base,
          "No experiment named #{base} in Monty's conf.",
          "base"
        )
      ]
    end
  end

  defp group_findings(%__MODULE__{} = blueprint, conf_dir) do
    for {group, option} <- groups(blueprint),
        not File.exists?(Source.path_for(conf_dir, group, option)) do
      Finding.new(
        :error,
        :unknown_group_option,
        "Monty has no option #{option} for the #{group} group.",
        group
      )
    end
  end

  defp config_findings(%__MODULE__{config: config}) do
    epoch_findings(config) ++ seed_findings(config) ++ run_name_findings(config)
  end

  defp epoch_findings(config) do
    for key <- ~w(n_train_epochs n_eval_epochs),
        count = Map.get(config, key),
        not (is_integer(count) and count >= 0) do
      Finding.new(
        :error,
        :epochs_not_a_count,
        "#{key} must be a whole number of epochs, got #{inspect(count)}.",
        "experiment.config.#{key}"
      )
    end
  end

  defp seed_findings(config) do
    case Map.get(config, "seed") do
      seed when is_integer(seed) and seed >= 0 ->
        []

      other ->
        [
          Finding.new(
            :error,
            :seed_not_a_number,
            "The seed must be a non-negative integer, got #{inspect(other)}.",
            "experiment.config.seed"
          )
        ]
    end
  end

  defp run_name_findings(config) do
    case logging(config)["run_name"] do
      nil ->
        []

      "" ->
        []

      run_name when is_binary(run_name) ->
        []

      other ->
        [
          Finding.new(
            :error,
            :run_name_not_a_string,
            "The run name must be text, got #{inspect(other)}.",
            "experiment.config.logging.run_name"
          )
        ]
    end
  end

  defp logging(%__MODULE__{config: config}), do: logging(config)

  defp logging(config) when is_map(config) do
    case Map.get(config, "logging") do
      logging when is_map(logging) -> logging
      _absent_or_unexpected -> %{}
    end
  end

  # -- building -------------------------------------------------------------

  defp experiment(base) do
    conf_dir = Source.conf_dir()

    config =
      case Source.load(conf_dir, "experiment", base) do
        {:ok, config} ->
          config

        {:error, _reason} ->
          # An unknown base is a finding, not a crash: the blueprint is built
          # from the default so the page can say what is wrong.
          {:ok, fallback} = Source.load(conf_dir, "experiment", @default_base)
          fallback
      end

    experiment_body = Map.get(config.body, "experiment", %{})

    %{
      defaults:
        for(
          {:group, group, option, _package} <- config.defaults,
          is_binary(option),
          do: {String.trim_leading(group, "/"), option}
        ),
      experiment_class: Map.get(experiment_body, "_target_", ""),
      config: Map.get(experiment_body, "config", %{})
    }
  end

  defp group_choices(defaults) do
    Map.new(defaults, fn {group, option} -> {group, option} end)
  end

  defp config_choices(attributes) do
    @builder_config_keys
    |> Enum.filter(&Map.has_key?(attributes, &1))
    |> Map.new(&{&1, Map.fetch!(attributes, &1)})
  end

  defp apply_group_choices(blueprint, attributes) do
    Enum.reduce(Catalog.groups(), blueprint, fn group, blueprint ->
      case Map.fetch(attributes, group) do
        {:ok, option} -> put_group(blueprint, group, option)
        :error -> blueprint
      end
    end)
  end

  defp normalize_keys(attributes) do
    Map.new(attributes, fn {key, value} -> {to_string(key), value} end)
  end
end
