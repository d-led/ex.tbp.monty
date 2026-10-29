defmodule Monty.Studio.Setup do
  @moduledoc """
  What a composed experiment *is*, read back out of Monty's config tree.

  A config is nested maps and Hydra interpolations; this is the other view of
  the same thing: the sensors, the learning modules, how they are wired, the
  motor system, the corpus and the epoch budget. The setup page draws it, the
  run starts it, and the validator argues with it.

  The checks are Monty's own, not invented here. `MontyBase.__init__` refuses a
  model whose `sm_to_lm_matrix` is missing, whose row count does not match the
  learning modules, whose vote matrix is the wrong shape, or whose
  `sm_to_agent_dict` keys are not exactly its sensor ids. Those four are errors
  here for the same reason. The rest are things Monty would discover later, at
  runtime or after an hour of training — an index into a module that does not
  exist, a sensor nothing listens to, a learning module fed features its sensor
  does not produce — and a studio is worth more the earlier it says them.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.ModuleMap
  alias Monty.Studio.Finding

  defstruct name: nil,
            experiment_class: nil,
            monty_class: nil,
            environment: nil,
            motor_system: nil,
            attention_system: nil,
            monty_args: %{},
            sensors: [],
            learning_modules: [],
            connections: [],
            epochs: %{},
            seed: nil,
            supervised_lm_ids: [],
            findings: []

  @type module_description :: %{
          class: String.t() | nil,
          python: String.t() | nil,
          elixir: String.t() | nil,
          status: :implemented | :planned | :excluded | :unknown
        }

  @type sensor :: %{
          id: String.t(),
          key: String.t(),
          index: non_neg_integer(),
          features: [String.t()],
          features_resolved?: boolean(),
          module: module_description()
        }

  @type learning_module :: %{
          id: String.t(),
          key: String.t(),
          index: non_neg_integer(),
          module: module_description(),
          goal_generator: module_description() | nil,
          hypotheses_updater: module_description() | nil,
          feature_weights: %{optional(String.t()) => map()} | nil,
          config: map()
        }

  @type connection :: %{
          from: {:sensor | :learning_module, String.t()},
          to: {:sensor | :learning_module, String.t()},
          kind: :sensor_input | :hierarchy | :vote
        }

  @type t :: %__MODULE__{}

  @doc """
  Reads a composed experiment tree.

  Options: `:name`, used only for display and logging.
  """
  @spec new(map(), keyword()) :: t()
  def new(tree, opts \\ []) do
    {tree, unresolved?} = resolved(tree, opts)
    # `config:` with nothing under it is a config that names nothing, not a
    # reason to crash on the way to a finding.
    config = tree |> Map.get("experiment", %{}) |> Map.get("config", %{}) || %{}
    monty_config = Map.get(config, "monty_config", %{})

    sensors = sensors(monty_config)
    learning_modules = learning_modules(monty_config)
    connections = connections(monty_config, sensors, learning_modules)

    setup = %__MODULE__{
      name: Keyword.get(opts, :name),
      experiment_class: describe_target(Map.get(tree["experiment"] || %{}, "_target_")),
      monty_class: describe_target(Map.get(monty_config, "monty_class")),
      environment: environment(config),
      motor_system: motor_system(monty_config),
      attention_system: describe_target(get_in(monty_config, ["attention_system", "_target_"])),
      monty_args: Map.get(monty_config, "monty_args", %{}),
      sensors: sensors,
      learning_modules: learning_modules,
      connections: connections,
      epochs: %{
        train: Map.get(config, "n_train_epochs"),
        eval: Map.get(config, "n_eval_epochs")
      },
      seed: Map.get(config, "seed"),
      supervised_lm_ids: Map.get(config, "supervised_lm_ids")
    }

    findings = findings(setup, monty_config, config) ++ resolution_findings(unresolved?)

    %{setup | findings: findings}
  end

  # Monty resolves `${...}` when it builds the experiment. Reading a config as
  # *values* means resolving it too, or every interpolated epoch count and
  # feature list looks wrong. The environment is the shell's, with Monty's
  # documented defaults, because a config that names `~/tbp/data` is not broken
  # when the variable is unset — it is Monty's default.
  defp resolved(tree, opts) do
    env = fn name -> System.get_env(name) || default_for(name) end

    case Monty.Config.Resolvers.resolve(tree, env: env, monty_root: monty_root(opts)) do
      {:ok, resolved} -> {resolved, false}
      {:error, _reason} -> {tree, true}
    end
  end

  defp default_for(name) when name in ~w(MONTY_DATA MONTY_MODELS MONTY_LOGS),
    do: Monty.Prerequisites.root_default(name)

  defp default_for(_name), do: nil

  defp monty_root(opts),
    do: Keyword.get_lazy(opts, :monty_root, fn -> Monty.Config.Source.root() end)

  defp resolution_findings(false), do: []

  defp resolution_findings(true) do
    [
      Finding.new(
        :info,
        :values_resolved_at_run_time,
        "Some values in this config are resolved when Monty builds the experiment; they are shown as written.",
        "experiment.config"
      )
    ]
  end

  @doc "Composes an experiment Monty ships and reads it."
  @spec from_experiment(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_experiment(name, opts \\ []) do
    with {:ok, tree} <- Monty.Config.Composer.compose(name, Keyword.take(opts, [:conf_dir])) do
      {:ok, new(tree, [name: name] ++ Keyword.take(opts, [:name]))}
    end
  end

  @doc "Reads an experiment config from a file outside Monty's tree."
  @spec from_file(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_file(path, opts \\ []) do
    with {:ok, tree} <- Monty.Config.Composer.compose_file(path, Keyword.take(opts, [:conf_dir])) do
      {:ok, new(tree, opts)}
    end
  end

  @doc "Composes config text and reads it."
  @spec from_text(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_text(text, opts \\ []) do
    with {:ok, tree} <- Monty.Config.Composer.compose_yaml(text, Keyword.take(opts, [:conf_dir])) do
      {:ok, new(tree, opts)}
    end
  end

  @doc "True when nothing would stop Monty."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{findings: findings}), do: Finding.acceptable?(findings)

  @doc "The findings at one level."
  @spec findings(t(), Finding.level()) :: [Finding.t()]
  def findings(%__MODULE__{findings: findings}, level), do: Finding.at(findings, level)

  @doc "How much of this setup exists here, as a fraction of the ported classes."
  @spec ported(t()) :: %{implemented: non_neg_integer(), total: non_neg_integer()}
  def ported(%__MODULE__{} = setup) do
    modules = all_modules(setup)

    %{
      implemented: Enum.count(modules, &(&1.status == :implemented)),
      total: length(modules)
    }
  end

  @doc """
  The model spec `Monty.Runtime.Model` runs.

  Every configured sensor and learning module becomes a process, wired exactly
  as the config wires them — so a run is a run of *this* topology, with
  stand-in modules until the ported ones land.
  """
  @spec model_spec(t(), atom() | String.t()) :: map()
  def model_spec(%__MODULE__{} = setup, model_id) do
    %{
      model_id: model_id,
      sensor_modules:
        Enum.map(setup.sensors, fn sensor ->
          %{
            id: sensor.id,
            agent_id: Monty.Simulators.Synthetic.Environment.agent_id(),
            module: Monty.Simulators.Synthetic.SensorModule,
            state: Monty.Simulators.Synthetic.SensorModule.new(sensor.id)
          }
        end),
      learning_modules: Enum.map(setup.learning_modules, &learning_module_spec/1),
      sm_to_lm: inputs_by_learning_module(setup, :sensor_input),
      lm_to_lm: inputs_by_learning_module(setup, :hierarchy),
      lm_to_lm_vote: inputs_by_learning_module(setup, :vote),
      # The ported motor system builds from this config too
      # (`Monty.Frameworks.Models.MotorSystem.from_config/1`), but the stand-in
      # environment cannot execute what it would ask for: a policy answers
      # `Monty.Frameworks.Actions` structs, and `Monty.Simulators.Synthetic.Environment`
      # ignores actions entirely. A real body on a fake world would be fake
      # progress, so the stand-in motor stays until a world consumes actions.
      motor: {Monty.Simulators.Synthetic.Motor, Monty.Simulators.Synthetic.Motor.new()}
    }
  end

  # What runs for one learning module: the ported module when the config targets
  # one this port has written, and the stand-in otherwise. The config decides,
  # because a module built from it is what makes a run a run of *this*
  # experiment rather than of a topology that merely looks like it.
  defp learning_module_spec(lm) do
    case EvidenceGraphLM.from_config(lm.config) do
      {:ok, state} ->
        %{id: lm.id, module: EvidenceGraphLM, state: state}

      {:error, _reason} ->
        %{
          id: lm.id,
          module: Monty.Simulators.Synthetic.LearningModule,
          state: Monty.Simulators.Synthetic.LearningModule.new(lm.id)
        }
    end
  end

  @doc "The sensor ids a run reads observations for."
  @spec sensor_ids(t()) :: [String.t()]
  def sensor_ids(%__MODULE__{sensors: sensors}), do: Enum.map(sensors, & &1.id)

  # -- extraction -----------------------------------------------------------

  defp sensors(monty_config) do
    monty_config
    |> Map.get("sensor_modules", %{})
    |> indexed_entries()
    |> Enum.map(fn {key, _index, sensor} ->
      declared_features = Map.get(sensor, "features")

      %{
        id: Map.get(sensor, "sensor_module_id", key),
        key: key,
        index: index_of(key),
        features: if(is_list(declared_features), do: declared_features, else: []),
        # A features list written as `${constants.default_sensor_features}` is
        # resolved by Monty at run time; until then it is not a list of
        # features, and guessing would produce a finding about our guess.
        features_resolved?: is_list(declared_features),
        module: describe_target(Map.get(sensor, "_target_"))
      }
    end)
  end

  defp learning_modules(monty_config) do
    monty_config
    |> Map.get("learning_modules", %{})
    |> indexed_entries()
    |> Enum.map(fn {key, _index, lm} ->
      %{
        id: key,
        key: key,
        index: index_of(key),
        module: describe_target(Map.get(lm, "_target_")),
        goal_generator: optional_describe_target(get_in(lm, ["gsg", "_target_"])),
        hypotheses_updater: optional_describe_target(Map.get(lm, "hypotheses_updater_class")),
        feature_weights: Map.get(lm, "feature_weights", %{}),
        # Kept whole: a run builds its module from this, so the numbers an
        # experiment writes are the numbers that run.
        config: lm
      }
    end)
  end

  # Monty orders modules by their position in the file; the composed map keeps
  # the keys but not the order, and the keys are numbered, so the number is the
  # position. Sorting textually would put `_10` before `_2`.
  defp indexed_entries(entries) do
    entries
    |> Enum.map(fn {key, value} -> {key, index_of(key), value} end)
    |> Enum.sort_by(fn {_key, index, _value} -> index end)
  end

  defp index_of(key) do
    case Regex.run(~r/(\d+)$/, to_string(key)) do
      [_, digits] -> String.to_integer(digits)
      nil -> 0
    end
  end

  defp connections(monty_config, sensors, learning_modules) do
    sm_to_lm(monty_config, sensors, learning_modules) ++
      lm_to_lm(monty_config, learning_modules) ++
      votes(monty_config, learning_modules)
  end

  defp sm_to_lm(monty_config, sensors, learning_modules) do
    matrix_edges(Map.get(monty_config, "sm_to_lm_matrix"), learning_modules, sensors)
    |> Enum.map(fn {lm, sensor} ->
      %{from: {:sensor, sensor}, to: {:learning_module, lm}, kind: :sensor_input}
    end)
  end

  defp lm_to_lm(monty_config, learning_modules) do
    matrix_edges(Map.get(monty_config, "lm_to_lm_matrix"), learning_modules, learning_modules)
    |> Enum.map(fn {receiver, source} ->
      %{from: {:learning_module, source}, to: {:learning_module, receiver}, kind: :hierarchy}
    end)
  end

  defp votes(monty_config, learning_modules) do
    matrix_edges(
      Map.get(monty_config, "lm_to_lm_vote_matrix"),
      learning_modules,
      learning_modules
    )
    |> Enum.map(fn {receiver, source} ->
      %{from: {:learning_module, source}, to: {:learning_module, receiver}, kind: :vote}
    end)
  end

  # Monty's connection matrices are `matrix[row][column]`: row `i` belongs to
  # target module `i`, column `j` names source module `j`. `null` means "no
  # such wiring", which is not the same as "wired to nothing".
  defp matrix_edges(nil, _targets, _sources), do: []

  defp matrix_edges(matrix, targets, sources) when is_list(matrix) do
    for {row, index} <- Enum.with_index(matrix),
        is_list(row),
        column <- row,
        source = Enum.at(sources, column),
        target = Enum.at(targets, index),
        source != nil,
        target != nil do
      {target.id, source.id}
    end
  end

  defp matrix_edges(_unexpected, _targets, _sources), do: []

  # Monty's `/environment` group is the simulator's *arguments*; what builds the
  # world is `env_init_func`, and what turns a world into episodes is the
  # interface class one level up. Both are read, because a setup that named only
  # one of them would not say what the run actually is.
  defp environment(config) do
    case Map.get(config, "environment") do
      %{} = environment ->
        args = Map.get(environment, "env_init_args", %{})

        %{
          module: describe_target(Map.get(environment, "env_init_func")),
          interface: describe_target(interface_class(config)),
          data_path: Map.get(args, "data_path"),
          objects: object_names(args)
        }

      _absent ->
        nil
    end
  end

  defp interface_class(config) do
    Map.get(config, "train_env_interface_class") || Map.get(config, "eval_env_interface_class")
  end

  defp object_names(args) do
    case Map.get(args, "objects") do
      list when is_list(list) -> Enum.map(list, &object_name/1)
      _absent -> []
    end
  end

  defp object_name(%{"name" => name}), do: name
  defp object_name(name), do: name

  defp motor_system(monty_config) do
    motor = Map.get(monty_config, "motor_system_config")

    case motor do
      %{} = motor ->
        selector = Map.get(motor, "policy_selector", %{})

        %{
          module: describe_target(Map.get(motor, "_target_")),
          selector: describe_target(Map.get(selector, "_target_")),
          policies:
            for {name, policy} <- selector, name != "_target_", into: %{} do
              {name, describe_target(get_in(policy, ["_target_"]))}
            end
        }

      _absent ->
        nil
    end
  end

  defp inputs_by_learning_module(setup, kind) do
    for lm <- setup.learning_modules, into: %{} do
      sources =
        setup.connections
        |> Enum.filter(&(&1.kind == kind and &1.to == {:learning_module, lm.id}))
        |> Enum.map(&elem(&1.from, 1))

      {lm.id, sources}
    end
  end

  # -- targets --------------------------------------------------------------

  @doc "The class a `_target_` names, with the module map's verdict on it."
  @spec describe_target(term()) :: module_description() | nil
  def describe_target(nil), do: nil

  def describe_target(target) when is_binary(target) do
    python = unwrap(target)

    case ModuleMap.resolve(python) do
      {:ok, resolved} ->
        %{
          class: resolved.class,
          python: "tbp." <> resolved.package <> "." <> String.replace(resolved.python, "/", "."),
          elixir: resolved.elixir,
          status: resolved.status
        }

      :error ->
        %{class: last_segment(python), python: python, elixir: nil, status: :unknown}
    end
  end

  def describe_target(_not_a_target), do: nil

  defp optional_describe_target(nil), do: nil
  defp optional_describe_target(target), do: describe_target(target)

  # Monty writes the interpolated form when the class must be resolved at run
  # time: `${monty.class:tbp.monty.frameworks.models.motor_policies.JumpToGoal}`.
  defp unwrap("${monty.class:" <> rest), do: rest |> String.trim_trailing("}")
  defp unwrap(target), do: target

  defp last_segment(dotted), do: dotted |> String.split(".") |> List.last()

  defp all_modules(setup) do
    environment_modules =
      case setup.environment do
        nil -> []
        environment -> [environment.module, environment.interface]
      end

    (environment_modules ++
       [setup.experiment_class, setup.monty_class] ++
       Enum.map(setup.sensors, & &1.module) ++
       Enum.flat_map(
         setup.learning_modules,
         &[&1.module, &1.goal_generator, &1.hypotheses_updater]
       ) ++
       ((setup.motor_system && [setup.motor_system.module, setup.motor_system.selector]) || []) ++
       ((setup.motor_system && Map.values(setup.motor_system.policies)) || []) ++
       [setup.attention_system])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.python)
  end

  # -- findings -------------------------------------------------------------

  defp findings(setup, monty_config, config) do
    module_findings(setup) ++
      connectivity_findings(setup, monty_config) ++
      wiring_findings(setup) ++
      settings_findings(config)
  end

  # One line per experiment about what is not ported, not one per class: a
  # fifteen-module config would otherwise bury its real findings under fifteen
  # identical notices. The names are listed, so the line is still actionable.
  defp module_findings(setup) do
    modules = all_modules(setup)
    unknown = Enum.filter(modules, &(&1.status == :unknown))
    planned = for module <- modules, module.status == :planned, do: module.class

    Enum.map(unknown, &unknown_module_finding/1) ++ not_ported_finding(planned, length(modules))
  end

  defp unknown_module_finding(module) do
    Finding.new(
      :warning,
      :unknown_module_class,
      "This config names a class the module map does not know, so nothing here can stand in for it.",
      module.python || module.class
    )
  end

  defp not_ported_finding([], _total), do: []

  defp not_ported_finding(classes, total) do
    [
      Finding.new(
        :info,
        :modules_not_ported,
        "#{length(classes)} of #{total} classes this experiment uses are not ported yet: " <>
          Enum.join(Enum.sort(classes), ", ") <> ". A run uses synthetic stand-ins.",
        "monty_config"
      )
    ]
  end

  defp connectivity_findings(setup, monty_config) do
    sm_to_lm = Map.get(monty_config, "sm_to_lm_matrix")
    vote_matrix = Map.get(monty_config, "lm_to_lm_vote_matrix")
    lm_count = length(setup.learning_modules)

    missing_matrix(sm_to_lm) ++
      shape_findings(sm_to_lm, lm_count, :learning_module_count_mismatch) ++
      shape_findings(vote_matrix, lm_count, :vote_matrix_count_mismatch) ++
      agent_mapping_findings(setup, monty_config) ++
      range_findings(sm_to_lm, length(setup.sensors), "sm_to_lm_matrix") ++
      range_findings(
        Map.get(monty_config, "lm_to_lm_matrix"),
        lm_count,
        "lm_to_lm_matrix"
      ) ++
      range_findings(vote_matrix, lm_count, "lm_to_lm_vote_matrix") ++
      goal_generator_findings(setup)
  end

  # Goal generation is what turns "I am not sure" into "look there next", and a
  # reading of an object is not reproducible without it. No goal generator is
  # ported yet, so a config that asks for one runs without goals — which is a
  # different experiment, and has to say so rather than explore at random.
  defp goal_generator_findings(setup) do
    for lm <- setup.learning_modules, lm.goal_generator != nil do
      Finding.new(
        :warning,
        :goal_generator_not_ported,
        "#{lm.id} asks for a goal generator (#{lm.goal_generator.class}), which this port has not written: this run explores without goals.",
        "experiment.config.monty_config.learning_modules.#{lm.key}.gsg"
      )
    end
  end

  defp missing_matrix(nil) do
    [
      Finding.new(
        :error,
        :sm_to_lm_matrix_missing,
        "Monty refuses to start a model without `sm_to_lm_matrix`: nothing would reach a learning module.",
        "experiment.config.monty_config.sm_to_lm_matrix"
      )
    ]
  end

  defp missing_matrix(_matrix), do: []

  defp shape_findings(nil, _count, _code), do: []

  defp shape_findings(matrix, count, code) when is_list(matrix) and length(matrix) != count do
    [
      Finding.new(
        :error,
        code,
        "The matrix has a row per learning module, so it needs #{count} row(s), not #{length(matrix)}.",
        "experiment.config.monty_config"
      )
    ]
  end

  defp shape_findings(_matrix, _count, _code), do: []

  defp agent_mapping_findings(setup, monty_config) do
    mapped = monty_config |> Map.get("sm_to_agent_dict", %{}) |> Map.keys() |> MapSet.new()
    sensors = setup.sensors |> Enum.map(& &1.id) |> MapSet.new()

    if MapSet.equal?(mapped, sensors) do
      []
    else
      [
        Finding.new(
          :error,
          :sensor_agent_mapping_mismatch,
          "Every sensor module needs exactly one agent in `sm_to_agent_dict`: sensors #{inspect(MapSet.to_list(sensors))}, mapped #{inspect(MapSet.to_list(mapped))}.",
          "experiment.config.monty_config.sm_to_agent_dict"
        )
      ]
    end
  end

  defp range_findings(nil, _count, _name), do: []

  defp range_findings(matrix, count, name) when is_list(matrix) do
    out_of_range =
      for {row, row_index} <- Enum.with_index(matrix),
          is_list(row),
          column <- row,
          column >= count do
        {row_index, column}
      end

    case out_of_range do
      [] ->
        []

      [{row, column} | _rest] ->
        [
          Finding.new(
            :error,
            :connection_index_out_of_range,
            "#{name} row #{row} names module #{column}, but there are only #{count}.",
            "experiment.config.monty_config.#{name}"
          )
        ]
    end
  end

  defp range_findings(_matrix, _count, _name), do: []

  defp wiring_findings(setup) do
    unconnected_sensors(setup) ++ unconnected_learning_modules(setup) ++ feature_findings(setup)
  end

  defp unconnected_sensors(setup) do
    connected =
      for %{kind: :sensor_input, from: {:sensor, id}} <- setup.connections,
          into: MapSet.new(),
          do: id

    for sensor <- setup.sensors, not MapSet.member?(connected, sensor.id) do
      Finding.new(
        :info,
        :sensor_not_matched,
        "#{sensor.id} feeds no learning module, so nothing matches on its percepts. " <>
          "Monty still steps it and can record its observations — a view finder is how an " <>
          "experiment keeps a wide shot — and `sm_to_lm_matrix` is where it would be matched.",
        sensor.id
      )
    end
  end

  defp unconnected_learning_modules(setup) do
    connected =
      for %{kind: :sensor_input, to: {:learning_module, id}} <- setup.connections,
          into: MapSet.new(),
          do: id

    for lm <- setup.learning_modules, not MapSet.member?(connected, lm.id) do
      Finding.new(
        :warning,
        :learning_module_unconnected,
        "#{lm.id} gets no sensor input, so it can never learn or match anything.",
        lm.id
      )
    end
  end

  # A learning module's `feature_weights` name the sensor it was tuned for; if
  # that sensor does not carry the feature, Monty matches on nothing and says
  # nothing.
  defp feature_findings(setup) do
    features =
      for sensor <- setup.sensors, sensor.features_resolved?, into: %{} do
        {sensor.id, MapSet.new(sensor.features)}
      end

    Enum.flat_map(setup.learning_modules, &missing_features(&1, features, setup))
  end

  defp missing_features(learning_module, features, setup) do
    Enum.flat_map(learning_module.feature_weights, fn {sensor_id, weights} ->
      case Map.fetch(features, sensor_id) do
        {:ok, provided} -> weights_missing(learning_module, sensor_id, weights, provided)
        :error -> unknown_sensor(learning_module, sensor_id, setup)
      end
    end)
  end

  defp weights_missing(learning_module, sensor_id, weights, provided) do
    for feature <- Map.keys(weights || %{}),
        not MapSet.member?(provided, feature) do
      missing_feature(learning_module, sensor_id, feature)
    end
  end

  defp unknown_sensor(learning_module, sensor_id, setup) do
    if sensor_resolved?(setup, sensor_id),
      do: [weights_for_unknown_sensor(learning_module, sensor_id)],
      else: []
  end

  defp sensor_resolved?(setup, sensor_id) do
    Enum.any?(setup.sensors, &(&1.id == sensor_id and &1.features_resolved?))
  end

  defp missing_feature(lm, sensor_id, feature) do
    Finding.new(
      :warning,
      :feature_not_provided,
      "#{lm.id} weighs the feature #{feature}, which #{sensor_id} does not produce.",
      lm.id
    )
  end

  defp weights_for_unknown_sensor(lm, sensor_id) do
    Finding.new(
      :warning,
      :weights_for_unknown_sensor,
      "#{lm.id} has feature weights for #{sensor_id}, which is not one of this experiment's sensors.",
      lm.id
    )
  end

  defp settings_findings(config) do
    epoch_findings(config["n_train_epochs"], "n_train_epochs") ++
      epoch_findings(config["n_eval_epochs"], "n_eval_epochs")
  end

  defp epoch_findings(count, _key) when is_integer(count) and count >= 0, do: []

  defp epoch_findings(count, key) do
    [
      Finding.new(
        :error,
        :epochs_not_a_count,
        "#{key} must be a whole number of epochs, got #{inspect(count)}.",
        "experiment.config.#{key}"
      )
    ]
  end
end
