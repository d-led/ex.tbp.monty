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
  alias Monty.Frameworks.Environments.ObjectInitSamplers.{Default, Predefined, RandomRotation}
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Frameworks.Models.NoResetEvidenceMatching.MontyForNoResetEvidenceGraphMatching
  alias Monty.Frameworks.Models.Salience.SensorModule.SalienceSM
  alias Monty.Frameworks.Models.SensorModules.CameraSM
  alias Monty.Frameworks.Models.TwoDSensorModule
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation
  alias Monty.ModuleMap
  alias Monty.ModuleMap.StandIns
  alias Monty.Prerequisites
  alias Monty.Studio.Catalog
  alias Monty.Studio.Finding
  alias Monty.Studio.Learned
  alias Monty.Studio.Memory

  # What a Habitat camera sees across, and so what `DepthTo3DLocations` inverts.
  # Monty's agents take a resolution and a zoom and no field of view.
  @habitat_hfov 90.0

  # Where Monty's object samplers put the object when a config names no place:
  # `Predefined` and `RandomRotation` both default to it, and it is the same spot
  # the agent stands in — ten centimetres nearer the floor.
  @sampler_position [0.0, 1.5, 0.0]

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
            # Whether this config has a vote matrix at all. Monty's `null` is not
            # "every module wired to nothing": `_vote` is skipped, and a
            # one-module config never votes.
            vote_round?: true,
            epochs: %{},
            phases: %{train: false, eval: true},
            termination: %{},
            seed: nil,
            supervised_lm_ids: [],
            logging: %{output_dir: nil, run_name: nil, logger: nil, handlers: []},
            findings: [],
            positioning: [],
            object_names: nil,
            # What each phase walks, as Monty keeps them apart: an experiment can
            # train on two objects and evaluate on one, and then its training
            # epochs are twice as long as its evaluation ones.
            objects_by_phase: %{},
            # Which pose an episode shows, per phase: Monty builds a training
            # interface and an evaluation interface, and each has its own
            # `object_init_sampler`. `nil` is a config that names none — the
            # scene's own place, which is what every run here used to be.
            object_init_sampler: %{train: nil, eval: nil},
            agent_class: nil,
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

  Options: `:name`, used only for display and logging, `:world_simulator`
  (`:mujoco` or `:synthetic`), which world a run is being read for, and
  `:pretrained_dir`, the release to load pretrained models from instead of the
  one the config names — see `pretrained_dir/2`.
  """
  @spec new(map(), keyword()) :: t()
  def new(tree, opts \\ []) do
    tree = pretrained_dir(tree, Keyword.get(opts, :pretrained_dir))
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
      world: Keyword.get(opts, :world_simulator) || configured_world(),
      cameras: cameras(config),
      scene: scene(config),
      motor_system: motor_system(monty_config),
      motor_system_config: Map.get(monty_config, "motor_system_config", %{}),
      transforms: transforms(config),
      positioning: get_in(config, ["eval_env_interface_args", "positioning_procedures"]) || [],
      object_names: object_names(config),
      objects_by_phase: objects_by_phase(config),
      object_init_sampler: samplers(config),
      agent_class: agent_class_of(config),
      recognition_policy: Map.get(config, "recognition_policy"),
      model_name_or_path: Map.get(config, "model_name_or_path"),
      attention_system: describe_target(get_in(monty_config, ["attention_system", "_target_"])),
      monty_args: Map.get(monty_config, "monty_args", %{}),
      sensors: sensors,
      learning_modules: learning_modules,
      connections: connections,
      vote_round?: Map.get(monty_config, "lm_to_lm_vote_matrix") != nil,
      epochs: %{
        train: Map.get(config, "n_train_epochs"),
        eval: Map.get(config, "n_eval_epochs")
      },
      # Which halves of the experiment a run of this config is. Monty's
      # `run()` asks `do_train` and `do_eval` before either loop, and they are
      # not derivable from the epoch counts: `base_config_10distinctobj_dist_agent`
      # says `n_train_epochs: 3` with `do_train: false`, so a page that read the
      # count and announced "training" would be describing a phase the
      # experiment never runs.
      phases: %{
        train: Map.get(config, "do_train") == true,
        eval: Map.get(config, "do_eval", true) != false
      },
      # The `termination` group's limits, which are what ends an episode.
      termination: termination(Map.get(config, "recognition_policy")),
      seed: Map.get(config, "seed"),
      supervised_lm_ids: Map.get(config, "supervised_lm_ids"),
      logging: logging(config)
    }

    findings =
      findings(setup, monty_config, config, unresolved?) ++ resolution_findings(unresolved?)

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

  # The release a config names is Monty's choice; whether this machine has it is
  # the machine's. Every config now names `pretrained_ycb_v14`, and a machine
  # with v10 or v13 exported can still run — with the graphs it has, which is
  # what the `memory_from_another_release` finding says out loud. So the
  # directory is a run's input, not a rewrite of the config: the value is put in
  # before resolution, so `${constants.pretrained_dir}` interpolates to it.
  defp pretrained_dir(tree, nil), do: tree

  defp pretrained_dir(tree, directory) do
    case Map.get(tree, "constants") do
      %{} = constants ->
        Map.put(tree, "constants", Map.put(constants, "pretrained_dir", directory))

      _none ->
        tree
    end
  end

  # Only when the caller says where: `${path.tests:…}` is Monty's own tests
  # directory, which a checkout has and a release does not. Resolution that
  # cannot name it fails, and the finding below says the value is unresolved
  # rather than pointing a run at a path that does not exist.
  defp monty_root(opts), do: Keyword.get(opts, :monty_root)

  # Which world a run steps is the machine's, not the experiment's: a config
  # says nothing about whether this host can render a scene, so it stays apart
  # from the config tree and the finding below says what it means.
  #
  # MuJoCo is the default because it is the world Monty's own configs are
  # written for, and here it costs nothing: the interpreter that renders it
  # travels with the application (`config/pythonx.exs`), so no operator installs
  # anything and no download stands between a checkout and a run. The stand-in
  # is the other choice — the selector, or `world_simulator: :synthetic` — and a
  # test picks it because a sphere needs no interpreter at all.
  # `||`, not a default argument: a key that exists and is nil is "nothing
  # configured", and `Application.get_env/3` would hand that nil on as a world.
  defp configured_world, do: Application.get_env(:ex_tbp_monty, :world_simulator) || :mujoco

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
      {:ok,
       new(tree, [name: name] ++ Keyword.take(opts, [:name, :world_simulator, :pretrained_dir]))}
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
      config: entry |> Map.drop(["_target_"]) |> described()
    }
  end

  # A handler's keyword can itself name a class: a `WandbWrapper` is given its
  # `wandb_handlers` that way. Only a list is looked through — a keyword holding
  # one target is a *value* the config resolved, such as `wandb_id:
  # ${wandb.util.generate_id:}`, and describing it as a handler would be reading
  # a call as a class.
  defp described(config) do
    Map.new(config, fn {key, value} -> {key, named(value)} end)
  end

  defp named(list) when is_list(list), do: Enum.map(list, &handler_or_value/1)
  defp named(value), do: value

  defp handler_or_value(%{"_target_" => _} = entry), do: handler(entry)
  defp handler_or_value(value), do: value

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
  @model_classes %{
    "MontyForEvidenceGraphMatching" => MontyForEvidenceGraphMatching,
    "MontyForNoResetEvidenceGraphMatching" => MontyForNoResetEvidenceGraphMatching
  }

  # The learning modules this port has written, by the class a config targets.
  # Monty names one per experiment and the class decides the step, so a run built
  # from the wrong one is a run of a different experiment.
  @learning_modules %{
    "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM" =>
      EvidenceGraphLM,
    "tbp.monty.frameworks.models.no_reset_evidence_matching.NoResetEvidenceGraphLM" =>
      Monty.Frameworks.Models.NoResetEvidenceMatching.NoResetEvidenceGraphLM,
    "tbp.monty.frameworks.models.displacement_matching.DisplacementGraphLM" =>
      Monty.Frameworks.Models.DisplacementMatching.DisplacementGraphLM,
    "tbp.monty.frameworks.models.feature_location_matching.FeatureGraphLM" =>
      Monty.Frameworks.Models.FeatureLocationMatching.FeatureGraphLM,
    "tbp.monty.frameworks.models.graph_matching.GraphLM" =>
      Monty.Frameworks.Models.GraphMatching.GraphLM
  }

  @doc """
  The model a run of this setup starts.

  Monty's own class when this port has written it, this port's runtime when it
  has not — the same answer the findings give, from the same map.
  """
  @spec model_class(t()) :: module()
  def model_class(%__MODULE__{monty_class: %{class: class}}),
    do: Map.get(@model_classes, class, Monty.Runtime.Model)

  def model_class(%__MODULE__{}), do: Monty.Runtime.Model

  # The experiment classes a config may name, by Monty's name for each. A config
  # naming any other runs the base epoch, which is what `MontyExperiment` is.
  @experiment_classes %{
    "MontyObjectRecognitionExperiment" =>
      Monty.Frameworks.Experiments.ObjectRecognitionExperiments.MontyObjectRecognitionExperiment,
    "MontySupervisedObjectPretrainingExperiment" =>
      Monty.Frameworks.Experiments.PretrainingExperiments.MontySupervisedObjectPretrainingExperiment
  }

  @doc """
  The experiment class a run of this setup goes through.

  Monty's own class when this port has written it, `MontyExperiment` when it has
  not — the same answer `model_class/1` gives for a model, from the same kind of
  map. The class decides how an episode begins, so a config naming
  `MontyObjectRecognitionExperiment` is run by that class rather than beside it.
  """
  @spec experiment_class(t()) :: module()
  def experiment_class(%__MODULE__{experiment_class: %{class: class}}),
    do: Map.get(@experiment_classes, class, Monty.Frameworks.Experiments.MontyExperiment)

  def experiment_class(%__MODULE__{}), do: Monty.Frameworks.Experiments.MontyExperiment

  @doc """
  The model spec a run starts: what the config resolved to, as processes can be
  given it.

  Every configured sensor and learning module becomes a process, wired exactly
  as the config wires them — so a run is a run of *this* topology, with
  stand-in modules until the ported ones land. The experiment's own
  `monty_args` come with it: how many steps each step type must last before
  anything may conclude is a property of the run, and a model given none of
  them would check the terminal condition on its first step.

  Options: `:has_detailed_logger` — whether this run's logging wants the whole
  hypothesis space per step. It is the experiment's answer, not the config's,
  because it follows from which handlers the logging section names.
  """
  @spec model_spec(t(), atom() | String.t(), keyword()) :: map()
  def model_spec(%__MODULE__{} = setup, model_id, opts \\ []) do
    detailed? = Keyword.get(opts, :has_detailed_logger, false)
    memories = Keyword.get_lazy(opts, :memory, fn -> memories(setup) end)

    Map.merge(
      %{
        model_id: model_id,
        sensor_modules: Enum.map(setup.sensors, &sensor_module_spec/1),
        learning_modules:
          Enum.map(
            setup.learning_modules,
            &learning_module_spec(&1, Map.get(memories, &1.id, :none), detailed?)
          ),
        sm_to_lm: inputs_by_learning_module(setup, :sensor_input),
        lm_to_lm: inputs_by_learning_module(setup, :hierarchy),
        lm_to_lm_vote: vote_wiring(setup),
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

  # The sensor classes Monty's configs name — a patch is a `CameraSM`, the 2-D
  # family's is a `TwoDSensorModule`, a view finder is a transform-pipeline
  # `ExperimentSensorModule` or a `SalienceSM` that proposes where to look — and
  # the port's own module for each. One that is none of them, or one whose pieces
  # this port has not written, is a stand-in.
  defp ported_sensor_module(config) do
    [CameraSM, TwoDSensorModule, ExperimentSensorModule, SalienceSM]
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
  Which world this experiment would step, in the words a page can show.

  Neither is a second implementation of the experiment. `:mujoco` is the world
  the experiment was written for — MuJoCo, with the object its config names —
  rendered in the interpreter this application carries, so nothing has to be
  installed for it. `:synthetic` is this port's stand-in: one sphere, stepped in
  the BEAM, which exists so the runtime can be developed without a scene at all.

  Nothing a stand-in produces is a result of the experiment, and a page deciding
  whether to trust a run has to be able to say so in the header rather than in a
  warning somewhere below.
  """
  @spec world_name(t()) :: String.t()
  def world_name(%__MODULE__{world: world} = setup), do: world_name(setup, world)

  @doc """
  One of the two worlds, named in the context of this setup — which is what the
  selector offers, because a config whose environment is not MuJoCo cannot be
  given MuJoCo's scene and has to say so.
  """
  @spec world_name(t(), atom()) :: String.t()
  def world_name(_setup, :synthetic), do: "stand-in scene (Elixir, one sphere)"
  def world_name(setup, :mujoco), do: mujoco_world_name(setup)

  # An operator can configure a world this build does not carry. Saying so is
  # the whole answer; a page that crashed instead would blame itself.
  def world_name(_setup, other), do: "#{inspect(other)} (not carried by this application)"

  # The class the experiment's `environment` block names, read out of the composed
  # tree rather than guessed from the experiment's name.
  defp mujoco_world_name(%__MODULE__{environment: %{module: %{class: class}}}) do
    case class do
      "MuJoCoSimulator" -> "MuJoCo (in this application)"
      other -> "#{other} (not carried by this application)"
    end
  end

  defp mujoco_world_name(%__MODULE__{}), do: "MuJoCo (in this application)"

  @doc """
  The world a run of this experiment steps: Monty's MuJoCo simulator, or the
  stand-in.

  `:mujoco` is the world the experiment was written for. `priv/monty_py` is
  this application's own Python written against MuJoCo — the scene, the agents,
  their cameras and their actuations, mirroring Monty's `MuJoCoSimulator` and its
  agents — run in the interpreter this application carries
  (`Monty.Simulators.Mujoco.Environment`). So the scene, the agent body and the
  images are Monty's design and this build's code, and nothing of it is
  installed or fetched: it travels inside this release.

  `:synthetic` is this port's sphere, which needs no scene description and no
  interpreter, and whose numbers are nobody's but its own.

  A config that names an engine this application does not carry — Habitat-Sim,
  which exists only as a conda package for another Python and is on its way out
  of Monty — is refused here rather than given MuJoCo's simulator and allowed to
  look as if it ran.
  """
  @spec world(t(), :synthetic | :mujoco) :: Monty.Simulators.Environment.t()
  def world(%__MODULE__{} = setup, world) when is_atom(world), do: world(setup, world, 0)

  @spec world(t(), non_neg_integer()) :: Monty.Simulators.Environment.t()
  def world(%__MODULE__{} = setup, episode) when is_integer(episode),
    do: world(setup, setup.world, episode)

  @spec world(t(), non_neg_integer(), keyword()) :: Monty.Simulators.Environment.t()
  def world(%__MODULE__{} = setup, episode, opts) when is_integer(episode) and is_list(opts),
    do: world(setup, setup.world, episode, opts)

  @doc """
  The world episode `episode` of an epoch steps.

  Monty's `OneObjectPerEpisodeInterface` shows one object per episode and walks
  the list, so the episode number is what says *which* object stands in front of
  the agent — a scene built without it would show the first object in every
  episode and call that a run of ten.
  """
  @spec world(t(), :synthetic | :mujoco, non_neg_integer()) :: Monty.Simulators.Environment.t()
  def world(%__MODULE__{} = setup, world, episode) when is_atom(world),
    do: world(setup, world, episode, [])

  @doc """
  The same world, with the episode's place in its epoch and its phase.

  Options: `:epoch` (which pass over the objects this is, defaulting to the
  first) and `:phase` (`:train` or `:eval`, whose sampler decides the pose).
  Both matter: `Predefined` walks its rotations one per epoch, so a world built
  without the epoch shows every episode of a run the same side of the object.
  """
  @spec world(t(), :synthetic | :mujoco, non_neg_integer(), keyword()) ::
          Monty.Simulators.Environment.t()
  def world(%__MODULE__{} = setup, :mujoco, episode, opts) do
    case engine(setup) do
      :mujoco -> mujoco_world(setup, episode, opts)
      _not_mujoco -> raise ArgumentError, uncarried_world(setup)
    end
  end

  def world(%__MODULE__{} = setup, :synthetic, _episode, _opts) do
    Monty.Simulators.Synthetic.Environment.new(
      sensor_ids(setup),
      Monty.Simulators.Synthetic.Scene.new(
        centre: object_centre(setup),
        radius: stand_in_radius(setup)
      ),
      views: setup.cameras,
      agent: setup.scene.agent,
      sensors: setup.scene.sensors
    )
  end

  # A world this build does not carry — an operator can configure one — is
  # refused with the words a page shows, not a FunctionClauseError.
  def world(%__MODULE__{}, world, _episode, _opts) when is_atom(world) do
    raise ArgumentError,
          "#{inspect(world)} is not a world this application carries: only MuJoCo " <>
            "and the stand-in scene can be stepped here."
  end

  defp uncarried_world(%__MODULE__{environment: nil}) do
    "This experiment names no environment, so there is no world to step here. Run one whose " <>
      "config names a world this build carries."
  end

  defp uncarried_world(%__MODULE__{environment: %{module: %{class: class}}}) do
    "This experiment's world is #{class}, which this application does not carry: only " <>
      "MuJoCo and the stand-in scene can be stepped here. Step the stand-in scene to run a " <>
      "config of its shape, or run one whose world this build has."
  end

  # Monty's simulator, from the numbers the config states: the data path the
  # meshes load from, the agent its `env_init_args` names (class, start pose and
  # per-sensor camera), and the object this episode is about.
  defp mujoco_world(%__MODULE__{} = setup, episode, opts) do
    Monty.Simulators.Mujoco.Environment.new(
      data_path: data_path(setup),
      agents: [agent_spec(setup)],
      objects: object_specs(setup, episode, opts),
      sensors: sensor_ids(setup)
    )
  end

  defp agent_spec(%__MODULE__{} = setup) do
    %{
      "class" => agent_class(setup),
      "agent_id" => Monty.Simulators.Synthetic.Environment.agent_id(),
      "position" => setup.scene.agent && setup.scene.agent.position,
      "rotation" => setup.scene.agent && quaternion(setup.scene.agent.rotation),
      "sensor_configs" => sensor_specs(setup)
    }
  end

  # A sensor's camera is the experiment's — resolution and zoom from its config —
  # and its pose is the agent's own sensor pose. `semantic` is asked for unless
  # the config says otherwise: the port's `DepthTo3DLocations` builds
  # `semantic_3d` from that image, and `on_object` is read from it.
  defp sensor_specs(%__MODULE__{} = setup) do
    for {sensor_id, pose} <- setup.scene.sensors, into: %{} do
      camera = Map.get(setup.cameras, sensor_id, [])
      {height, width} = Keyword.get(camera, :resolution, {64, 64})

      {to_string(sensor_id),
       %{
         "width" => width,
         "height" => height,
         "zoom" => Keyword.get(camera, :zoom, 1.0),
         "position" => pose.position,
         "rotation" => quaternion(pose.rotation),
         "semantic" => true
       }}
    end
  end

  defp quaternion(%Rotation{} = rotation),
    do: rotation |> Rotation.to_quaternion() |> Tuple.to_list()

  # The object this episode is about, standing where the interface's own sampler
  # puts it. One object at a time is Monty's own scene: the primary target, and
  # its distractors when a config asks for any.
  defp object_specs(%__MODULE__{} = setup, episode, opts) do
    case object_name(setup, episode) do
      nil ->
        []

      name ->
        # The phase's sampler decides where the object stands and how it is
        # turned; a config that names none keeps the place the scene was drawn
        # with.
        placed = %{
          "name" => name,
          "position" => object_centre(setup),
          "semantic_id" => target_semantic_id(setup, episode)
        }

        params =
          object_params(setup, episode,
            epoch: Keyword.get(opts, :epoch, 0),
            phase: Keyword.get(opts, :phase, :eval)
          )

        [Map.merge(placed, params || %{})]
    end
  end

  @doc """
  The pose episode `episode` of `epoch` shows: Monty's `object_init_sampler`.

  `nil` when the phase's config names no sampler, which is a scene that places
  its own object and never turns it.

  The pose is what makes an epoch an epoch: a sampler that is never asked leaves
  every episode of an experiment looking at the object in one orientation, and a
  memory that learned the first of them explains all the rest.
  """
  @spec object_params(t(), non_neg_integer(), keyword()) :: map() | nil
  def object_params(%__MODULE__{} = setup, episode, opts) do
    phase = Keyword.get(opts, :phase, :eval)

    case Map.get(setup.object_init_sampler, phase) do
      nil -> nil
      sampler -> sampler.(seed_of(setup), phase, Keyword.get(opts, :epoch, 0), episode)
    end
  end

  defp seed_of(%__MODULE__{seed: seed}) when is_integer(seed), do: seed
  defp seed_of(%__MODULE__{}), do: 0

  # Monty instantiates one `object_init_sampler` per interface, so each phase
  # gets its own here. A target this port has not written is `nil` — the scene's
  # own place — rather than a sampler that draws poses Monty never drew.
  @samplers %{
    "tbp.monty.frameworks.environments.object_init_samplers.Predefined" => Predefined,
    "tbp.monty.frameworks.environments.object_init_samplers.Default" => Default,
    "tbp.monty.frameworks.environments.object_init_samplers.RandomRotation" => RandomRotation
  }

  defp samplers(config) do
    for phase <- [:train, :eval], into: %{} do
      {phase, sampler(get_in(config, ["#{phase}_env_interface_args", "object_init_sampler"]))}
    end
  end

  defp sampler(%{"_target_" => target} = args) do
    case Map.fetch(@samplers, target) do
      {:ok, Default} -> &Default.call/4
      {:ok, module} -> bound(module, sampler_options(args))
      :error -> nil
    end
  end

  defp sampler(_absent), do: nil

  defp bound(module, options),
    do: fn seed, mode, epoch, episode ->
      module.call(module.new(options), seed, mode, epoch, episode)
    end

  # The keys the three samplers take, by name: a config key is data from a file,
  # and `String.to_atom/1` on one is how a leak begins. A key the config does not
  # name is left out rather than passed as `nil`, so the sampler's own default
  # applies — `RandomRotation`, whose config names only its class, stands where
  # its `new/0` says and turns the object every episode.
  @sampler_options %{
    "positions" => :positions,
    "rotations" => :rotations,
    "scales" => :scales,
    "change_every_episode" => :change_every_episode,
    "position" => :position,
    "scale" => :scale
  }

  defp sampler_options(args) do
    for {name, option} <- @sampler_options, Map.has_key?(args, name) do
      {option, Map.fetch!(args, name)}
    end
  end

  @doc """
  The object episode `episode` of an epoch is about.

  `OneObjectPerEpisodeInterface.object_for/2` is Monty's cycle — the next name in
  the config's list, and the first again past its end — so a run of ten objects
  is ten episodes in the order the experiment wrote them. A config that names no
  object leaves the scene to the dataset, and the first mesh the machine has is
  what it holds.
  """
  @spec object_name(t(), non_neg_integer()) :: String.t() | nil
  def object_name(%__MODULE__{} = setup, episode \\ 0) do
    OneObjectPerEpisodeInterface.object_for(object_interface(setup), episode) ||
      object_label(setup)
  end

  @doc """
  The objects an epoch visits, one episode each — Monty's `object_names`.

  A config that names none is still one episode: the scene is the dataset's, and
  a run of nothing would be a run with no result.
  """
  @spec objects(t()) :: [String.t()]
  def objects(%__MODULE__{} = setup) do
    case object_interface(setup).object_names do
      [] -> List.wrap(object_name(setup, 0))
      names -> names
    end
  end

  @doc """
  The same experiment, seen from one of its phases.

  Monty builds a training interface and an evaluation interface, each with its own
  objects, and `run_epoch` walks whichever belongs to the mode it is in. A setup
  here carries one list, so what an episode of a phase is built from — the world,
  the object it shows, the semantic id stamped on it — has to come from that
  phase's list. `with_phase/2` is that setup: everything downstream keeps reading
  `object_names` and gets the right objects without knowing about phases.

  Without it, `test/evidence_lm/evidence_mujoco` walks `capsule3DSolid` twice and
  `cubeSolid` never: the epoch loop hands the second object to an episode whose
  world was built from the evaluation list.
  """
  @spec with_phase(t(), :train | :eval) :: t()
  def with_phase(%__MODULE__{} = setup, mode) do
    names = objects(setup, mode)
    %{setup | object_names: names, objects_by_phase: %{train: names, eval: names}}
  end

  @doc """
  The objects one phase of the run walks, one episode each.

  Monty keeps a training interface and an evaluation interface, and they do not
  have to name the same objects: `test/evidence_lm/evidence_mujoco` trains on
  `capsule3DSolid` and `cubeSolid` and evaluates on `capsule3DSolid`, so its
  training epochs are six episodes and its evaluation ones three. Walking the
  evaluation list in both would be a shorter experiment than the config asks
  for — and, since the second training object would never be seen, a memory with
  one object in it where Monty's has two.
  """
  @spec objects(t(), :train | :eval) :: [String.t()]
  def objects(%__MODULE__{} = setup, mode) do
    case Map.get(setup.objects_by_phase, mode, []) do
      [] -> objects(setup)
      names -> names
    end
  end

  @doc """
  How many eval epochs the run is: Monty's `n_eval_epochs`.

  A rotation experiment is the same object list walked again —
  `base_77obj_dist_agent` names `${constants.rotations_3_count}`, which is three
  walks of seventy-seven objects, not one. A config that names no count is one
  walk, which is what a single epoch is.
  """
  @spec eval_epochs(t()) :: pos_integer()
  def eval_epochs(%__MODULE__{epochs: %{eval: epochs}}) when is_integer(epochs) and epochs > 0,
    do: epochs

  def eval_epochs(%__MODULE__{}), do: 1

  @doc """
  How many train epochs the config names, or `nil` when it names none.

  Not every config that names a count trains (`do_train` decides that), and a
  training-only config — `only_surf_agent_training_10obj` — is the one place the
  count is the run itself.
  """
  @spec train_epochs(t()) :: pos_integer() | nil
  def train_epochs(%__MODULE__{epochs: %{train: epochs}}) when is_integer(epochs) and epochs > 0,
    do: epochs

  def train_epochs(%__MODULE__{}), do: nil

  @doc "Whether a run of this config trains — Monty's `do_train`."
  @spec do_train(t()) :: boolean()
  def do_train(%__MODULE__{phases: phases}), do: Map.get(phases, :train, false)

  @doc "Whether a run of this config evaluates — Monty's `do_eval`."
  @spec do_eval(t()) :: boolean()
  def do_eval(%__MODULE__{phases: phases}), do: Map.get(phases, :eval, true)

  @doc """
  The learning modules a supervised experiment states the answer for.

  Monty's `supervised_lm_ids`, where `"all"` means every module the config wires
  (`monty_experiment.py::__init__` resolves it the same way, off the config's own
  keys). An empty list is an experiment that supervises none, which is every
  recognition config.
  """
  @spec supervised_ids(t()) :: [String.t()]
  def supervised_ids(%__MODULE__{supervised_lm_ids: "all", learning_modules: modules}),
    do: Enum.map(modules, & &1.id)

  def supervised_ids(%__MODULE__{supervised_lm_ids: ids}) when is_list(ids), do: ids

  def supervised_ids(%__MODULE__{}), do: []

  @doc """
  The epochs a run of this config is, in the order Monty runs them.

  Monty's `run()` is `train()` and then `evaluate()`, each with its own mode set
  on the model and its own loop, so the answer is a list of phases rather than
  one number: `[{:eval, 14}]` for a config that only evaluates,
  `[{:train, 3}, {:eval, 14}]` for one that does both, and `[{:train, 3}]` for
  the training-only configs. A phase the config switches on but gives no count
  is left out rather than run once by accident.
  """
  @spec epoch_plan(t()) :: [{:train | :eval, pos_integer()}]
  def epoch_plan(%__MODULE__{} = setup) do
    phase(:train, do_train(setup), train_epochs(setup)) ++
      phase(:eval, do_eval(setup), eval_epochs(setup))
  end

  # A phase runs when its flag is on and its count is a count: a phase switched
  # on without one is left out rather than run once by accident.
  defp phase(name, true, count) when is_integer(count) and count > 0, do: [{name, count}]
  defp phase(_name, _on, _count), do: []

  @doc """
  The step limit the config's termination puts on one episode of `mode`.

  This is `maximum_steps` in Monty's recognition policy — `max_train_steps` while
  training, `max_eval_steps` while evaluating — and it is what a run is capped by
  unless its record asks for something shorter. `nil` means the config named no
  policy, which is the one case a page has to invent a number.
  """
  @spec max_steps(t(), :train | :eval) :: pos_integer() | nil
  def max_steps(%__MODULE__{termination: termination}, :train),
    do: Map.get(termination, :max_train_steps)

  def max_steps(%__MODULE__{termination: termination}, :eval),
    do: Map.get(termination, :max_eval_steps)

  @doc """
  The ceiling the config puts on one episode, whatever its mode.

  This is the number a page's own safety cap should be: the per-mode limits are
  the policy's to enforce, and a training episode may explore for longer than
  its matching limit — the tutorial allows one matching step and three exploring
  ones — so capping an episode at `max_train_steps` would cut a step the
  experiment asked for.
  """
  @spec max_total_steps(t()) :: pos_integer() | nil
  def max_total_steps(%__MODULE__{termination: termination}),
    do: Map.get(termination, :max_total_steps)

  # The `termination` group, as the limits it puts on an episode. Monty's policy
  # validates them when it is built; here they are read, and the policy itself
  # (`recognition_policy/1`) does the validating.
  defp termination(%{"_target_" => _policy} = policy) do
    %{
      max_train_steps: Map.get(policy, "max_train_steps"),
      max_eval_steps: Map.get(policy, "max_eval_steps"),
      max_total_steps: Map.get(policy, "max_total_steps")
    }
  end

  defp termination(_none), do: %{}

  @doc """
  How many episodes a run of this experiment is: every object, in every rotation,
  in every phase.

  `base_77obj_dist_agent` is seventy-seven objects in three rotations, so two
  hundred and thirty-one episodes — Monty's `run_epoch` inside his `evaluate`.
  An experiment that trains first is both halves: `test/evidence_lm/evidence_mujoco`
  trains on two objects for three epochs and evaluates one object for three, so
  it is nine episodes, and a budget of three would stop it in the middle of its
  training.

  A page shows this number before starting, because "run the experiment" and
  "run twelve steps" are very different promises.
  """
  @spec episodes(t()) :: pos_integer()
  def episodes(%__MODULE__{} = setup), do: planned_episodes(setup)

  @doc """
  How many episodes the whole experiment is, phases and all.

  `episodes/1` answers what a reader means by "the eval episodes"; this answers
  what a run does: every object, in every epoch of every phase the config runs,
  added up — 140 for a ten-object experiment evaluated fourteen times, and 28 for
  a two-object tutorial trained fourteen times.
  """
  @spec planned_episodes(t()) :: non_neg_integer()
  def planned_episodes(%__MODULE__{} = setup) do
    # Added up rather than handed to `Enum.sum/1`, whose type is a list of
    # numbers summing to a number: an episode count is a count, and a type that
    # admits a float invites one. Each phase counts its own objects.
    setup
    |> epoch_plan()
    |> Enum.map(fn {mode, epochs} -> length(objects(setup, mode)) * epochs end)
    |> Enum.reduce(0, &+/2)
  end

  @doc """
  The same experiment with another seed.

  The seed is the one input a run is varied by most often — a sweep over seeds
  is the simplest experiment there is — and it is the one the config cannot
  answer for a particular run. `nil` means the config's own seed, which is why
  a record that kept no seed leaves the setup alone rather than picking zero.
  """
  @spec with_seed(t(), integer() | nil) :: t()
  def with_seed(%__MODULE__{} = setup, nil), do: setup
  def with_seed(%__MODULE__{} = setup, seed), do: %{setup | seed: seed}

  @doc """
  The world the **config** was written for: `:mujoco`, `:habitat`, or `nil` when
  it names no simulator this application knows.

  Not the same question as `world`, which is the world a run of it would step
  (the operator's choice). This is what the config says, which is what decides
  whether the work it needs can be checked at all.
  """
  @spec engine(t()) :: :mujoco | :habitat | nil
  def engine(%__MODULE__{environment: %{module: %{class: "MuJoCoSimulator"}}}), do: :mujoco
  def engine(%__MODULE__{environment: %{module: %{class: "HabitatEnvironment"}}}), do: :habitat
  def engine(%__MODULE__{environment: %{module: %{class: "HabitatSim"}}}), do: :habitat
  def engine(%__MODULE__{}), do: nil

  # The class the experiment's agent is, from `env_init_args.agents` — which is
  # how Monty's own MuJoCo configs name `SurfaceAgent` or `DistantAgent`.
  defp agent_class_of(config) do
    case get_in(config, ["environment", "env_init_args", "agents"]) do
      [%{"_target_" => target} | _more] -> target |> String.split(".") |> List.last()
      _not_named -> nil
    end
  end

  # The class the experiment's agent is, from `env_init_args.agents` — which is
  # how Monty's own MuJoCo configs name `SurfaceAgent` or `DistantAgent`.
  defp agent_class(%__MODULE__{} = setup), do: setup.agent_class || "SurfaceAgent"

  defp object_label(%__MODULE__{object_names: names}) when is_list(names), do: List.first(names)
  defp object_label(_setup), do: nil

  defp data_path(%__MODULE__{environment: %{data_path: path}}) when is_binary(path), do: path
  defp data_path(%__MODULE__{}), do: nil

  # How big the stand-in's sphere is. Its *position* is the config's — where the
  # interface's sampler puts the object — so its size is what is left to choose,
  # and what it has to satisfy is how far the patch can see. A surface
  # experiment clips everything past `clip_value` and zeroes the on-surface mask
  # there, so a sphere whose surface is further than that is invisible: the module
  # never sees that it is on an object and builds no hypothesis space. So the
  # surface is put where the policy aims to keep it (`desired_object_distance`),
  # and never past half the clip, where a rounding error in the depth image could
  # put it on the wrong side of the boundary.
  #
  # A distant experiment clips nothing — it looks across the room — and there the
  # sphere is simply the scene's own size: sizing it to a surface policy's
  # standoff would shrink the object to a millimetre and lose it the same way.
  defp stand_in_radius(
         %__MODULE__{scene: %{objects: [%{position: object}], agent: %{position: agent}}} = setup
       )
       when is_list(agent) do
    gap = SpatialArithmetics.magnitude(SpatialArithmetics.subtract(agent, object))

    case patch_reach(setup) do
      nil -> Monty.Simulators.Synthetic.Scene.radius()
      reach -> max(gap - min(desired_object_distance(setup), reach / 2.0), 0.001)
    end
  end

  defp stand_in_radius(%__MODULE__{}), do: Monty.Simulators.Synthetic.Scene.radius()

  # How far a patch sees, when the experiment limits it: the `clip_value` of the
  # transform that clips depth, on the configs that clip any sensor at all.
  defp patch_reach(%__MODULE__{transforms: transforms}) do
    Enum.find_value(transforms, fn transform ->
      case Map.get(transform, "depth_clip_sensors") do
        sensors when is_list(sensors) and sensors != [] -> Map.get(transform, "clip_value")
        _no_clip -> nil
      end
    end)
  end

  defp desired_object_distance(%__MODULE__{motor_system_config: config}) do
    get_in(config, ["policy_selector", "policy", "desired_object_distance"]) || 0.025
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
  #
  # The classes are named once, in `@learning_modules`. A config naming anything
  # else reaches the stand-in, and the module map — which is where a class is
  # called `:implemented` — is what refuses the run: a registered class and a
  # status of `:implemented` are the same fact, and a test holds them together.
  defp learning_module_spec(lm, memory, detailed?) do
    target = Map.get(lm.config, "_target_")
    options = [has_detailed_logger: detailed?]
    options = if memory == :none, do: options, else: [memory: memory] ++ options

    with {:ok, module} <- learning_module_class(target),
         {:ok, state} <- module.from_config(lm.config, options) do
      %{id: lm.id, module: module, state: state}
    else
      _unknown_or_refused -> stand_in_learning_module(lm)
    end
  end

  @doc """
  The learning module class a config's `_target_` names.

  An unknown target is `:error` rather than a class that would run something
  else: a module standing in for another is a run of a different experiment, and
  the finding that refuses it comes from the module map, which is where the
  status of every class is written down.
  """
  @spec learning_module_class(String.t() | nil) :: {:ok, module()} | :error
  def learning_module_class(target), do: Map.fetch(@learning_modules, target)

  defp stand_in_learning_module(lm) do
    # Unreachable for a setup that runs: `learning_module_findings/1` refuses any
    # module this port cannot build. It answers here so that `model_spec/3` has
    # something to say about a config that will be refused anyway.
    %{
      id: lm.id,
      module: Monty.Simulators.Synthetic.LearningModule,
      state: Monty.Simulators.Synthetic.LearningModule.new(lm.id)
    }
  end

  @doc """
  Monty's pretrained memory for the model this experiment names, if exported.

  `:none` means an empty memory: the config names no model, it names no release
  to look in, or this machine has no exported library for that model from that
  release — and `memory_findings/1` says which, because a run with no memory
  cannot recognise anything however long it runs.

  `module_index` is which learning module of the pretrained model to read: a
  heterarchy's store holds one memory per module, and the high-level module's is
  not the child's.
  """
  @spec memory_for(t(), non_neg_integer()) ::
          Monty.Frameworks.Models.GraphMatching.GraphMemory.t() | :none
  def memory_for(%__MODULE__{model_name_or_path: nil}, _module_index), do: :none

  def memory_for(%__MODULE__{model_name_or_path: path}, module_index) do
    with name when is_binary(name) <- Memory.name_of(path),
         release when is_binary(release) <- Memory.release_of(path) do
      load_memory(name, release, module_index)
    else
      _absent -> :none
    end
  end

  @doc """
  The memory each learning module starts an episode from, by module id.

  A heterarchy's pretrained model holds one memory per learning module — the 3-D
  child, the 2-D child, and the high-level module that recognises a composition
  of the two — so each module reads its own. A model the port exported before the
  library carried module indices had one memory, which every module read, and
  that is what a single-module run still gets.

  A run that learns replaces this map with the one it wrote
  (`Monty.Studio.Run.memories/1`), which is how a training phase carries what one
  episode learned into the next.
  """
  @spec memories(t()) :: %{optional(atom() | String.t()) => term()}
  def memories(%__MODULE__{learning_modules: modules} = setup) do
    modules
    |> Enum.with_index()
    |> Map.new(fn {module, index} -> {module.id, memory_for(setup, index)} end)
  end

  # The release the config names, and failing that any release this machine has
  # the model exported from — which is what `memory_from_another_release` says
  # happens ("the run uses the graphs that are here"). Loading nothing while the
  # finding promised graphs would make every experiment whose config names a
  # release nobody exported here run with an empty memory: no possible matches,
  # no evidence, nothing to draw, however long it runs.
  defp load_memory(name, release, module_index) do
    case Memory.load_module(name, release, module_index) do
      {:ok, memory} -> memory
      {:error, _not_found} -> newest_exported(name, module_index)
    end
  end

  defp newest_exported(name, module_index) do
    name
    |> Memory.releases_for()
    |> Enum.reverse()
    |> Enum.reduce_while(:none, fn release, _none ->
      case Memory.load_module(name, release, module_index) do
        {:ok, memory} -> {:halt, memory}
        {:error, _not_found} -> {:cont, :none}
      end
    end)
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
          objects: scene_objects(args)
        }

      _absent ->
        nil
    end
  end

  defp interface_class(config) do
    Map.get(config, "train_env_interface_class") || Map.get(config, "eval_env_interface_class")
  end

  # Where a config's simulator puts everything. Habitat gives the agent a
  # position through `agents.agent_args`, plus the sensors' offsets relative to
  # the agent; MuJoCo gives `agents` as a list of agent objects carrying each
  # sensor's own config. Either way the agent's own pose is what the scene needs,
  # and `env_init_args.objects` give the object a place 0.2 m in front of it.
  defp scene(config) do
    args = get_in(config, ["environment", "env_init_args"]) || %{}
    agent = agent(args)
    objects = objects(args, agent, sampler_position(config))

    %{agent: agent_pose(agent, objects), sensors: sensor_poses(agent), objects: objects}
  end

  defp agent(args) do
    case Map.get(args, "agents") do
      [%{} = agent | _more] ->
        %{
          "position" => Map.get(agent, "position"),
          "rotation" => Map.get(agent, "rotation"),
          "sensor_configs" => Map.get(agent, "sensor_configs")
        }

      %{} = agents ->
        Map.get(agents, "agent_args") || %{}

      _no_agent ->
        %{}
    end
  end

  # A config that declares no rotation means "not turned" — except for a MuJoCo
  # agent, which declares none and is modelled in the MJCF file this port does
  # not read. Such an agent is aimed at the object instead: every action Monty's
  # surface policies emit is written for a body whose −z already points at it
  # (`MoveForward` closes in along that axis, `OrientHorizontal` steps sideways,
  # yaws and steps along it again to orbit), so a body left pointing at the world
  # rather than at the object would walk away from the thing it is meant to
  # inspect.
  defp agent_pose(agent_args, objects) do
    case Map.get(agent_args, "position") do
      [_x, _y, _z] = position ->
        %{
          position: position,
          rotation: facing(Map.get(agent_args, "rotation"), position, objects)
        }

      _absent ->
        nil
    end
  end

  defp facing(nil, position, objects), do: look_at(position, objects)
  defp facing(rotation, _position, _objects), do: rotation(rotation)

  # A MuJoCo agent declares its sensors instead of listing where they are: each
  # `SensorConfig` carries a `position` and a `rotation` relative to the agent,
  # which is exactly the shape a scene's sensors are in. So they are read as they
  # are — the aiming is the agent's job (`agent_pose/2`).
  defp sensor_poses(%{"sensor_configs" => %{} = configs}) do
    for {sensor_id, %{} = config} <- configs, into: %{} do
      {sensor_id,
       %{
         position: Map.get(config, "position") || [0.0, 0.0, 0.0],
         rotation: rotation(Map.get(config, "rotation"))
       }}
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

  # A sensor looks along its own −z, so the rotation that shows the object is the
  # one that turns −z onto the direction of the object.
  defp look_at(origin, [%{position: target} | _more]) do
    gaze = SpatialArithmetics.normalize(difference(target, origin))
    turn([0.0, 0.0, -1.0], gaze)
  end

  defp look_at(_origin, _no_objects) do
    {:ok, rotation} = Rotation.from_euler_degrees([-90.0, 0.0, 0.0])
    rotation
  end

  defp turn(from, to) do
    case SpatialArithmetics.cross(from, to) do
      [x, y, z] when x == 0.0 and y == 0.0 and z == 0.0 ->
        # Parallel or exactly opposite: the cross product gives no axis. Which of
        # the two it is, the dot product says — already looking at it needs no
        # turn at all, which is the usual case: a MuJoCo agent sits directly
        # above its object, and its camera already looks down that axis.
        if SpatialArithmetics.dot(from, to) < 0.0 do
          {:ok, rotation} = Rotation.from_euler_degrees([180.0, 0.0, 0.0])
          rotation
        else
          {:ok, rotation} = Rotation.from_euler_degrees([0.0, 0.0, 0.0])
          rotation
        end

      axis ->
        {:ok, rotation} =
          Rotation.from_axis_angle(
            SpatialArithmetics.normalize(axis),
            SpatialArithmetics.get_angle_between(from, to)
          )

        rotation
    end
  end

  defp difference([ax, ay, az], [bx, by, bz]), do: [ax - bx, ay - by, az - bz]

  # A MuJoCo environment lists no objects at all: its simulator loads the YCB set
  # from `data_path`, and the config only says which dataset. Where the object
  # goes is the **interface's** business — it adds one per episode and asks a
  # sampler for the pose. So the stand-in puts its sphere where that sampler would,
  # which for every sampler Monty's experiment groups name is the same place as
  # the agent, ten centimetres below it.
  #
  # That number is not decoration. A surface agent's patch reaches five
  # centimetres (`clip_value: 0.05`) and everything past it is clipped flat, so an
  # object a metre and a half away is not "far away" but *invisible*: every pixel
  # comes back at the clip distance with the on-surface mask off, `on_object` is
  # false, no hypothesis space is ever built and the run steps happily for as long
  # as you let it with nothing to match. That is what an object at the origin did.
  defp objects(args, agent, sampler_position) do
    case placed(args) do
      [] ->
        if Map.has_key?(agent, "sensor_configs"),
          do: [%{name: nil, position: sampler_position}],
          else: []

      objects ->
        objects
    end
  end

  # Where a config's interface samples its object. `Predefined` and
  # `RandomRotation` both default to `(0.0, 1.5, 0.0)`; the bare `Default` sampler
  # draws a position per episode instead, and a scene built before the draw cannot
  # say where that is — so it answers the default and the scene is a stand-in for
  # the world, not a copy of one episode of it.
  defp sampler_position(config) do
    config
    |> interface_args()
    |> Map.get("object_init_sampler", %{})
    |> case do
      %{} = sampler ->
        case Map.get(sampler, "positions") || Map.get(sampler, "position") do
          [_x, _y, _z] = position -> position
          [[_x, _y, _z] = position | _more] -> position
          _absent -> @sampler_position
        end

      _no_sampler ->
        @sampler_position
    end
  end

  defp interface_args(config),
    do:
      Map.get(config, "eval_env_interface_args") ||
        Map.get(config, "train_env_interface_args") || %{}

  defp placed(args) do
    args
    |> Map.get("objects")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{} = object ->
        case Map.get(object, "position") do
          [_x, _y, _z] = position ->
            [%{name: Map.get(object, "name"), position: position}]

          # MuJoCo places a custom object at `pos=position` and defaults that to
          # `ZERO_VECTOR`, and a MuJoCo config names its objects without a place
          # at all. Dropping them left the scene with nothing in it — and a world
          # with no object raises `ObjectNotVisibleError` on the first step, so
          # the missing place was being reported as a camera fault.
          _no_position ->
            [%{name: Map.get(object, "name"), position: [0.0, 0.0, 0.0]}]
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
    args = get_in(config, ["environment", "env_init_args"]) || %{}

    case Map.get(args, "agents") do
      [%{} = agent | _more] -> Map.get(agent, "sensor_configs") |> cameras_in_objects()
      %{} = agents -> cameras_of(Map.get(agents, "agent_args") || %{})
      _no_agent -> %{}
    end
  end

  # MuJoCo's agent object names each sensor's config, and the config carries its
  # own resolution and zoom — the same numbers, said one sensor at a time instead
  # of three parallel lists. Habitat's field of view stays the simulator's.
  defp cameras_in_objects(%{} = sensor_configs) do
    for {sensor_id, %{} = sensor_config} <- sensor_configs,
        %{"width" => width, "height" => height} = Map.get(sensor_config, "resolution"),
        into: %{} do
      {sensor_id,
       [
         resolution: {width, height},
         zoom: Map.get(sensor_config, "zoom", 1.0),
         hfov: @habitat_hfov
       ]}
    end
  end

  defp cameras_in_objects(_no_sensor_configs), do: %{}

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
  # a run that skips one is a different experiment (`docs/monty-differences.md` §1.7).
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

  Which object an episode is about is the experiment's own answer: a config that
  names ten objects runs ten episodes, one object each, and episode 3 is about
  the fourth name — `OneObjectPerEpisodeInterface.object_for/2`, which is the
  cycle Monty's `pre_episode` walks. A config that names none leaves the
  stand-in world's single sphere, which is why that case answers the id the scene
  stamps on it.

  `episode` is the index of the episode inside the epoch, not of the epoch: a run
  here is one episode, and this is what it is about.
  """
  @spec target_semantic_id(t(), non_neg_integer()) :: integer()
  def target_semantic_id(%__MODULE__{} = setup, episode \\ 0) do
    interface = object_interface(setup)

    case OneObjectPerEpisodeInterface.object_for(interface, episode) do
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

  # The objects a scene is built with, as the environment names them.
  defp scene_objects(args) do
    case Map.get(args, "objects") do
      list when is_list(list) -> Enum.map(list, &named_object/1)
      _absent -> []
    end
  end

  # The objects a config visits. Monty names them per interface, and an
  # experiment that only trains names them in the training half — the tutorial
  # trains on one object and evaluates that same object, so a run without it
  # would have nothing to look at. Nothing is read from the dataset: which meshes
  # are installed says what a machine can render, not what an experiment is made
  # of, and a run of "no objects" must be a run of no objects rather than a run of
  # whatever happened to be there first.
  defp object_names(config) do
    get_in(config, ["eval_env_interface_args", "object_names"]) ||
      get_in(config, ["train_env_interface_args", "object_names"]) ||
      []
  end

  # Each phase's list, and a phase that names none walks the other's: a config
  # that only trains names its objects in the training half, and one that only
  # evaluates names them in the evaluation half — either would otherwise be a run
  # of nothing.
  defp objects_by_phase(config) do
    train = get_in(config, ["train_env_interface_args", "object_names"]) || []
    evaluate = get_in(config, ["eval_env_interface_args", "object_names"]) || []

    %{
      train: if(train == [], do: evaluate, else: train),
      eval: if(evaluate == [], do: train, else: evaluate)
    }
  end

  defp named_object(%{"name" => name}), do: name
  defp named_object(name), do: name

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

  # Monty's `lm_to_lm_vote_matrix: null` means there is no vote round at all, not
  # that every module is wired to nothing: `_vote` is skipped, so a one-module
  # config never votes and a report of one says so. The runtime tells the two
  # apart by `nil`.
  defp vote_wiring(%__MODULE__{vote_round?: false}), do: nil
  defp vote_wiring(setup), do: inputs_by_learning_module(setup, :vote)

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

  @doc """
  Every class this setup names — the world, the model, the sensors, the learning
  modules and their collaborators, the motor system, the transforms, the
  attention system — each with this application's status for it.
  """
  @spec modules(t()) :: [module_description()]
  def modules(%__MODULE__{} = setup), do: all_modules(setup)

  @typedoc """
  What this setup names that is not simply an Elixir module that runs.

    * `:unwritten` — no module here and nothing standing in for it, so a run is
      refused;
    * `:carried` — Monty's MuJoCo classes, which the Python in `priv/monty_py`
      executes, so a MuJoCo run does run them;
    * `:shell` — the classes whose job `Monty.Runtime.*` does on purpose;
    * `:unknown` — a class the module map cannot place at all, which no stand-in
      can be written for and which is therefore refused too.
  """
  @type blocking :: %{
          unwritten: [module_description()],
          carried: [module_description()],
          shell: [String.t()],
          unknown: [module_description()]
        }

  @doc """
  What this setup names that is not simply an Elixir module that runs.

  The one home of the classification: `module_findings/1` reports it, and a
  survey counts it, so the page and a count cannot disagree about why an
  experiment is refused. A class is refused exactly when it is `:unwritten` or
  `:unknown` — missing, or a name nobody can resolve.
  """
  @spec blocking(t()) :: blocking()
  def blocking(%__MODULE__{} = setup) do
    modules = all_modules(setup)

    {shell, rest} =
      modules
      |> Enum.filter(&(&1.status == :planned))
      |> Enum.split_with(&StandIns.shell?(&1.class))

    {carried, unwritten} = Enum.split_with(rest, &runs_in_the_world?/1)

    %{
      unknown: Enum.filter(modules, &(&1.status == :unknown)),
      unwritten: unwritten,
      carried: carried,
      shell: Enum.map(shell, & &1.class)
    }
  end

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
    |> Enum.uniq_by(& &1.class)
  end

  # -- findings -------------------------------------------------------------

  defp findings(setup, monty_config, config, unresolved?) do
    module_findings(setup) ++
      learning_module_findings(setup, unresolved?) ++
      supervision_findings(setup) ++
      connectivity_findings(setup, monty_config) ++
      wiring_findings(setup) ++
      memory_findings(setup) ++
      settings_findings(config)
  end

  # A supervised experiment states the object and pose it was given, and it
  # reads them off the world's `primary_target`. The stand-in scene renders one
  # sphere and answers no target, so there is nothing to state — refused before
  # the first episode rather than after it, which is when the answer is asked
  # for.
  defp supervision_findings(%__MODULE__{
         experiment_class: %{class: "MontySupervisedObjectPretrainingExperiment"},
         world: :synthetic
       }) do
    [
      Finding.new(
        :error,
        :no_target_to_supervise,
        "A supervised experiment states the object and the pose it was given, and the " <>
          "stand-in scene cannot say what it showed. Run this experiment against " <>
          "MuJoCo, whose scene is the one its config names.",
        "monty_config"
      )
    ]
  end

  defp supervision_findings(%__MODULE__{}), do: []

  # A learning module a config names is either one this port runs or a refusal.
  # There is no third answer: the stand-in exists so that `model_spec/3` can
  # answer for an invalid setup, and a run never reaches it, because the finding
  # here has already refused the run.
  #
  # A tree that did not resolve is asked nothing about its values —
  # `resolution_findings/1` has already said they are shown as written, and every
  # question here would be answered about strings where numbers were meant.
  defp learning_module_findings(_setup, true), do: []

  defp learning_module_findings(%__MODULE__{learning_modules: modules}, false) do
    Enum.flat_map(modules, fn lm ->
      case unbuildable_reason(lm) do
        nil -> []
        reason -> [unbuildable_learning_module_finding(lm, reason)]
      end
    end)
  end

  # Why this module cannot be built, or `nil` when it can.
  #
  # A class the module map calls `:planned` is left to `module_findings/1`: the
  # same fact, said once. A class it calls `:implemented` but this setup has no
  # module for is a defect in the port, not in the config — and it is refused
  # rather than stood in for, because the alternative is a run that reports
  # numbers from a module nobody wrote.
  defp unbuildable_reason(%{config: config, module: described}) do
    case learning_module_class(Map.get(config, "_target_")) do
      {:ok, module} ->
        case module.from_config(config, []) do
          {:ok, _state} -> nil
          {:error, reason} -> reason
        end

      :error ->
        not_registered(described)
    end
  end

  # A config that names no class at all is `module_findings/1`'s to say; the same
  # for one the map does not know. Only "implemented, and no module here" is this
  # clause's.
  defp not_registered(%{status: :implemented}), do: :not_registered
  defp not_registered(_absent_or_unknown), do: nil

  defp unbuildable_learning_module_finding(lm, reason) do
    Finding.new(
      :error,
      :learning_module_not_buildable,
      "This config's learning module cannot be built here: #{why(reason)}. " <>
        "A stand-in in its place would be a different experiment.",
      Map.get(lm.config, "_target_")
    )
  end

  defp why({:unsupported_match_attribute, attribute}),
    do: ~s(matching on #{inspect(attribute)} is not ported, only "displacement" is)

  defp why(:not_registered),
    do: "the module map calls this class implemented and this setup has no module for it"

  defp why(other), do: inspect(other)

  # A training epoch used to be refused here, because this application stepped a
  # model and never kept what an episode learned: the run would explore and
  # conclude nothing, which looks like the experiment and answers none of it.
  # That is no longer what happens — a training phase hands each episode the
  # memory the last one wrote (`Jobs.Run.end_episode/4`) — so there is nothing
  # left for a finding to refuse, and a config that trains runs.

  # A run with no memory cannot recognise anything, so it does not start rather
  # than reporting "no conclusion" after sixty steps: an empty memory gives the
  # same answer to every observation, so the run is not a slower recognition but
  # no recognition at all. A memory from another release is not that: it is a run
  # that will recognise with graphs Monty did not train for this config, which is
  # worth knowing and not worth refusing.
  @doc """
  What this setup says about the memory its run will load.

  Nothing when the config names no model, or when the model is exported from the
  release the config names. A warning when the model is exported from some other
  release — the run still starts, with graphs Monty would not have loaded for
  this config. An error when nothing is exported at all: the run cannot
  recognise anything however long it runs, so it is refused with the one thing
  the reader can act on, where to fetch the memory.
  """
  @spec memory_findings(t()) :: [Finding.t()]
  # A stand-in run loads whatever memory is exported and, with none, runs on an
  # empty one (`memory_for/1` answers `:none`) — that is what "reads nothing from
  # disk" means, and it is why the stand-in is the way to see the runtime work
  # before any download. The stand-in's own warning already says its results are
  # not the experiment's; refusing it for want of a memory would take the one
  # thing on a fresh machine that works.
  def memory_findings(%__MODULE__{world: :synthetic}), do: []

  def memory_findings(%__MODULE__{model_name_or_path: path}) when path in [nil, ""], do: []

  def memory_findings(%__MODULE__{model_name_or_path: path}) do
    name = Memory.name_of(path)
    release = Memory.release_of(path)

    cond do
      # A path this port cannot read as `<release>/<model>/pretrained/` names no
      # memory to look for, so there is nothing to say about one.
      name == nil or release == nil ->
        []

      Memory.available?(name, release) ->
        []

      Memory.releases_for(name) != [] ->
        [
          Finding.new(
            :warning,
            :memory_from_another_release,
            another_release(name, release),
            "model_name_or_path"
          )
        ]

      true ->
        [
          Finding.new(
            :error,
            :no_pretrained_memory,
            "No memory this application can read for #{name}, and a run without " <>
              "one cannot recognise any object. #{where_memory_comes_from(name, release)}",
            "model_name_or_path"
          )
          |> with_memory_link(name, release)
        ]
    end
  end

  # Where the memory comes from, said only when it is known. A model an archive
  # carries is a download; a model a training run writes is not, and sending that
  # reader to the prerequisites page is a link to a file that is not there.
  defp where_memory_comes_from(name, release) do
    cond do
      archive = Prerequisites.for_model(name, release) ->
        "It is in #{archive.title}."

      trainer = Catalog.trainer_for(name) ->
        "It is what a run of #{trainer} writes — train that first."

      true ->
        "No archive carries it and no experiment here trains it."
    end
  end

  defp with_memory_link(finding, name, release) do
    case Prerequisites.for_model(name, release) do
      nil -> finding
      archive -> Finding.with_link(finding, "Download it", "/prerequisites?fetch=#{archive.id}")
    end
  end

  # The other case, said in one sentence: which memory the run will use, and the
  # release the config asked for that it is not. A page that told a reader to
  # re-export the model would be asking them to check out this repository — the
  # same page, in a container, has no `scripts/` to run.
  defp another_release(name, release) do
    exported = list(Memory.releases_for(name))

    # `trained` is not a Monty release: it is what a run of this application
    # files what it learned under, and the path the config names
    # (`…/projects/<run>/pretrained`) is Monty's own output directory, whose
    # second-to-last segment is a folder rather than a release. Comparing the two
    # would read as nonsense, so this case says what happened instead.
    if Memory.releases_for(name) == [Learned.release()] do
      "It learns from the memory a run here trained (#{Learned.release()}). The path this " <>
        "config names is Monty's output directory, which this machine does not have. " <>
        "Nothing to download or train: run it."
    else
      "It learns from #{exported}'s graphs, not from #{release}'s. This config names " <>
        "the memory #{release} trained; #{exported} is what this installation has " <>
        "exported for #{name}.#{unexported(name, release)} The run works — its numbers " <>
        "are the ones those graphs give."
    end
  end

  # "a", "a and b", "a, b and c": a list a person reads, not a list a program prints.
  defp list([one]), do: one

  defp list(many) do
    Enum.map_join(Enum.drop(many, -1), ", ", & &1) <> " and " <> List.last(many)
  end

  # The release this machine has but nobody exported to the format this
  # application reads is a second fact, and only worth its clause when it is
  # true: it is the difference between "the graphs are old" and "the graphs are
  # missing".
  defp unexported(name, release) do
    if [Monty.Prerequisites.root_path("MONTY_MODELS"), release, name, "pretrained"]
       |> Path.join()
       |> File.dir?() do
      " #{release}'s own model is on this machine, but nothing has turned it into " <>
        "the export a run reads, so it is not used."
    else
      ""
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
  #
  # Which classes those are is `Monty.ModuleMap.StandIns`, not a second list:
  # the same table goes into the generated map, so a page and a refusal cannot
  # disagree.
  defp module_findings(setup) do
    modules = modules(setup)
    blocking = blocking(setup)

    Enum.map(blocking.unknown, &unknown_module_finding/1) ++
      not_ported_finding(Enum.map(blocking.unwritten, & &1.class), length(modules)) ++
      carried_finding(setup, Enum.map(blocking.carried, & &1.class)) ++
      shell_finding(blocking.shell, length(modules)) ++
      world_finding(setup)
  end

  # A MuJoCo class is not a stand-in: the world a run steps implements it, in
  # `priv/monty_py`, so listing it would tell a reader that a scene is missing
  # when the scene is exactly what ran.
  defp runs_in_the_world?(%{python: python}), do: StandIns.in_the_world?(python)

  # Said only where it is true of the run: a MuJoCo run executes those classes.
  # A stand-in run does not execute them at all, so it has nothing to report.
  # A class whose code runs here as copied Python is not a fact about the run:
  # what a reader needs to know is which world stepped it, and `world` says that
  # in one word. The note lived on every MuJoCo page and explained ourselves.
  defp carried_finding(_setup, _classes), do: []

  defp unknown_module_finding(module) do
    Finding.new(
      :error,
      :unknown_module_class,
      "This config names a class the module map does not know, so it cannot run " <>
        "here: nothing can stand in for a name nothing can place. Monty's own " <>
        "test fakes are named this way.",
      module.python || module.class
    )
  end

  defp not_ported_finding([], _total), do: []

  # An error, not an info: a class this port has not written is not stood in for
  # any more. A run built from one would be a run of something else wearing the
  # experiment's name, and every entry point — the page's buttons, the queue,
  # `mix monty.run`, the MCP tools — asks `valid?/1` before it starts.
  defp not_ported_finding(classes, _total) do
    [
      Finding.new(
        :error,
        :modules_not_ported,
        "This experiment cannot run here. It is built from classes this application has not " <>
          "written — #{Enum.join(Enum.sort(classes), ", ")} — and a stand-in in their place " <>
          "would be a different experiment. Run one whose classes the module map lists as " <>
          "implemented.",
        "monty_config"
      )
    ]
  end

  # The world is the one stand-in whose absence changes what a run's numbers
  # mean, so it is the one finding that is a warning: every step of a synthetic
  # scene is a step Monty did not take. A MuJoCo run has the geometry its config
  # asks for, and what is left to say is which object the scene holds — a run
  # with an empty scene would otherwise look like a camera fault.
  defp world_finding(%__MODULE__{world: :synthetic}) do
    [
      Finding.new(
        :warning,
        :world_is_a_stand_in,
        "This run steps the stand-in scene — one sphere in the BEAM — so its results are not " <>
          "the experiment's. Choose MuJoCo in the selector to run it against the object its " <>
          "config names.",
        "monty_config"
      )
    ]
  end

  defp world_finding(%__MODULE__{world: :mujoco} = setup), do: mujoco_findings(setup)

  # A world this build does not carry — an operator can configure one — is said
  # plainly rather than crashing the page: the experiment's numbers come from its
  # own simulator, and this is not it.
  defp world_finding(%__MODULE__{world: world} = setup) do
    [
      Finding.new(
        :warning,
        :world_not_carried,
        "This run's world is #{world_name(setup, world)}, so its results are not the " <>
          "experiment's. Choose MuJoCo in the selector to step the world the config was " <>
          "written for.",
        "monty_config"
      )
    ]
  end

  defp mujoco_findings(%__MODULE__{} = setup) do
    case engine(setup) do
      :mujoco ->
        object_in_world_findings(setup)

      # The selector names MuJoCo and the config names its own simulator, which is
      # not the same program: `world/3` raises this sentence, and a run that has to
      # die to say it leaves a failed record where a refused run was the answer.
      _not_mujoco ->
        [Finding.new(:error, :world_not_carried, uncarried_world(setup), "environment")]
    end
  end

  # An error, not a warning: a MuJoCo run whose data path holds none of the
  # objects its config names steps a scene with nothing in it. It starts, it
  # spends the episodes, and every sensor finds no surface — which answers none
  # of the experiment's question while looking like a result. The fix is a
  # download, so the finding says which one and links where it starts.
  defp object_in_world_findings(%__MODULE__{environment: %{data_path: path}} = setup)
       when is_binary(path) do
    cond do
      # The directory itself is the first thing to say: a config whose objects
      # were never downloaded has nothing to look for *in* it, and naming the
      # directory is what tells a person which archive is missing.
      not File.dir?(path) -> [with_download(missing_data_finding(path), path)]
      object_label(setup) == nil -> [with_download(no_object_finding(path), path)]
      true -> []
    end
  end

  defp object_in_world_findings(%__MODULE__{}), do: []

  # What the run is waiting for, rather than what it is denied: these two are the
  # differences a download clears, and the link says what to do about it. One
  # line, because the second line of a warning is the one nobody reads.
  defp missing_data_finding(path) do
    Finding.new(
      :error,
      :world_data_missing,
      "Not on this machine yet: #{path}.",
      "environment.env_init_args.data_path"
    )
  end

  defp no_object_finding(path) do
    Finding.new(
      :error,
      :world_holds_no_object,
      "This world has no object in it: none of the meshes this config names is " <>
        "under #{path}, so the first sensor that looks for a surface would find " <>
        "nothing.",
      "environment.env_init_args.data_path"
    )
  end

  # A finding about a directory a prerequisite fills offers the download itself.
  # Where no entry fills it, the finding says the directory has to be put there
  # and points at the page that lists what this application can fetch: a link to
  # a download that does not exist would be worse than no link at all.
  defp with_download(%Finding{} = finding, path) do
    case Prerequisites.for_path(path) do
      nil ->
        Finding.with_link(
          finding,
          "What this application can download",
          "/prerequisites"
        )

      prerequisite ->
        Finding.with_link(
          finding,
          "Download it#{archive_size(prerequisite)}",
          "/prerequisites?fetch=#{prerequisite.id}"
        )
    end
  end

  defp archive_size(prerequisite) do
    case Prerequisites.size(prerequisite)[:archive] do
      nil -> ""
      bytes -> " (#{Humanizer.bytes(bytes, system: :binary)})"
    end
  end

  defp shell_finding([], _total), do: []

  defp shell_finding(classes, _total) do
    [
      Finding.new(
        :info,
        :modules_not_ported_shell,
        "The class that owns Monty's episode loop — " <>
          Enum.join(Enum.sort(classes), ", ") <>
          " — is replaced here, not missing: this application steps the same modules " <>
          "with `Monty.Runtime.Step` and runs the episode with `Monty.Studio.Run`.",
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

  # A sensor that feeds no learning module is not a finding: `view_finder` is
  # how every MuJoCo config keeps a wide shot and Monty never matches on it, so
  # saying it on every page passed a note about Monty's design off as a caveat
  # about the run.
  defp wiring_findings(setup) do
    unconnected_learning_modules(setup) ++ feature_findings(setup)
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
