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

  alias Monty.Experiment.Environment.OneObjectPerEpisodeInterface
  alias Monty.Experiment.RecognitionPolicy
  alias Monty.Experiment.SensorModule.ExperimentSensorModule
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Frameworks.Models.Salience.SensorModule.SalienceSM
  alias Monty.Frameworks.Models.SensorModules.CameraSM
  alias Monty.Geometry.Rotation
  alias Monty.ModuleMap
  alias Monty.Simulators.Habitat.Environment.HabitatEnvironment
  alias Monty.Studio.Finding
  alias Monty.Studio.Memory

  # What a Habitat camera sees across, and so what `DepthTo3DLocations` inverts.
  # Monty's agents take a resolution and a zoom and no field of view.
  @habitat_hfov 90.0

  defstruct name: nil,
            experiment_class: nil,
            monty_class: nil,
            environment: nil,
            world: :synthetic,
            cameras: %{},
            scene: %{agent: nil, sensors: %{}, objects: []},
            motor_system: nil,
            motor_system_config: %{},
            transforms: [],
            attention_system: nil,
            monty_args: %{},
            sensors: [],
            learning_modules: [],
            connections: [],
            epochs: %{},
            seed: nil,
            supervised_lm_ids: [],
            logging: %{output_dir: nil, run_name: nil, logger: nil, handlers: []},
            findings: [],
            positioning: [],
            object_names: nil,
            recognition_policy: nil,
            model_name_or_path: nil

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

  @typedoc """
  One sensor's camera, in the terms its simulator states it: a resolution in
  pixels, a zoom multiplier, and a field of view in degrees.
  """
  @type camera :: [resolution: {pos_integer(), pos_integer()}, zoom: float(), hfov: float()]

  @typedoc """
  Where one body starts: a position in the world and the rotation from its own
  frame to the world's.
  """
  @type pose :: %{position: [float()], rotation: Monty.Geometry.Rotation.t()}

  @typedoc """
  The place an experiment is run in, as its simulator is configured: where the
  agent starts, where its sensors sit relative to it, and what is in front of it.
  """
  @type scene :: %{
          agent: pose() | nil,
          sensors: %{optional(String.t()) => pose()},
          objects: [%{name: String.t() | nil, position: [float()]}]
        }

  @type connection :: %{
          from: {:sensor | :learning_module, String.t()},
          to: {:sensor | :learning_module, String.t()},
          kind: :sensor_input | :hierarchy | :vote
        }

  @typedoc """
  The experiment's `logging` section: where it would write, and what it would
  write with.

  `logger` is Monty's `monty_data_logger` — the class that pools an episode's
  data — and `handlers` are the classes it hands that pool to, each with the
  keywords its config gives it. Both are described rather than built, because
  what a config names and what this port has are two different questions.
  """
  @type logging :: %{
          output_dir: String.t() | nil,
          run_name: String.t() | nil,
          logger: module_description() | nil,
          handlers: [%{module: module_description() | nil, config: map()}]
        }

  @type t :: %__MODULE__{}

  @doc """
  Reads a composed experiment tree.

  Options: `:name`, used only for display and logging, and `:world_simulator`
  (`:synthetic` or `:habitat`), which world a run is being read for.
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
      world: Keyword.get_lazy(opts, :world_simulator, &configured_world/0),
      cameras: cameras(config),
      scene: scene(config),
      motor_system: motor_system(monty_config),
      motor_system_config: Map.get(monty_config, "motor_system_config", %{}),
      transforms: transforms(config),
      positioning: get_in(config, ["eval_env_interface_args", "positioning_procedures"]) || [],
      object_names: get_in(config, ["eval_env_interface_args", "object_names"]),
      recognition_policy: Map.get(config, "recognition_policy"),
      model_name_or_path: Map.get(config, "model_name_or_path"),
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
      supervised_lm_ids: Map.get(config, "supervised_lm_ids"),
      logging: logging(config)
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

  # Which world a run steps is the machine's, not the experiment's: a config
  # says nothing about whether this host can run Monty's simulator, so it stays
  # apart from the config tree and the finding below says what it means.
  defp configured_world, do: Application.get_env(:ex_tbp_monty, :world_simulator, :synthetic)

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
      {:ok, new(tree, [name: name] ++ Keyword.take(opts, [:name, :world_simulator]))}
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

  # Monty's `experiment.config.logging`: `monty_data_logger` is one class nested
  # with its handlers, and a handler is a target plus the keywords that target
  # is constructed with — so the config is read for both halves of each.
  defp logging(config) do
    logging = Map.get(config, "logging") || %{}
    data_logger = Map.get(logging, "monty_data_logger") || %{}

    %{
      output_dir: Map.get(logging, "output_dir"),
      run_name: Map.get(logging, "run_name"),
      logger: describe_target(Map.get(data_logger, "_target_")),
      handlers: Enum.map(Map.get(data_logger, "handlers") || [], &handler/1)
    }
  end

  defp handler(entry) when is_map(entry) do
    %{
      module: describe_target(Map.get(entry, "_target_")),
      config: Map.drop(entry, ["_target_"])
    }
  end

  defp handler(_not_a_map), do: %{module: nil, config: %{}}

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

  # The models this port has written, by the name a config gives. A config that
  # names any other runs on this port's runtime, which is what the findings say
  # out loud rather than leaving to be discovered.
  @model_classes %{"MontyForEvidenceGraphMatching" => MontyForEvidenceGraphMatching}

  @doc """
  The model a run of this setup starts.

  Monty's own class when this port has written it, this port's runtime when it
  has not — the same answer the findings give, from the same map.
  """
  @spec model_class(t()) :: module()
  def model_class(%__MODULE__{monty_class: %{class: class}}),
    do: Map.get(@model_classes, class, Monty.Runtime.Model)

  def model_class(%__MODULE__{}), do: Monty.Runtime.Model

  @doc """
  The model spec a run starts: what the config resolved to, as processes can be
  given it.

  Every configured sensor and learning module becomes a process, wired exactly
  as the config wires them — so a run is a run of *this* topology, with
  stand-in modules until the ported ones land. The experiment's own
  `monty_args` come with it: how many steps each step type must last before
  anything may conclude is a property of the run, and a model given none of
  them would check the terminal condition on its first step.
  """
  @spec model_spec(t(), atom() | String.t()) :: map()
  def model_spec(%__MODULE__{} = setup, model_id) do
    Map.merge(
      %{
        model_id: model_id,
        sensor_modules: Enum.map(setup.sensors, &sensor_module_spec/1),
        learning_modules:
          Enum.map(setup.learning_modules, &learning_module_spec(&1, memory_for(setup))),
        sm_to_lm: inputs_by_learning_module(setup, :sensor_input),
        lm_to_lm: inputs_by_learning_module(setup, :hierarchy),
        lm_to_lm_vote: inputs_by_learning_module(setup, :vote),
        motor: motor_spec(setup),
        # A step waits for its modules for as long as they take. Monty's round
        # is synchronous, and the vote round — which does have a deadline, on
        # purpose — is a separate number (`vote_timeout`). A deadline on the
        # work itself only decides which module gets dropped when a machine is
        # busy, which is the one thing a comparison must not let it decide.
        call_timeout: :infinity
      },
      monty_args(setup)
    )
  end

  # Monty keeps these on the model (`MontyBase.min_steps`), not on a module: a
  # matching episode may not conclude before `min_eval_steps` matching steps,
  # and an exploratory one runs for `num_exploratory_steps`.
  @monty_args %{
    "min_eval_steps" => :min_eval_steps,
    "min_train_steps" => :min_train_steps,
    "num_exploratory_steps" => :num_exploratory_steps
  }

  defp monty_args(%__MODULE__{monty_args: args}) do
    for {key, field} <- @monty_args, Map.has_key?(args, key), into: %{} do
      {field, Map.fetch!(args, key)}
    end
  end

  # What runs for one sensor: the class its config targets, when this port has
  # written it, and a stand-in otherwise.
  defp sensor_module_spec(sensor) do
    case ported_sensor_module(sensor.config) do
      {:ok, module, state} ->
        %{
          id: sensor.id,
          agent_id: Monty.Simulators.Synthetic.Environment.agent_id(),
          module: module,
          state: state
        }

      :not_ported ->
        %{
          id: sensor.id,
          agent_id: Monty.Simulators.Synthetic.Environment.agent_id(),
          module: Monty.Simulators.Synthetic.SensorModule,
          state: Monty.Simulators.Synthetic.SensorModule.new(sensor.id, sensor_options(sensor))
        }
    end
  end

  # The sensor classes Monty's configs name — a patch is a `CameraSM`, a view
  # finder is a transform-pipeline `ExperimentSensorModule` or a `SalienceSM`
  # that proposes where to look — and the port's own module for each. One that is
  # none of them, or one whose pieces this port has not written, is a stand-in.
  defp ported_sensor_module(config) do
    [CameraSM, ExperimentSensorModule, SalienceSM]
    |> Enum.find_value(:not_ported, fn module ->
      case module.from_config(config) do
        {:ok, state} -> {:ok, module, state}
        {:error, _not_this_class} -> nil
      end
    end)
  end

  # What a sensor some other class owns is given: the features its config
  # declares, and no filter, because that is all the stand-in offers.
  defp sensor_options(sensor) do
    [
      features: sensor.features,
      delta_thresholds: sensor.delta_thresholds,
      is_surface_sm: sensor.is_surface_sm
    ]
  end

  # The body is the config's, when every class it names is ported: the motor
  # system, the selector and every policy. Otherwise the stand-in drives, which
  # moves the agent and leaves the percepts to the learning modules.
  defp motor_spec(%__MODULE__{motor_system_config: config}) when map_size(config) > 0 do
    if Monty.Config.Target.implemented?(config) do
      {Monty.Frameworks.Models.MotorSystem,
       Monty.Frameworks.Models.MotorSystem.from_config(config)}
    else
      {Monty.Simulators.Synthetic.Motor, Monty.Simulators.Synthetic.Motor.new()}
    end
  end

  defp motor_spec(%__MODULE__{}),
    do: {Monty.Simulators.Synthetic.Motor, Monty.Simulators.Synthetic.Motor.new()}

  @doc """
  The world this setup is run against.

  The stand-in world with a sphere in it: enough for a ported surface policy to
  steer by (depth, a normal, curvatures), and no claim to be Monty's world. A
  simulator behind `Monty.Simulators.Port.Environment` replaces it when one can
  run here.

  Each sensor looks through the camera its own experiment describes — the
  resolution and zoom its agent is configured with, which for
  `base_10simobj_surf_agent` is 64 pixels at ten times zoom for the patch and
  64 at one times for the view finder. That is not a detail to round off: the
  transform that turns a depth image into points unprojects with those numbers,
  so a world rendering a different camera would disagree with it about which ray
  a pixel came from. A sensor whose experiment declares no camera renders one
  ray down its own axis.

  It starts where the experiment starts it, too: `base_10simobj_surf_agent`
  puts the agent 0.2 m from the object's centre with its patch camera on the
  agent and its view finder 3 cm behind, and that is what a surface policy's
  search expects to see — Monty's own `_move_to_visible_object` steps forward
  from there until the view finder is at `desired_object_distance`, which is
  what brings the patch within a finger's reach.
  """
  @spec world(t()) :: Monty.Simulators.Environment.t()
  def world(%__MODULE__{world: world} = setup), do: world(setup, world)

  @doc """
  The world a run of this experiment steps: Monty's own, or the stand-in.

  `:habitat` is `Monty.Simulators.Habitat.Environment.HabitatEnvironment`, which
  runs Monty's `HabitatEnvironment` in Monty's own Python environment — the
  world the experiment was written for, one round trip per step. `:synthetic`
  is this port's scene, which steps in the BEAM and steps nothing Monty posed.
  """
  @spec world(t(), :synthetic | :habitat) :: Monty.Simulators.Environment.t()
  def world(%__MODULE__{} = setup, :habitat) do
    HabitatEnvironment.new(experiment: setup.name, sensors: sensor_ids(setup))
  end

  def world(%__MODULE__{} = setup, :synthetic) do
    Monty.Simulators.Synthetic.Environment.new(
      sensor_ids(setup),
      Monty.Simulators.Synthetic.Scene.new(centre: object_centre(setup)),
      views: setup.cameras,
      agent: setup.scene.agent,
      sensors: setup.scene.sensors
    )
  end

  # The stand-in world has one object. Where the experiment puts the first one is
  # where the sphere goes; a config with no objects leaves it at the origin,
  # which is where a world with nothing to say about scenes has always had it.
  defp object_centre(%__MODULE__{scene: %{objects: [%{position: position} | _rest]}}),
    do: position

  defp object_centre(%__MODULE__{}), do: [0.0, 0.0, 0.0]

  # What runs for one learning module: the ported module when the config targets
  # one this port has written, and the stand-in otherwise. The config decides,
  # because a module built from it is what makes a run a run of *this*
  # experiment rather than of a topology that merely looks like it.
  # A module with no pretrained memory is built the way Monty builds one before
  # loading a state dict into it: with the empty memory the module makes itself.
  defp learning_module_spec(lm, :none),
    do: build_learning_module(lm, &EvidenceGraphLM.from_config/1)

  defp learning_module_spec(lm, memory),
    do: build_learning_module(lm, &EvidenceGraphLM.from_config(&1, memory: memory))

  defp build_learning_module(lm, build) do
    case build.(lm.config) do
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

  @doc """
  Monty's pretrained memory for the model this experiment names, if exported.

  `:none` means an empty memory: the config names no model, it names no release
  to look in, or this machine has no exported library for that model from that
  release — and `memory_findings/1` says which, because a run with no memory
  cannot recognise anything however long it runs.
  """
  @spec memory_for(t()) :: Monty.Frameworks.Models.GraphMatching.GraphMemory.t() | :none
  def memory_for(%__MODULE__{model_name_or_path: nil}), do: :none

  def memory_for(%__MODULE__{model_name_or_path: path}) do
    with name when is_binary(name) <- Memory.name_of(path),
         release when is_binary(release) <- Memory.release_of(path),
         {:ok, memory} <- Memory.load(name, release) do
      memory
    else
      _absent -> :none
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
        # The entry as the config writes it, which is what a ported sensor
        # module is built from.
        config: sensor,
        delta_thresholds: Map.get(sensor, "delta_thresholds"),
        is_surface_sm: Map.get(sensor, "is_surface_sm", false),
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

  # Where a config's simulator puts everything. Habitat's `agent_args` give the
  # agent a position and no rotation — the rotations it lists are the sensors',
  # relative to the agent — and `env_init_args.objects` give the object a place
  # 0.2 m in front of it.
  defp scene(config) do
    args = get_in(config, ["environment", "env_init_args"]) || %{}
    agent_args = get_in(args, ["agents", "agent_args"]) || %{}

    %{agent: agent_pose(agent_args), sensors: sensor_poses(agent_args), objects: objects(args)}
  end

  defp agent_pose(agent_args) do
    case Map.get(agent_args, "position") do
      [_x, _y, _z] = position ->
        %{position: position, rotation: rotation(Map.get(agent_args, "rotation"))}

      _absent ->
        nil
    end
  end

  defp sensor_poses(agent_args) do
    sensor_ids = List.wrap(Map.get(agent_args, "sensor_ids"))
    positions = List.wrap(Map.get(agent_args, "positions"))
    rotations = List.wrap(Map.get(agent_args, "rotations"))

    for {sensor_id, index} <- Enum.with_index(sensor_ids),
        [_x, _y, _z] = position <- [Enum.at(positions, index)],
        into: %{} do
      {sensor_id, %{position: position, rotation: rotation(Enum.at(rotations, index))}}
    end
  end

  defp objects(args) do
    args
    |> Map.get("objects")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = object ->
        case Map.get(object, "position") do
          [_x, _y, _z] = position -> [%{name: Map.get(object, "name"), position: position}]
          _absent -> []
        end

      _scenery ->
        []
    end)
  end

  # A rotation in a config is a `wxyz` quaternion, as the rest of this port
  # writes them. A config that has none means "not turned".
  defp rotation([w, x, y, z])
       when is_number(w) and is_number(x) and is_number(y) and is_number(z) do
    case Rotation.from_quaternion({w * 1.0, x * 1.0, y * 1.0, z * 1.0}) do
      {:ok, rotation} ->
        rotation

      {:error, reason} ->
        raise ArgumentError, "a config declares a rotation that is not one: #{inspect(reason)}"
    end
  end

  defp rotation(_absent), do: Rotation.identity()

  # What each sensor's camera is, from the agent a config asks its simulator for.
  # `resolutions` and `zooms` are listed in the agent's own sensor order, and the
  # field of view is the simulator's — 90 degrees for Habitat — unless a config
  # says otherwise, which none of Monty's do.
  defp cameras(config) do
    case get_in(config, ["environment", "env_init_args", "agents", "agent_args"]) do
      %{} = args -> cameras_of(args)
      _absent -> %{}
    end
  end

  defp cameras_of(args) do
    sensor_ids = List.wrap(Map.get(args, "sensor_ids"))
    resolutions = List.wrap(Map.get(args, "resolutions"))
    zooms = List.wrap(Map.get(args, "zooms"))
    hfov = Map.get(args, "hfov", @habitat_hfov)

    for {sensor_id, index} <- Enum.with_index(sensor_ids),
        resolution = Enum.at(resolutions, index),
        is_list(resolution) and length(resolution) == 2,
        into: %{} do
      {sensor_id,
       [resolution: List.to_tuple(resolution), zoom: Enum.at(zooms, index) || 1.0, hfov: hfov]}
    end
  end

  # The transforms an experiment configures, in the order they run. They are the
  # layer between what a simulator rendered and what a sensor module is given, so
  # a run that skips one is a different experiment (`docs/monty-bugs.md` §1.7).
  defp transforms(config) do
    config
    |> Map.get("environment", %{})
    |> Map.get("transform", [])
    |> List.wrap()
  end

  @doc """
  The configured transforms this port can build, in the order they run.

  A config may name transforms that are not ported — `DepthTo3DLocations` is the
  usual one — and those are left out rather than approximated: the run then has
  a sensor reading a depth image, and the setup says so as a finding.
  """
  @spec built_transforms(t()) :: [struct()]
  def built_transforms(%__MODULE__{transforms: configs}) do
    Enum.filter(configs, &Monty.Config.Target.implemented?/1)
    |> Enum.map(&Monty.Frameworks.EnvironmentUtils.Transforms.from_config/1)
  end

  @doc """
  The positioning procedures the experiment asks for, or why one cannot be built.

  A config that names none is Monty's "positioning is not configured": the run
  starts wherever the world put the agent.
  """
  @spec positioning_procedures(t()) ::
          {:ok, [Monty.Frameworks.Environments.PositioningProcedures.GetGoodViewFactory.t()]}
          | {:error, term()}
  def positioning_procedures(%__MODULE__{positioning: configs}) do
    Enum.reduce_while(configs, {:ok, []}, fn config, {:ok, built} ->
      case Monty.Frameworks.Environments.PositioningProcedures.GetGoodViewFactory.from_config(
             config
           ) do
        {:ok, factory} -> {:cont, {:ok, [factory | built]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  @doc """
  The experiment's recognition policy: what counts as the episode being over.

  Monty's `termination` group writes `recognition_policy` into the experiment
  config, and an experiment that names none gets `MontyIsDone`
  (`monty_experiment.py`). That default is honoured here rather than left to the
  run, so a config without a policy still ends the way it ends in Monty.
  """
  @spec recognition_policy(t()) ::
          {:ok, Monty.Experiment.RecognitionPolicy.t()} | {:error, term()}
  def recognition_policy(%__MODULE__{recognition_policy: nil}),
    do: RecognitionPolicy.MontyIsDone.new()

  def recognition_policy(%__MODULE__{recognition_policy: config}),
    do: RecognitionPolicy.from_config(config)

  @doc """
  The semantic id of the object an episode is about.

  The stand-in world has one sphere and stamps it `1` (`Scene.render/3`). Monty's
  worlds number their objects as they are added (`create_semantic_mapping`), which
  is a thing to port with the worlds themselves, not before them.
  """
  @spec target_semantic_id(t()) :: integer()
  def target_semantic_id(%__MODULE__{} = setup) do
    interface = object_interface(setup)

    case List.first(interface.object_names) do
      nil ->
        # A config that names no objects leaves the stand-in world's single
        # sphere, and the scene stamps it 1. That is a fact about the stand-in —
        # the one place in the prologue that is not Monty's arithmetic.
        1

      name ->
        Map.fetch!(interface.semantic_label_to_id, name)
    end
  end

  @doc """
  How many objects the scene has besides the target.

  Monty's single-object scenes refuse to start when positioning never reaches the
  target; a cluttered scene may give up, because a run that starts slightly off is
  still a run of the experiment. The count is the interface config's
  `num_distractors` — a list of object names means none — not a guess from the
  stand-in scene, which holds one object whatever the config says.
  """
  @spec distractors(t()) :: non_neg_integer()
  def distractors(%__MODULE__{} = setup), do: object_interface(setup).num_distractors

  @doc """
  The object interface the config describes, before any object is chosen.

  Monty's mapping starts at one, so a one-object experiment's target is 1 — the
  id the stand-in world stamps on its sphere, now derived rather than assumed.
  """
  @spec object_interface(t()) :: OneObjectPerEpisodeInterface.t()
  def object_interface(%__MODULE__{object_names: names}) do
    OneObjectPerEpisodeInterface.new(object_names: names || [])
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
       Enum.map(setup.transforms, &Monty.Studio.Setup.describe_target(get_in(&1, ["_target_"]))) ++
       [setup.attention_system])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.python)
  end

  # -- findings -------------------------------------------------------------

  defp findings(setup, monty_config, config) do
    module_findings(setup) ++
      connectivity_findings(setup, monty_config) ++
      wiring_findings(setup) ++
      memory_findings(setup) ++
      settings_findings(config)
  end

  # A run with no memory cannot recognise anything, so it says so before it
  # starts rather than reporting "no conclusion" after sixty steps. A memory
  # from another release is not that: it is a run that will recognise with
  # graphs Monty did not train for this config, which is worth knowing and not
  # worth refusing.
  @doc """
  What this setup says about the memory its run will load.

  Nothing when the config names no model, or when the model is exported from the
  release the config names. A warning when the model is exported from some other
  release — the run still starts, with graphs Monty would not have loaded for
  this config — and a louder one when nothing is exported at all, because then
  the run cannot recognise anything however long it runs.
  """
  @spec memory_findings(t()) :: [Finding.t()]
  def memory_findings(%__MODULE__{model_name_or_path: nil}), do: []

  def memory_findings(%__MODULE__{model_name_or_path: path}) do
    name = Memory.name_of(path)
    release = Memory.release_of(path)

    cond do
      Memory.available?(name, release) ->
        []

      Memory.releases_for(name) != [] ->
        [
          Finding.new(
            :warning,
            :memory_from_another_release,
            "#{name} is exported from " <>
              Enum.join(Memory.releases_for(name), ", ") <>
              ", but this config's pretrained_dir names #{inspect(release)}. The run " <>
              "uses the graphs that are here, which are not the ones Monty would " <>
              "load for this config. Export the release it names with " <>
              "scripts/sync_monty_libraries.sh --only #{name} --release #{release}.",
            "model_name_or_path"
          )
        ]

      true ->
        [
          Finding.new(
            :warning,
            :no_pretrained_memory,
            "No exported memory for #{name || path} from #{inspect(release)}: this run " <>
              "starts with an empty memory and cannot recognise anything. Export one " <>
              "with scripts/sync_monty_libraries.sh --only <model> --release <release>; " <>
              "exported here: " <>
              Enum.join(Memory.available_libraries(), ", ") <> ".",
            "model_name_or_path"
          )
        ]
    end
  end

  # One line per kind of gap about what is not ported, not one per class: a
  # fifteen-module config would otherwise bury its real findings under fifteen
  # identical notices. The names are listed, so a line is still actionable.
  #
  # Two kinds are worth telling apart, because they mean different things for a
  # run. Monty's *shell* — `Monty`, the `MontyFor*` model that owns the modules,
  # and the object-recognition experiment that owns the epoch — is deliberately
  # not a port: this project's runtime does that job (`Monty.Runtime.Step`,
  # `Monty.Studio.Run`), so those classes are named by the topology and replaced
  # on purpose. Everything else planned is a real stand-in at run time, and the
  # world is the one that changes what a run's numbers mean. A training
  # experiment is not a shell: there is no training loop here yet, and saying so
  # is the point.
  @shell_classes [
    "Monty",
    "MontyForGraphMatching",
    "MontyObjectRecognitionExperiment"
  ]

  defp module_findings(setup) do
    modules = all_modules(setup)
    unknown = Enum.filter(modules, &(&1.status == :unknown))

    planned =
      for module <- modules,
          module.status == :planned,
          module.class not in @shell_classes,
          do: module.class

    shell =
      for module <- modules,
          module.status == :planned,
          module.class in @shell_classes,
          do: module.class

    Enum.map(unknown, &unknown_module_finding/1) ++
      not_ported_finding(planned, length(modules)) ++
      shell_finding(shell, length(modules)) ++
      world_finding(setup)
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

  defp not_ported_finding(classes, _total) do
    [
      Finding.new(
        :info,
        :modules_not_ported,
        "#{length(classes)} class(es) this experiment uses are still stand-ins at run time: " <>
          Enum.join(Enum.sort(classes), ", ") <> ".",
        "monty_config"
      )
    ]
  end

  # The world is the one stand-in whose absence changes what a run's numbers
  # mean, so it is the one finding that is a warning: every step of a synthetic
  # scene is a step Monty did not take.
  defp world_finding(%__MODULE__{world: :synthetic}) do
    [
      Finding.new(
        :warning,
        :world_is_a_stand_in,
        "A run steps this port's synthetic scene, not Monty's world, so its results are not " <>
          "Monty's. Monty's own HabitatEnvironment runs out of process: set " <>
          "`config :ex_tbp_monty, world_simulator: :habitat`.",
        "monty_config"
      )
    ]
  end

  defp world_finding(%__MODULE__{world: :habitat}), do: []

  defp shell_finding([], _total), do: []

  defp shell_finding(classes, _total) do
    [
      Finding.new(
        :info,
        :modules_not_ported_shell,
        "Monty's model and experiment loop are this port's own runtime, not a port: " <>
          Enum.join(Enum.sort(classes), ", ") <>
          ". The topology they build is the config's; the classes that do the stepping are ours.",
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
  # reading of an object is not reproducible without it. Both of Monty's
  # generators are ported and a module built from its config gets the one it
  # names, so this only fires for a class this port does not have.
  defp goal_generator_findings(setup) do
    for lm <- setup.learning_modules,
        lm.goal_generator != nil,
        lm.goal_generator.status != :implemented do
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
