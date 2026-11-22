defmodule Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM do
  @moduledoc """
  The learning module that recognises objects by accumulating evidence.

  Mirrors `...evidence_matching/learning_module.py::EvidenceGraphLM`, on top of
  the graph-matching base class (`graph_matching.py::GraphLM`). Monty inherits
  the base class's buffer bookkeeping, terminal conditions and vote handling;
  Elixir has no inheritance, so those live here too, in the same order the
  Python reads.

  ## What it does with a step

  1. **Percepts arrive.** Sensor percepts carry features and a location;
     learning-module percepts carry a hypothesis from below. A step with no
     features at all only *moves*: the sensor travelled, so every hypothesis
     travels with it.
  2. **Every graph's hypotheses are displaced** by the sensor's movement, as
     each hypothesis' own orientation sees it, and then **updated**: the
     observation is compared against the nodes around each hypothesis' search
     location, and the ones near the best evidence earn or lose evidence.
     (The comparison itself is `...HypothesesDisplacer`; which hypotheses get
     compared is `...HypothesesUpdater`.)
  3. **Possible matches are thresholded.** An object stays possible if its best
     hypothesis is within `x_percent_threshold` per cent of the best object.
     When nothing stands out — the evidence is flat — every object stays
     possible rather than none.
  4. **The terminal condition is checked** between steps: recognise when one
     object is left and its pose is narrowed down, give up when nothing is
     left, otherwise keep going.

  ## Why evidence is unbounded

  `past_weight` and `present_weight` both default to `1`, so evidence is a
  running sum rather than a moving average: a hypothesis that has matched four
  times is four times as convincing as one that has matched once, which is what
  makes "within 20% of the leader" a sensible rule. Monty notes a bounded
  version would be nicer to configure but performs worse, because it cannot
  remember how often it has been right.

  ## What is short-term and what is long-term

  The buffer, the hypotheses, the MLH and the terminal state belong to one
  episode and are thrown away by `reset_stm/1`. Graph memory is long-term and
  survives; `update_ltm_from_stm/1` is the only thing that writes to it, and
  only after a training episode.

  ## Differences from Monty, on purpose

    * **A learning module returns a new module** instead of mutating itself, so
      a step is a value: a test can hold two versions of the same module and see
      what one step changed.
    * **Evidence updates run for one graph at a time.** Monty's
      `use_multithreading` switch threads the per-object updates; here a round of
      them is a request (`concurrent_objects?`), because a BEAM process is not a
      thread and a task is handed a copy of what its closure holds. Each update is
      independent, so the result is identical either way, and concurrency belongs
      to whoever calls the steps rather than to the algorithm.
    * **Object ids come back sorted** (`GraphMemory`'s map order) rather than in
      the order models were learned. Only exact ties can tell the difference,
      and a tie is broken by id, which is at least stable across runs.
    * **A module that cannot read its own sensed pose does not vote** instead of
      raising: the pose is needed to translate votes into another sensor's
      frame, and a vote round is not a place to end an episode.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

  require Logger

  alias Monty.Cmp
  alias Monty.Cmp.{Goal, Message}

  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer
  alias Monty.Frameworks.Models.EvidenceMatching.GraphMemory.EvidenceGraphMemory

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule
  alias Monty.Frameworks.Models.GoalGeneration
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Frameworks.Utils.KdTree
  alias Monty.Geometry
  alias Monty.Geometry.{GazeDirection, OrientationMatrix, Rotation, SurfacePoseVectors}

  @detected_pose_width 7

  @enforce_keys [:graph_memory, :max_match_distance]
  defstruct graph_memory: nil,
            max_match_distance: nil,
            tolerances: %{},
            feature_weights: %{},
            feature_evidence_increment: 1,
            threshold_config: :all,
            x_percent_threshold: 10,
            vote_evidence_threshold: 0.8,
            past_weight: 1,
            present_weight: 1,
            vote_weight: 1,
            object_evidence_threshold: 1,
            path_similarity_threshold: 0.1,
            pose_similarity_threshold: 0.35,
            required_symmetry_evidence: 5,
            max_nneighbors: 3,
            learning_module_id: "LM_0",
            # Whether the per-object evidence updates may run concurrently —
            # Monty's `use_multithreading`, which its own configs leave at the
            # constructor's default. The name here says concurrency because a
            # BEAM process is not a thread; Monty's `false` is a debugging switch
            # there and the same numbers here, one update at a time.
            concurrent_objects?: true,
            # Whether the memory this module reads is a term other processes can
            # hold without copying it: the studio's cached library lives in
            # `:persistent_term`, and a term from there is shared with every
            # process it is sent to, while a memory the run itself built is on
            # this process's heap and would be copied once per task. The round
            # is only taken when this, `concurrent_objects?` and a run's request
            # are all true.
            #
            # A run that reads a library says so from the shell it builds its
            # modules in (`Monty.Runtime.LearningModuleServer`); a training phase
            # carries the memory its own last episode wrote, which is a heap term
            # and keeps the loop (`docs/monty-differences.md` §2.45).
            memory_shared?: false,
            # The round is Monty's own answer and the faster one, so it is what
            # an experiment gets unless it asks for the loop: `round_objects:
            # false` in a config is that request, and it is how the two shapes
            # are compared on one config (`graph_round?/1`).
            round_objects?: true,
            has_detailed_logger: false,
            hypotheses_updater_module: DefaultHypothesesUpdater,
            hypotheses_updater_options: [],
            hypotheses_updater: nil,
            mode: nil,
            buffer: nil,
            gsg: nil,
            hypotheses: %{},
            hypotheses_updater_telemetry: %{},
            possible_matches: [],
            symmetry_evidence: 0,
            terminal_state: nil,
            detected_object: nil,
            detected_pose: [nil, nil, nil, nil, nil, nil, nil],
            detected_rotation_r: nil,
            current_mlh: nil,
            previous_mlh: nil,
            primary_target: nil,
            primary_target_rotation_quat: nil,
            stepwise_target_object: nil,
            stepwise_targets_list: [],
            graph_id_to_target: %{},
            target_to_graph_id: %{}

  @type graph_id :: String.t()

  @typedoc "Monty's `ExperimentMode`: training writes memory, evaluation does not."
  @type mode :: :train | :eval | nil

  @typedoc """
  The best hypothesis of a graph, or of everything, as one record.

  `mlh_id` indexes into that graph's hypothesis space — `nil` until a space
  exists, which is why `get_current_mlh/1` has a location to refresh only when
  there is an id to refresh it from.
  """
  @type mlh :: %{
          graph_id: graph_id(),
          mlh_id: non_neg_integer() | nil,
          location: [float()],
          rotation: Rotation.t(),
          scale: number(),
          evidence: number()
        }

  @typedoc """
  What this module tells the vote round: for each object, the hypotheses worth
  voting for, plus where this module's own sensor is.
  """
  @type vote :: %{
          possible_states: %{optional(graph_id()) => [Message.t()]},
          sensed_pose_rel_body: [[float()]]
        }

  @type t :: %__MODULE__{}

  # What an experiment's config names, and what those names mean here.
  @evidence_graph_lm_target "tbp.monty.frameworks.models.evidence_matching.learning_module.EvidenceGraphLM"
  @default_max_nneighbors 3
  @hypotheses_updaters %{
    "tbp.monty.frameworks.models.evidence_matching.hypotheses_updater.DefaultHypothesesUpdater" =>
      DefaultHypothesesUpdater,
    "tbp.monty.frameworks.models.evidence_matching.burst_sampling.BurstSamplingHypothesesUpdater" =>
      Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
  }

  # -- construction --------------------------------------------------------

  @doc """
  A learning module over `memory`.

  `:max_match_distance` is how far a hypothesis' search location may sit from a
  stored node and still be compared against it; `:tolerances` and
  `:feature_weights` are keyed by input channel and then by feature.

  The memory is handed in rather than built here: what an object model can
  represent — grid resolution, node budget, size limit — is decided where
  memory is built, and a learning module reads memory rather than owning it.

  `:hypotheses_updater` names the strategy and `:hypotheses_updater_options`
  are passed to it; `:displacer` and `:scorer` are built here from the
  configuration above, so that every strategy sees the same comparison.

  `:concurrent_objects?` says whether one step's per-object updates may run at
  once, which is what Monty's `use_multithreading` asks for; `:memory_shared?`
  says the memory is the kind a task can hold without copying it
  (`Monty.Studio.Memory`), and `:round_objects?` is a run asking for the round —
  all three are needed, because the round measured no faster than the loop
  (`graph_round?/1`).

  `:gsg` is the goal generator this module will drive, and is `nil` unless an
  experiment supplies one — the same default Monty's evidence learning module
  has, which takes a generator as an argument rather than creating one.

  Pose tolerances are added if the configuration does not name them: matching
  never runs without comparing poses, so a missing pose tolerance would silently
  mean "any pose matches".

  Returns `{:error, %InvalidEvidenceThresholdConfig{}}` for an
  `:evidence_threshold_config` Monty does not define.
  """
  @spec new(GraphMemory.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%GraphMemory{} = memory, options) do
    with {:ok, threshold_config} <- threshold_config(options) do
      tolerances =
        options
        |> Keyword.get(:tolerances, %{})
        |> GraphMatchingUtils.add_pose_features_to_tolerances()

      lm = %__MODULE__{
        graph_memory: %{memory | features_to_use: matched_features(tolerances)},
        max_match_distance: Keyword.fetch!(options, :max_match_distance),
        tolerances: tolerances,
        feature_weights:
          fill_feature_weights_with_default(
            Keyword.get(options, :feature_weights, %{}),
            tolerances
          ),
        feature_evidence_increment: Keyword.get(options, :feature_evidence_increment, 1),
        threshold_config: threshold_config,
        x_percent_threshold: Keyword.get(options, :x_percent_threshold, 10),
        vote_evidence_threshold: Keyword.get(options, :vote_evidence_threshold, 0.8),
        past_weight: Keyword.get(options, :past_weight, 1),
        present_weight: Keyword.get(options, :present_weight, 1),
        vote_weight: Keyword.get(options, :vote_weight, 1),
        object_evidence_threshold: Keyword.get(options, :object_evidence_threshold, 1),
        path_similarity_threshold: Keyword.get(options, :path_similarity_threshold, 0.1),
        pose_similarity_threshold: Keyword.get(options, :pose_similarity_threshold, 0.35),
        required_symmetry_evidence: Keyword.get(options, :required_symmetry_evidence, 5),
        max_nneighbors: Keyword.get(options, :max_nneighbors, 3),
        learning_module_id: Keyword.get(options, :learning_module_id, "LM_0"),
        concurrent_objects?: Keyword.get(options, :concurrent_objects?, true),
        memory_shared?: Keyword.get(options, :memory_shared?, false),
        round_objects?: Keyword.get(options, :round_objects?, true),
        has_detailed_logger: Keyword.get(options, :has_detailed_logger, false),
        hypotheses_updater_module:
          Keyword.get(options, :hypotheses_updater, DefaultHypothesesUpdater),
        hypotheses_updater_options: Keyword.get(options, :hypotheses_updater_options, []),
        gsg: Keyword.get(options, :gsg)
      }

      {:ok, lm |> build_updater() |> reset_stm()}
    end
  end

  @doc """
  A module built from an experiment's learning-module configuration.

  Monty has no such function: Hydra instantiates the config's `_target_` with
  the group's parameters, which arrive already composed. This reads the same
  mapping — what an experiment writes under
  `monty_config.learning_modules.learning_module_0` — and builds both the module
  and the memory it learns into, so that an experiment's own numbers decide what
  runs rather than a test's.

  A target or an updater this port has not written is an error naming it, not a
  module that would answer with something else's numbers.
  """
  @spec from_config(map()) :: {:ok, t()} | {:error, term()}
  def from_config(config, options \\ []) when is_map(config) do
    with :ok <- check_target(Map.get(config, "_target_", @evidence_graph_lm_target)),
         {:ok, updater} <- updater_for(config) do
      # An empty memory unless one is handed in: Monty loads a pretrained state
      # dict into the module it has just built, which is the same thing one step
      # earlier.
      memory =
        Keyword.get_lazy(options, :memory, fn ->
          EvidenceGraphMemory.new(memory_options(config))
        end)

      with {:ok, lm} <-
             new(
               memory,
               [
                 max_match_distance: Map.get(config, "max_match_distance", 0.01),
                 tolerances: Map.get(config, "tolerances", %{}),
                 feature_weights: Map.get(config, "feature_weights", %{}),
                 learning_module_id: Map.get(config, "learning_module_id", "LM_0"),
                 max_nneighbors:
                   get_in(config, ["hypotheses_updater_args", "max_nneighbors"]) ||
                     @default_max_nneighbors,
                 hypotheses_updater: updater,
                 hypotheses_updater_options: updater_options(config),
                 gsg: goal_generator(config),
                 # The experiment's, not the config's: a run that logs detail
                 # asks its modules for it, which is Monty's
                 # `lm.has_detailed_logger` set by `init_monty_data_loggers`.
                 has_detailed_logger: Keyword.get(options, :has_detailed_logger, false)
               ] ++ module_options(config)
             ) do
        # Monty's pretrained state dict carries which object built each graph, and
        # a library here now does too (`docs/monty-differences.md` §2.27): the run
        # that trained wrote the module's own `graph_id_to_target` beside the
        # graphs. Without it an episode's statistics cannot tell a target found
        # from an object confused for one, and would call every recall an unknown
        # object. A library that carries none — a pretrained release this port did
        # not write — is read as it always was: a graph is named after the object
        # it was stored under.
        if Keyword.has_key?(options, :memory),
          do: {:ok, index_objects_for_graphs(lm, Keyword.get(options, :memory_targets, %{}))},
          else: {:ok, lm}
      end
    end
  end

  # This port's addition: Monty indexes nothing when it loads a model, because
  # its state dict carries `graph_id_to_target` beside the graphs. Here a library
  # is a separate file, so the module indexes itself from the names the library
  # recorded (`docs/monty-differences.md` §2.27).
  #
  # Both directions of the index, from what the library says each graph was built
  # from, and from the graph's own id where it says nothing.
  defp index_objects_for_graphs(%__MODULE__{} = lm, targets) do
    graph_ids = GraphMemory.get_memory_ids(lm.graph_memory)

    named =
      Map.new(graph_ids, fn graph_id ->
        {graph_id, MapSet.new(Map.get(targets, graph_id, [graph_id]))}
      end)

    %{
      lm
      | graph_id_to_target: named,
        target_to_graph_id:
          Enum.reduce(named, %{}, fn {graph_id, names}, index ->
            Enum.reduce(names, index, fn name, index ->
              Map.update(index, name, MapSet.new([graph_id]), &MapSet.put(&1, graph_id))
            end)
          end)
    }
  end

  # Monty's Hydra instantiation builds the learning module's `gsg` entry and
  # passes the object in; a module built from its own config builds the entry
  # inside it. A generator class this port has not written leaves the module
  # without one — and without goals, which is a different experiment, so
  # `Monty.Studio.Setup` reports it rather than this crashing the build.
  #
  # `gsg: null` is Monty saying there are no goals here at all: its heterarchy
  # configs write it for the sensory modules beneath the one that steers.
  defp goal_generator(%{"gsg" => entry}) when is_map(entry) do
    case GoalGeneration.from_config(entry) do
      {:ok, generator} -> generator
      {:error, _unsupported} -> nil
    end
  end

  defp goal_generator(_config), do: nil

  defp check_target(@evidence_graph_lm_target), do: :ok

  defp check_target(target), do: {:error, {:unsupported_learning_module, target}}

  defp updater_for(config) do
    case Map.get(config, "hypotheses_updater_class") do
      nil ->
        {:ok, DefaultHypothesesUpdater}

      class ->
        case Map.fetch(@hypotheses_updaters, class) do
          {:ok, module} -> {:ok, module}
          :error -> {:error, {:unsupported_hypotheses_updater, class}}
        end
    end
  end

  # Monty instantiates the module by handing its config to `__init__`, so every
  # constructor parameter a config names decides what runs. These are the ones
  # that arrive as a number, a string or a switch; a key the config does not name
  # keeps `new/2`'s default, which is Monty's own.
  @module_options [
    {"evidence_threshold_config", :evidence_threshold_config},
    # Monty's key names a Python thread; a BEAM process is not one, so the
    # option it arrives as says what it is — concurrency.
    {"use_multithreading", :concurrent_objects?},
    # This port's own key, and the only way a run asks for the *loop*: an
    # experiment's YAML may write `round_objects: false` beside
    # `use_multithreading`. No shipped config does — the round is Monty's own
    # answer and the faster one, so a run measures this port's loop shape only
    # when it says so (`graph_round?/1`).
    {"round_objects", :round_objects?},
    {"feature_evidence_increment", :feature_evidence_increment},
    {"vote_evidence_threshold", :vote_evidence_threshold},
    {"past_weight", :past_weight},
    {"present_weight", :present_weight},
    {"vote_weight", :vote_weight},
    {"object_evidence_threshold", :object_evidence_threshold},
    {"x_percent_threshold", :x_percent_threshold},
    {"path_similarity_threshold", :path_similarity_threshold},
    {"pose_similarity_threshold", :pose_similarity_threshold},
    {"required_symmetry_evidence", :required_symmetry_evidence}
  ]

  # The memory's three sizes and its graph threshold, by the same rule.
  @memory_options [
    {"graph_delta_thresholds", :graph_delta_thresholds},
    {"max_nodes_per_graph", :max_nodes_per_graph},
    {"max_graph_size", :max_graph_size},
    {"num_model_voxels_per_dim", :num_model_voxels_per_dim}
  ]

  defp module_options(config), do: present_options(@module_options, config)

  defp memory_options(config), do: present_options(@memory_options, config)

  # The updaters' own arguments, under Monty's names: what a config writes under
  # `hypotheses_updater_args` Hydra hands to the updater's constructor, so a
  # config that names a burst's length or the slope it deletes at is running that
  # burst. A key dropped here runs a different search without saying so.
  @updater_arguments [
    {"umbilical_num_poses", :umbilical_num_poses},
    {"sampling_multiplier", :sampling_multiplier},
    {"sampling_burst_duration", :sampling_burst_duration},
    {"burst_trigger_slope", :burst_trigger_slope},
    {"deletion_trigger_slope", :deletion_trigger_slope},
    {"include_telemetry", :include_telemetry}
  ]

  # The poses a run starts from are an updater argument too, and the one that
  # needs translating: a config writes Euler angles and a hypothesis space holds
  # matrices, which is the shape the informed case produces as well. A config
  # that names none keeps the updater's default, which is "informed" — hence
  # nothing here rather than `nil`, which several updaters would read as "no pose
  # at all".
  defp updater_options(config) do
    args = Map.get(config, "hypotheses_updater_args") || %{}

    fixed_poses(Map.get(args, "initial_possible_poses")) ++
      present_options(@updater_arguments, args)
  end

  defp fixed_poses(nil), do: []
  defp fixed_poses("informed"), do: []

  defp fixed_poses(poses) do
    {:ok, rotations} = GraphMatchingUtils.initial_possible_poses(poses)
    [{:initial_possible_poses, Enum.map(rotations, &Rotation.to_matrix/1)}]
  end

  # A key a config does not name is absent, not `nil`: `nil` written into a
  # number's place fails a comparison much later, in the middle of a step. `false`
  # is a value a config can name — a switch — so what is asked is whether the key
  # is there, never whether its value is truthy: `value = Map.get(...)` as a
  # comprehension filter drops every switch a config turned off, silently.
  defp present_options(pairs, config) do
    for {key, option} <- pairs,
        Map.has_key?(config, key),
        not is_nil(Map.get(config, key)),
        do: {option, Map.get(config, key)}
  end

  defp threshold_config(options) do
    LearningModule.parse_config(
      Keyword.get(options, :evidence_threshold_config, "all"),
      Keyword.get(options, :x_percent_threshold, 10)
    )
  end

  # Monty hands memory its tolerances dictionary and reads the feature names out
  # of it; here memory is told the names directly, because a tolerance is a
  # number and a feature name is not.
  defp matched_features(tolerances) do
    Map.new(tolerances, fn {channel, channel_tolerances} ->
      {channel, Map.keys(channel_tolerances)}
    end)
  end

  # Monty fills in a weight of one for every feature it has a tolerance for:
  # everything it compares counts, unless an experiment says otherwise.
  defp fill_feature_weights_with_default(feature_weights, tolerances) do
    Map.new(tolerances, fn {channel, channel_tolerances} ->
      weights = Map.get(feature_weights, channel, %{})

      filled =
        Enum.reduce(channel_tolerances, weights, fn {feature, tolerance}, weights ->
          Map.put_new_lazy(weights, feature, fn -> List.duplicate(1.0, width_of(tolerance)) end)
        end)

      {channel, filled}
    end)
  end

  # How many numbers a feature's tolerance spans — one for a scalar, as numpy's
  # `np.ones(1)` gives, and the length for a vector.
  defp width_of(tolerance) when is_list(tolerance), do: length(tolerance)
  defp width_of(_scalar), do: 1

  # The comparison the whole module rests on: one scorer, one displacer, one
  # updater, all looking at the same memory. Rebuilt whenever memory changes,
  # because each of them holds memory as data.
  defp build_updater(%__MODULE__{} = lm) do
    memory = lm.graph_memory

    scorer =
      DefaultFeatureEvidenceScorer.new(memory,
        feature_weights: lm.feature_weights,
        tolerances: lm.tolerances,
        increment: lm.feature_evidence_increment
      )

    displacer =
      HypothesesDisplacer.new(memory,
        feature_weights: lm.feature_weights,
        max_match_distance: lm.max_match_distance,
        max_nneighbors: lm.max_nneighbors,
        past_weight: lm.past_weight,
        present_weight: lm.present_weight,
        tolerances: lm.tolerances,
        feature_evidence_scorer: scorer
      )

    options = [displacer: displacer, scorer: scorer] ++ lm.hypotheses_updater_options

    updater = lm.hypotheses_updater_module.new(memory, options)

    %{lm | hypotheses_updater: {lm.hypotheses_updater_module, updater}}
  end

  @doc """
  Clears short-term memory: the buffer, the hypotheses, the MLH, the terminal
  state, and the evidence slope a burst was watching.

  Long-term memory is untouched, which is why an episode can end mid-object and
  the next one still knows what a mug looks like. Monty re-reads the feature
  arrays out of memory here, so a graph learned in an earlier episode — or
  loaded from a pretrained library — is matchable from the first step.
  """
  @impl true
  @spec reset_stm(t()) :: t()
  def reset_stm(%__MODULE__{} = lm) do
    lm
    |> Map.merge(%{
      buffer: FeatureAtLocationBuffer.new(),
      hypotheses_updater_telemetry: %{},
      terminal_state: nil,
      detected_object: nil,
      detected_pose: List.duplicate(nil, @detected_pose_width),
      detected_rotation_r: nil
    })
    |> init_from_ltm()
    |> init_EvidenceGraphLM()
    |> reset_goal_generator()
    |> build_updater()
  end

  # Monty's `init_from_ltm`: what long-term memory offers this episode — the
  # objects that are possible matches, and feature arrays read so a graph learned
  # earlier, or loaded from a pretrained library, is matchable from the first
  # step. Monty's base `reset_stm` calls this first, which is why the port does.
  defp init_from_ltm(%__MODULE__{} = lm) do
    memory = GraphMemory.initialize_feature_arrays(lm.graph_memory)

    %{
      lm
      | graph_memory: memory,
        possible_matches: EvidenceGraphMemory.get_initial_hypotheses(memory)
    }
  end

  # Monty's `_init_EvidenceGraphLM`: the short-term hypothesis space, the evidence
  # symmetry was being counted with, and the two placeholders an episode reports
  # from until the first percept arrives.
  #
  # Monty resets its hypotheses updater here. This port builds a new one, because
  # an updater is handed the feature arrays of the memory being read, and those
  # arrays are the ones `init_from_ltm/1` just rebuilt.
  defp init_EvidenceGraphLM(%__MODULE__{} = lm) do
    mlh = fresh_mlh()
    %{lm | symmetry_evidence: 0, hypotheses: %{}, current_mlh: mlh, previous_mlh: mlh}
  end

  @doc """
  Drops the buffer, and keeps everything else.

  Monty's `MontyForNoResetEvidenceGraphMatching._reset_modules_buffers` calls
  `lm.buffer.reset()` directly, between objects it has no signal for. The buffer
  is what an episode is written from and what a training episode builds a graph
  out of; the hypotheses, the MLH and the terminal state are what the run
  believes, and a run without episode boundaries keeps those.
  """
  @impl true
  @spec clear_buffers(t()) :: t()
  def clear_buffers(%__MODULE__{} = lm), do: %{lm | buffer: FeatureAtLocationBuffer.new()}

  @doc """
  Tells the module what the episode was about, as a supervised experiment knows it.

  Monty's `_pass_target_info_to_model` supervised branch: the object's name, the
  pose the ground truth reported, and the place on the model the first epoch
  found it. A pretraining episode writes whatever `detected_object` names, so
  without this a supervised phase stores nothing — the module's own matching has
  an empty memory to work from, and its answer would be `new_object0` rather than
  the name the experiment knows.
  """
  @spec supervise(t(), map(), list()) :: t()
  def supervise(%__MODULE__{} = lm, target, location_on_model) do
    {:ok, rotation} = Rotation.from_quaternion(quaternion(target))

    stats = %{
      "possible_matches" => [target["object_name"]],
      "detected_location_on_model" => location_on_model,
      "detected_location_rel_body" => target["position"],
      "detected_rotation" => target["euler_rotation"],
      "detected_scale" => target["scale"]
    }

    %{
      lm
      | detected_object: target["object_name"],
        detected_rotation_r: Rotation.invert(rotation),
        buffer: FeatureAtLocationBuffer.add_overall_stats(lm.buffer, stats)
    }
  end

  # A target carries the object's turn under two names; `quat_rotation` is the
  # `wxyz` one a rotation is built from. A target without it cannot supervise
  # anything, and failing here says which object it was.
  defp quaternion(%{"quat_rotation" => [w, x, y, z]}), do: {w, x, y, z}

  defp quaternion(target) do
    raise ArgumentError,
          "a supervised episode needs the target's quat_rotation, and " <>
            "#{inspect(target["object_name"])} has none"
  end

  @doc """
  Forgets the episode's answer and keeps the hypothesis space.

  Monty's `set_individual_ts(None)`: the conclusion, the object it named and the
  pose that came with it go; the hypotheses, their evidence and the buffer's
  statistics stay.
  """
  @impl true
  @spec clear_conclusion(t()) :: t()
  def clear_conclusion(%__MODULE__{} = lm), do: set_individual_ts(lm, nil)

  @doc """
  Forgets the hypotheses as well as the answer: the guard a training write needs.

  A module that matched on its own during a training episode concluded a guess,
  and a guess written into memory is worse than nothing learned — so the runtime
  asks this before `update_ltm_from_stm/1`, and `detected_object` being nil is
  what stops the write. The hypotheses go with it so the episode's statistics do
  not claim a match nobody made; the buffer keeps a line saying so.
  """
  @spec clear_hypotheses(t()) :: t()
  def clear_hypotheses(%__MODULE__{} = lm) do
    cleared = %{
      "detected_location_on_model" => nil,
      "detected_location_rel_body" => nil,
      "detected_rotation" => nil,
      "detected_scale" => nil
    }

    %{
      lm
      | hypotheses: %{},
        possible_matches: [],
        symmetry_evidence: 0,
        current_mlh: nil,
        previous_mlh: nil,
        detected_object: nil,
        detected_pose: List.duplicate(nil, @detected_pose_width),
        detected_rotation_r: nil,
        buffer: FeatureAtLocationBuffer.add_overall_stats(lm.buffer, cleared)
    }
  end

  @doc """
  Names this episode's object without emptying `stepwise_targets_list`.

  The stepwise list is the record of what the sensor was on at every step, and a
  run without episode boundaries keeps it across an object change — it is the
  only place that record exists.
  """
  @impl true
  @spec set_primary_target(t(), map() | nil) :: t()
  def set_primary_target(%__MODULE__{} = lm, primary_target) do
    %{
      lm
      | primary_target: Map.get(primary_target, "object_name"),
        primary_target_rotation_quat: Map.get(primary_target, "quat_rotation")
    }
  end

  # Monty resets the goal generator with the rest of the short-term memory: a
  # schedule built against another object's observations says nothing here.
  defp reset_goal_generator(%__MODULE__{gsg: nil} = lm), do: lm

  defp reset_goal_generator(%__MODULE__{} = lm) do
    %{lm | gsg: lm.gsg.__struct__.reset(lm.gsg.__struct__.point_at(lm.gsg, without_gsg(lm)))}
  end

  # The module as the goal generator should hold it: everything it reads, and
  # not the generator itself.
  #
  # The generator is handed this module and keeps it whole, so a module that
  # keeps its generator keeps the module it held one step ago as well — whose
  # generator holds the one before that, once per step for the length of the
  # episode. Monty hands over a pointer to one module that is mutated in place
  # and so has a single copy; a struct holding a struct has to be told where to
  # stop. The generator reads the buffer, the step counters and the tolerances,
  # never the generator it is itself part of.
  defp without_gsg(%__MODULE__{} = lm), do: %{lm | gsg: nil}

  defp fresh_mlh do
    %{
      graph_id: "no_observations_yet",
      mlh_id: nil,
      location: [0.0, 0.0, 0.0],
      rotation: Rotation.identity(),
      scale: 1,
      evidence: 0.0
    }
  end

  # -- steps ---------------------------------------------------------------

  @doc """
  One step of trying to recognise an object.

  A location-only step moves the hypotheses and stops there; anything else is
  buffered, matched, thresholded, and ends in either a recognition, a
  no-match, or neither.
  """
  @impl true
  @spec matching_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()} | {:error, term()}
  def matching_step(percepts, ctx, %__MODULE__{} = lm) do
    if Monty.Runtime.location_only_step?(percepts) do
      {:ok, displace_all(lm, percepts)}
    else
      # Monty asks this before the percepts are buffered, so the first step of an
      # episode has not "moved" yet and nothing is displaced.
      moved? = FeatureAtLocationBuffer.size(lm.buffer) > 0

      with {:ok, percepts} <- add_displacements(lm, percepts),
           {:ok, lm} <- store_step(lm, percepts) do
        lm = compute_possible_matches(lm, feature_percepts(percepts), moved?)
        lm = if lm.possible_matches == [], do: set_individual_ts(lm, :no_match), else: lm
        {:ok, log_stats(step_goal_generator(lm, ctx, feature_percepts(percepts)), ctx)}
      end
    end
  end

  @doc """
  A step of learning without trying to recognise: buffer the step, move on.

  Monty still displaces here for the same reason it does in a location-only
  matching step — hypotheses must stay aligned with the sensor — but never
  updates evidence, because in exploration nothing is being tested.
  """
  @impl true
  @spec exploratory_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()} | {:error, term()}
  def exploratory_step(percepts, _ctx, %__MODULE__{} = lm) do
    if Monty.Runtime.location_only_step?(percepts) do
      {:ok, displace_all(lm, percepts)}
    else
      with {:ok, percepts} <- add_displacements(lm, percepts) do
        store_step(lm, percepts)
      end
    end
  end

  @doc """
  The goals this module's goal generator proposed, and none before it has one.

  Monty only proposes after a step that processed an observation — a module
  given nothing has nothing new to look at — so this repeats the goals only
  when the step that produced them is the last one.
  """
  @impl true
  @spec propose_goals(t()) :: {[Goal.t()], t()}
  def propose_goals(%__MODULE__{gsg: nil} = lm), do: {[], lm}

  def propose_goals(%__MODULE__{} = lm) do
    if FeatureAtLocationBuffer.get_last_obs_processed(lm.buffer) do
      {lm.gsg.__struct__.output_goals(lm.gsg), lm}
    else
      {[], lm}
    end
  end

  # Monty's learning module owns its goal generator and steps it at the end of
  # every matching step. The generator is handed this module's current value
  # first: it holds a copy, and the schedule it has built up belongs to the
  # module rather than to a step of it.
  defp step_goal_generator(%__MODULE__{gsg: nil} = lm, _ctx, _percepts), do: lm

  defp step_goal_generator(%__MODULE__{} = lm, ctx, percepts) do
    gsg = lm.gsg.__struct__.point_at(lm.gsg, without_gsg(lm))
    %{lm | gsg: gsg.__struct__.step(gsg, ctx, percepts)}
  end

  @doc """
  Records how far the sensor travelled, on every percept of the step.

  The displacement is the same for the whole step — one movement of one sensor —
  and is written onto the learning-module percepts too, because a learning
  module higher in the hierarchy needs it to place what it is told.

  `{:error, :no_sensor_module_location}` when no sensor module reported a
  location: a step with no place in it cannot be indexed against the episode.
  """
  @spec add_displacements(t(), [Message.t()]) :: {:ok, [Message.t()]} | {:error, term()}
  def add_displacements(%__MODULE__{} = lm, percepts),
    do: add_displacements(lm, percepts, lm.buffer.last_location)

  @doc """
  The same, from a location the caller remembers rather than the buffer.

  Monty's `GraphLM._add_displacements` reads `self.buffer.last_location`, and
  `NoResetEvidenceGraphLM` overrides it to read its own field — because the model
  clears the buffer when the object under the sensor changes, while where the
  sensor was has to survive
  (`.../no_reset_evidence_matching.py::NoResetEvidenceGraphLM._add_displacements`).
  The location is an argument so that each class states where its own is.
  """
  @spec add_displacements(t(), [Message.t()], [float()] | nil) ::
          {:ok, [Message.t()]} | {:error, term()}
  def add_displacements(%__MODULE__{} = _lm, percepts, previous_location) do
    sensor_module_percepts = Enum.filter(percepts, &Message.from_sensor_module?/1)

    case Cmp.location_mean(sensor_module_percepts) do
      nil ->
        {:error, :no_sensor_module_location}

      location ->
        displacement =
          case previous_location do
            nil -> [0.0, 0.0, 0.0]
            previous -> Geometry.subtract(location, previous)
          end

        {:ok, Enum.map(percepts, &Message.set_displacement(&1, displacement))}
    end
  end

  defp store_step(%__MODULE__{} = lm, percepts) do
    with {:ok, buffer} <- FeatureAtLocationBuffer.append(lm.buffer, percepts) do
      buffer =
        Enum.reduce(percepts, buffer, &FeatureAtLocationBuffer.append_input_percepts(&2, &1))

      {:ok, %{lm | buffer: buffer}}
    end
  end

  defp feature_percepts(percepts), do: Enum.filter(percepts, & &1.process_features_in_lm)

  # -- matching ------------------------------------------------------------

  @doc """
  Monty's `GraphLM._compute_possible_matches`: the query this step's observation
  makes of memory, and the hypothesis space it leaves possible.

  `moved?` decides whether the observation carries a displacement with it. It is
  false for a step that has not moved yet — the first one — where a displacement
  of zero would be a measurement nobody made.

  Public because `NoResetEvidenceGraphLM` assembles Monty's own `matching_step`
  from the same steps this module's does, and states for itself when the agent
  has moved.
  """
  @spec compute_possible_matches(t(), [Message.t()], boolean()) :: t()
  def compute_possible_matches(%__MODULE__{} = lm, observations, moved?) do
    query = {
      select_features_to_use(lm, observations),
      if(moved?, do: FeatureAtLocationBuffer.current_displacement(lm.buffer))
    }

    update_possible_matches(lm, query)
  end

  @doc """
  The observed features this module matches on, by channel.

  Monty's `GraphLM._select_features_to_use`. A feature is kept when the
  configuration gives its channel a tolerance for it — an experiment that does
  not want to match on `hsv` simply does not configure an `hsv` tolerance.
  `pose_fully_defined` is the exception: it is always kept, because it decides
  how many hypotheses a node can start, and dropping it would silently halve
  the hypothesis space of every node.

  Pose vectors arrive as a matrix and are read as nine numbers, which is the
  shape the comparison works on.
  """
  @spec select_features_to_use(t(), [Message.t()]) :: %{optional(String.t()) => map()}
  def select_features_to_use(%__MODULE__{} = lm, percepts) do
    Map.new(percepts, fn percept ->
      tolerances = Map.get(lm.tolerances, percept.sender_id, %{})

      morphological = matching_features(percept.morphological_features, tolerances)
      non_morphological = matching_features(percept.non_morphological_features || %{}, tolerances)

      {percept.sender_id, Map.merge(morphological, non_morphological)}
    end)
  end

  defp matching_features(features, tolerances) do
    for {name, value} <- features, matchable?(name, tolerances), into: %{} do
      {name, flattened(value)}
    end
  end

  defp matchable?(name, tolerances),
    do: Map.has_key?(tolerances, name) or name == "pose_fully_defined"

  defp flattened(%module{value: value})
       when module in [SurfacePoseVectors, OrientationMatrix, GazeDirection],
       do: List.flatten(value)

  defp flattened(value), do: value

  defp update_possible_matches(%__MODULE__{} = lm, {features, displacement}) do
    lm = begin_step(lm)
    lm = lm |> get_all_known_object_ids() |> update_every_graph(lm, features, displacement)
    lm = end_step(lm)

    %{
      lm
      | possible_matches: threshold_possible_matches(lm, 1.0),
        previous_mlh: lm.current_mlh,
        current_mlh: calculate_most_likely_hypothesis(lm)
    }
  end

  @doc """
  Whether a step's per-object updates are taken in a round.

  Monty's answer is its `use_multithreading`, and Monty's threads share the
  memory for free, so the round is what an experiment gets. Two things can take
  it away. A BEAM process is not a thread: it is handed a copy of what its
  closure holds, so the state must be one a task can be handed — which is
  `HypothesesUpdater.narrow/2`, one object instead of the library — and the
  memory must be one a run holds once rather than per module (`memory_shared?`,
  set for the studio's cached library; a training phase carries a heap term and
  keeps the loop). And a config may ask for the loop outright with
  `round_objects: false`, which is how the two shapes are compared on one config.

  What a round is worth, this Mac, `mix monty.run --no-record`, eight steps an
  arm, interleaved, the stand-in world (so these are the model's own numbers and
  not the experiment's):

  | config                                 | loop              | round          |
  | -------------------------------------- | ----------------- | -------------- |
  | `base_config_10distinctobj_dist_agent` | 282–295 ms a step | **149–186 ms** |
  | `base_77obj_dist_agent`                | 337–345 ms a step | **95–103 ms**  |

  Three whole episodes of the ten-object config — 108 steps — are the same step
  for step in both shapes, goal counts included (123 524 each), and the model
  took 3.60 s in the loop against 1.77 s in the round. The round costs about 4 %
  more BEAM work (5 058–5 072 k reductions a step against 4 857–4 860 k on the
  five-module episode) and wins the wall clock anyway, because a step's time is
  the native work of seventy-seven objects and that runs at once.

  That was not true before the state was narrowed: handed the whole updater — the
  library and a slope tracker an object, 3 048 µs to copy against 73 µs narrowed
  after four steps of the seventy-seven-object config — the round took 965–1 346
  ms a step against the loop's 341, three to four times worse, and it is *that*
  number the earlier version of this comment reported as "the round does not
  pay". See `docs/monty-differences.md` §2.45.
  """
  @spec graph_round?(t()) :: boolean()

  def graph_round?(%__MODULE__{
        concurrent_objects?: true,
        round_objects?: true,
        memory_shared?: true
      }),
      do: true

  def graph_round?(%__MODULE__{}), do: false

  # Monty's `_update_possible_matches`: one update a graph, and — under
  # `concurrent_objects?`, which is Monty's own default outcome — one process a
  # graph, because
  # the objects share nothing. Monty says so in a comment ("the updates of
  # different objects are independent of each other"); here the independence is
  # in the data: an update reads its own graph's space and the step's threshold,
  # writes its own graph's space and tracker, and the only thing the round shares
  # is the updater state, which `merge_step/2` puts back together by graph.
  #
  # The loop is Monty's debugging path, kept for the same reason it is kept
  # there — and it is also what proves the round: both branches run the same
  # per-graph update, in the same graph order, and answer the same numbers; the
  # loop threads the updater forward and the round merges it back, so a merge
  # that dropped one object's state would show up as a difference between them.
  defp update_every_graph(graph_ids, %__MODULE__{} = lm, features, displacement) do
    if graph_round?(lm),
      do: in_a_round(graph_ids, lm, features, displacement),
      else: one_at_a_time(graph_ids, lm, features, displacement)
  end

  defp in_a_round(graph_ids, %__MODULE__{} = lm, features, displacement) do
    view = graph_view(lm)
    {module, updater} = view.hypotheses_updater

    graph_ids
    |> Enum.map(fn graph_id ->
      # Each task is handed its own object rather than the library: a task copies
      # what its closure holds, and the state as it is holds every object's data
      # and every object's tracker (`HypothesesUpdater.narrow/2`).
      {graph_id, space_of(lm, graph_id),
       %{view | hypotheses_updater: {module, module.narrow(updater, graph_id)}}}
    end)
    |> Task.async_stream(
      fn {graph_id, hypotheses, view} ->
        update_one(view, features, displacement, graph_id, hypotheses)
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, update} ->
        update

      {:exit, reason} ->
        raise RuntimeError, "a graph's evidence update stopped: #{inspect(reason)}"
    end)
    |> merge_updates(lm)
  end

  # Monty's loop, one update after another, each handed what the one before it
  # left — which is what mutating `self` in place is. There is no merge here on
  # purpose: a loop that merged its own steps could agree with a round that
  # merged wrongly, and the comparison in the tests is only worth making if the
  # two paths get to the same answer for different reasons.
  defp one_at_a_time(graph_ids, %__MODULE__{} = lm, features, displacement) do
    Enum.reduce(graph_ids, lm, fn graph_id, lm ->
      update =
        update_one(graph_view(lm), features, displacement, graph_id, space_of(lm, graph_id))

      lm
      |> put_graph_hypotheses(update)
      |> put_graph_telemetry(update)
      |> put_graph_updater(update)
    end)
  end

  defp space_of(%__MODULE__{hypotheses: hypotheses}, graph_id),
    do: Map.get(hypotheses, graph_id, Hypotheses.empty())

  # What one graph's update reads of the module: the step's evidence threshold
  # rule and the updater. Not the module — its memory and the other graphs'
  # spaces are not this update's business, and a process is handed a copy of what
  # its closure holds.
  defp graph_view(%__MODULE__{} = lm) do
    %{
      mlh_evidence: lm.current_mlh.evidence,
      threshold_config: lm.threshold_config,
      hypotheses_updater: lm.hypotheses_updater
    }
  end

  # Monty's `_update_evidence(feature, displacement, graph_id)`: one object's
  # space, from the graph's hypotheses to the updater's answer for them.
  defp update_one(view, features, displacement, graph_id, hypotheses) do
    # The stored evidence, not `get_current_mlh/1`: that one refreshes the MLH's
    # location by indexing its graph's space, and this loop replaces those
    # spaces one object at a time — so an object already behind us has been
    # pruned and the index the MLH was found at may no longer be in it. Monty
    # reads `self.current_mlh["evidence"]` here, which is the stored number.
    #
    # The hypotheses go over whole: the setting the experiments run asks the
    # column one question — its lowest value — and handing over the numbers
    # meant decoding all of them first, once per graph per step.
    update_threshold =
      LearningModule.evidence_update_threshold(
        view.threshold_config,
        view.mlh_evidence,
        hypotheses
      )

    {module, updater} = view.hypotheses_updater
    displaced = module.displace_hypotheses(updater, hypotheses, displacement)

    {updater, updated, telemetry} =
      module.update_evidence(updater, displaced, features, graph_id, update_threshold)

    # Monty keeps the hypotheses it had when the updater had nothing to do with
    # them: a graph whose channel this observation does not carry learns nothing
    # from it, and its (undisplaced) space says as much — which is why a `nil`
    # here is carried as "no answer", never as an empty space.
    %{
      graph_id: graph_id,
      hypotheses: updated,
      telemetry: telemetry,
      updater: {module, updater}
    }
  end

  # The round's answers, put back into the module in one order whichever order
  # they were produced in: each update owns one graph, so sorting by graph id
  # makes the merge independent of how many processes answered, and of when.
  # `base` is the state they all started from, which is what tells the merge
  # which keys a half changed.
  defp merge_updates(updates, %__MODULE__{hypotheses_updater: {module, base}} = lm) do
    updates
    |> Enum.sort_by(& &1.graph_id)
    |> Enum.reduce(lm, fn update, lm ->
      lm
      |> put_graph_hypotheses(update)
      |> put_graph_telemetry(update)
      |> merge_graph_updater(module, base, update)
    end)
  end

  defp put_graph_hypotheses(lm, %{graph_id: _graph_id, hypotheses: nil}), do: lm

  defp put_graph_hypotheses(lm, %{graph_id: graph_id, hypotheses: updated}),
    do: %{lm | hypotheses: Map.put(lm.hypotheses, graph_id, updated)}

  defp put_graph_telemetry(lm, %{graph_id: graph_id, telemetry: telemetry}),
    do: %{
      lm
      | hypotheses_updater_telemetry:
          put_telemetry(lm.hypotheses_updater_telemetry, graph_id, telemetry)
    }

  # The loop's way: the update was handed the state it started from and answers
  # with the next one, so its answer is the state — nothing to merge.
  defp put_graph_updater(%__MODULE__{} = lm, %{updater: updater}),
    do: %{lm | hypotheses_updater: updater}

  # The round's way: every update started from the same state, so what comes back
  # is one graph's share of it and the shares are put together.
  defp merge_graph_updater(
         %__MODULE__{hypotheses_updater: {module, updater}} = lm,
         module,
         base,
         %{
           updater: {module, update}
         }
       ),
       do: %{lm | hypotheses_updater: {module, module.merge_step(base, updater, update)}}

  defp put_telemetry(telemetry_by_graph, _graph_id, telemetry) when telemetry == %{},
    do: telemetry_by_graph

  defp put_telemetry(telemetry_by_graph, graph_id, telemetry),
    do: Map.put(telemetry_by_graph, graph_id, telemetry)

  defp begin_step(%__MODULE__{hypotheses_updater: {module, updater}} = lm) do
    %{lm | hypotheses_updater: {module, module.begin_step(updater)}}
  end

  defp end_step(%__MODULE__{hypotheses_updater: {module, updater}} = lm) do
    %{lm | hypotheses_updater: {module, module.end_step(updater)}}
  end

  @doc """
  Moves every hypothesis of every object by the sensor's movement.

  Used on location-only steps: the sensor travelled without looking, so the
  hypotheses must keep up while their evidence stays exactly as it was. The
  hypothesis ids do not change, which is why the MLH still points at the same
  hypothesis afterwards.
  """
  @spec displace_all(t(), [Message.t()]) :: t()
  def displace_all(%__MODULE__{} = lm, percepts),
    do: displace_hypotheses(lm, percepts, lm.buffer.last_location)

  @doc """
  The same, by a displacement the caller works out from its own memory of where
  the sensor was.

  `NoResetEvidenceGraphLM` overrides Monty's `_displace_hypotheses` for the same
  reason it overrides `_add_displacements`: the buffer is cleared between objects
  and the sensor's place is not. A module with no previous place has nothing to
  displace by and says so by returning itself.
  """
  @spec displace_hypotheses(t(), [Message.t()], [float()] | nil) :: t()
  def displace_hypotheses(%__MODULE__{} = lm, _percepts, nil), do: lm

  def displace_hypotheses(%__MODULE__{} = lm, percepts, previous_location) do
    case Cmp.location_mean(Enum.filter(percepts, &Message.from_sensor_module?/1)) do
      nil ->
        Logger.warning(
          "#{lm.learning_module_id} was moved without a sensor location; nothing to displace by"
        )

        lm

      location ->
        displacement = Geometry.subtract(location, previous_location)

        hypotheses =
          Map.new(lm.hypotheses, fn {graph_id, hypotheses} ->
            {module, updater} = lm.hypotheses_updater
            {graph_id, module.displace_hypotheses(updater, hypotheses, displacement)}
          end)

        %{lm | hypotheses: hypotheses, buffer: %{lm.buffer | last_location: location}}
    end
  end

  # -- what is possible ----------------------------------------------------

  @doc """
  The objects still worth considering: those whose best hypothesis is within
  `x_percent_threshold` per cent of the best object's.

  Three regimes, and the middle one is the interesting one. When the evidence
  spreads out (`std > 0.1`) or is all negative, the threshold spans the objects.
  When everything is flat *and* memory holds a single object, that object stays
  possible at zero evidence — otherwise a one-object memory could never be
  recognised, which is the situation of every first training run. With several
  objects and flat evidence, all of them stay possible: nothing yet
  distinguishes them.
  """
  @spec threshold_possible_matches(t(), number()) :: [graph_id()]
  def threshold_possible_matches(%__MODULE__{} = lm, x_percent_scale_factor \\ 1.0) do
    if GraphMemory.size(lm.graph_memory) == 0 do
      []
    else
      case evidence_for_each_graph(lm) do
        {[], _evidences} -> []
        {graph_ids, evidences} -> possible_of(lm, graph_ids, evidences, x_percent_scale_factor)
      end
    end
  end

  # Monty decides this in numpy, where one NaN in the field of evidence makes
  # every comparison against it false: the spread is not `> 0.1`, the best is
  # not `< 0`, and no hypothesis is `>= 0` — so the answer falls through to "no
  # object is ruled out" rather than to a threshold that cannot be computed.
  # This port's NaN is `nil` (a kernel's column reads one back as `nil`, and so
  # does an unscored node's evidence), and Elixir's term order would have
  # answered *true* to each of those comparisons, so each one asks for a number
  # first.
  defp possible_of(%__MODULE__{} = lm, graph_ids, evidences, x_percent_scale_factor) do
    max_evidence = Enum.max(evidences)

    cond do
      spread_out?(evidences) or negative?(max_evidence) ->
        threshold = threshold(lm, max_evidence, x_percent_scale_factor)
        keep_where(graph_ids, evidences, &(number?(&1) and &1 > threshold))

      GraphMemory.size(lm.graph_memory) == 1 ->
        keep_where(graph_ids, evidences, &(number?(&1) and &1 >= 0))

      true ->
        graph_ids
    end
  end

  defp spread_out?(evidences) do
    case Monty.Math.population_std(evidences) do
      spread when is_number(spread) -> spread > 0.1
      _not_a_number -> false
    end
  end

  defp negative?(value), do: number?(value) and value < 0
  defp number?(value), do: is_number(value)

  defp threshold(lm, max_evidence, x_percent_scale_factor) do
    if number?(max_evidence) and max_evidence > 0 do
      max_evidence - max_evidence / 100 * lm.x_percent_threshold * x_percent_scale_factor
    else
      0.0
    end
  end

  defp keep_where(graph_ids, evidences, keep?) do
    for {graph_id, evidence} <- Enum.zip(graph_ids, evidences), keep?.(evidence), do: graph_id
  end

  @doc """
  The highest evidence of each object that has any hypotheses, alongside the
  ids those belong to.

  A module that has not started matching yet has no hypothesis space at all, and
  answers with the sentinel `{"patch_off_object", [0.0]}` — Monty's way of
  saying "nothing was observed" so that callers do not treat "no candidate" as
  "the candidate is the empty string".
  """
  @spec evidence_for_each_graph(t()) :: {[graph_id()], [number()]}
  def evidence_for_each_graph(%__MODULE__{} = lm) do
    graph_ids = get_all_known_object_ids(lm)

    if graph_ids == [] or not Map.has_key?(lm.hypotheses, hd(graph_ids)) do
      {["patch_off_object"], [0.0]}
    else
      graph_ids
      |> Enum.flat_map(fn graph_id ->
        case Map.get(lm.hypotheses, graph_id) do
          %Hypotheses{evidence: <<>>} -> []
          %Hypotheses{} = hypotheses -> [{graph_id, Hypotheses.max_evidence(hypotheses)}]
          nil -> []
        end
      end)
      |> Enum.unzip()
    end
  end

  @doc """
  Every object the memory knows about.

  A module built without a memory knows none — the state Monty's own
  constructor leaves it in, and the one an episode's statistics are read from
  when an episode ended before anything was loaded.
  """
  @spec get_all_known_object_ids(t()) :: [graph_id()]
  def get_all_known_object_ids(%__MODULE__{graph_memory: nil}), do: []

  def get_all_known_object_ids(%__MODULE__{} = lm),
    do: GraphMemory.get_memory_ids(lm.graph_memory)

  @doc """
  The model stored for `model_id`, or one input channel of it.

  `nil` returns everything memory holds for the object, keyed by channel; a
  channel returns just that channel's model. Monty names this after graphs
  because that is all memory used to hold, and keeps the name because the
  callers read it as "the thing I compare against".
  """
  @spec get_graph(t(), graph_id(), String.t() | :first | nil) ::
          %{optional(String.t()) => Monty.Frameworks.Models.ObjectModel.model()}
          | Monty.Frameworks.Models.ObjectModel.model()
  def get_graph(%__MODULE__{} = lm, model_id, input_channel \\ nil),
    do: GraphMemory.get_graph(lm.graph_memory, model_id, input_channel)

  @doc "Monty has no scale detection yet; every object is at scale one."
  @spec get_object_scale(t(), graph_id()) :: 1
  def get_object_scale(%__MODULE__{}, _graph_id), do: 1

  @doc "The objects currently possible, in memory order."
  @spec get_possible_matches(t()) :: [graph_id()]
  def get_possible_matches(%__MODULE__{} = lm), do: lm.possible_matches

  @doc """
  The current most likely hypothesis, with its location refreshed.

  The location is read back from the hypothesis space so that it reflects any
  displacement since the MLH was computed — a location-only step moves the
  hypothesis but not its identity, so the stored index still points at it.
  """
  @spec get_current_mlh(t()) :: mlh()
  def get_current_mlh(%__MODULE__{current_mlh: mlh} = lm) do
    with id when not is_nil(id) <- mlh.mlh_id,
         %Hypotheses{} = hypotheses <- Map.get(lm.hypotheses, mlh.graph_id) do
      %{mlh | location: Hypotheses.location(hypotheses, id)}
    else
      _not_a_live_hypothesis -> mlh
    end
  end

  @doc """
  The most likely hypothesis, of one object or of all of memory.

  With no hypothesis space anywhere, the answer is the current MLH with the
  graph id `"new_object0"` — Monty's way of saying "there are no observations"
  without inventing an object that was seen.
  """
  @spec calculate_most_likely_hypothesis(t(), graph_id() | nil) :: mlh()
  def calculate_most_likely_hypothesis(lm, graph_id \\ nil)

  def calculate_most_likely_hypothesis(%__MODULE__{} = lm, graph_id) when is_binary(graph_id) do
    lm
    |> best_of(graph_id)
    |> finish_mlh(lm)
  end

  def calculate_most_likely_hypothesis(%__MODULE__{} = lm, nil) do
    lm
    |> get_all_known_object_ids()
    |> Enum.reduce(nil, fn graph_id, best -> better(best, best_of(lm, graph_id)) end)
    |> finish_mlh(lm)
  end

  defp best_of(%__MODULE__{} = lm, graph_id) do
    case Map.get(lm.hypotheses, graph_id) do
      %Hypotheses{evidence: <<>>} ->
        nil

      %Hypotheses{} = hypotheses ->
        get_mlh_dict_from_id(lm, graph_id, Hypotheses.argmax_evidence(hypotheses))

      nil ->
        nil
    end
  end

  # The index of the second highest value, or `nil` when there is no second.
  # Ties keep the first object in memory order, which is the order
  # `get_all_known_object_ids/1` gives.
  defp better(nil, candidate), do: candidate

  # A hypothesis with no evidence holds NaN, and numpy's `NaN > x` is false:
  # it never displaces anything. Elixir's `<`/`>` are term order, in which every
  # atom sorts after every number, so a plain `>` let the NaN win — and the
  # threshold it was then read from was computed over nothing at all.
  defp better(%{evidence: best}, %{evidence: candidate} = candidate_mlh)
       when is_number(best) and is_number(candidate) and candidate > best,
       do: candidate_mlh

  defp better(current, _candidate), do: current

  # Monty's `_get_current_mlh`: nothing to compute, so answer with what the
  # module last believed. Its default names `"new_object0"`, and every key the
  # current hypothesis has — the name included — replaces that default. A module
  # nothing was ever seen through keeps the default and invents no object.
  defp finish_mlh(nil, %__MODULE__{current_mlh: nil}), do: empty_mlh()

  defp finish_mlh(nil, %__MODULE__{} = lm), do: get_current_mlh(lm)

  defp finish_mlh(mlh, %__MODULE__{}), do: mlh

  @spec empty_mlh() :: mlh()
  defp empty_mlh,
    do: %{
      graph_id: "new_object0",
      mlh_id: nil,
      location: [0.0, 0.0, 0.0],
      rotation: Rotation.identity(),
      scale: 1,
      evidence: 0
    }

  @doc "The most likely hypothesis of one object, whether or not it is the best overall."
  @spec get_mlh_for_object(t(), graph_id()) :: mlh()
  def get_mlh_for_object(%__MODULE__{} = lm, graph_id),
    do: calculate_most_likely_hypothesis(lm, graph_id)

  @doc """
  How many hypotheses the module holds for one object.

  Monty's goal generator reads `_hypotheses[graph_id].evidence` for this, and
  its own comment marks the reach as a temporary measure. Here it is a question
  the module answers: one hypothesis cannot be separated from itself, which is
  the whole reason the goal generator asks.
  """
  @spec num_hypotheses(t(), graph_id()) :: non_neg_integer()
  def num_hypotheses(%__MODULE__{} = lm, graph_id) do
    case Map.get(lm.hypotheses, graph_id) do
      %Hypotheses{} = hypotheses -> Hypotheses.count(hypotheses)
      nil -> 0
    end
  end

  defp get_mlh_dict_from_id(%__MODULE__{} = lm, graph_id, id) do
    hypotheses = Map.fetch!(lm.hypotheses, graph_id)

    %{
      graph_id: graph_id,
      mlh_id: id,
      location: Hypotheses.location(hypotheses, id),
      rotation: rotation_of(Hypotheses.pose(hypotheses, id)),
      scale: get_object_scale(lm, graph_id),
      evidence: Hypotheses.evidence_at(hypotheses, id)
    }
  end

  # A hypothesis pose was built from a rotation, so it converts back without
  # loss; a matrix that does not is a bug in how hypotheses were built.
  defp rotation_of(pose) do
    {:ok, rotation} = Rotation.from_matrix(pose)
    rotation
  end

  @doc """
  The two most likely objects, for a goal generator deciding whether to
  discriminate between objects or narrow down one object's pose.

  `{nil, nil}` when there is nothing to discriminate yet, and `{id, nil}` when
  memory holds a single object — the second element is what tells a goal
  generator to work on pose.

  Monty's `argsort` gives the same answer, and then corrects for ties against
  the current MLH, because a goal generator expects `argmax` and `argsort` to
  agree on which object is on top. With three objects tied, the current MLH is
  reported as the leader and the runner-up stays whoever it was.
  """
  @spec get_top_two_mlh_ids(t()) :: {graph_id() | nil, graph_id() | nil}
  def get_top_two_mlh_ids(%__MODULE__{} = lm) do
    {graph_ids, evidences} = evidence_for_each_graph(lm)

    cond do
      graph_ids == [] or hd(graph_ids) == "patch_off_object" ->
        {nil, nil}

      length(graph_ids) == 1 ->
        {hd(graph_ids), nil}

      true ->
        ranked =
          graph_ids
          |> Enum.zip(evidences)
          |> Enum.with_index()
          |> Enum.sort_by(fn {{_graph_id, evidence}, index} -> {evidence, index} end)
          |> Enum.map(fn {{graph_id, _evidence}, _index} -> graph_id end)

        [second_id, top_id] = Enum.take(ranked, -2)
        reconcile_top_two(lm, top_id, second_id)
    end
  end

  defp reconcile_top_two(%__MODULE__{} = lm, top_id, second_id) do
    current_id = get_current_mlh(lm).graph_id

    cond do
      top_id == current_id -> {top_id, second_id}
      second_id == current_id -> {second_id, top_id}
      true -> {current_id, second_id}
    end
  end

  @doc """
  The best and second-best hypotheses of one object.

  `{best, nil}` when the object has a single hypothesis: there is no second
  best, and Monty's `argsort(...)[-2]` would index past the end of a one-element
  array. Monty raises there, so this is a deviation as well as a defect —
  `docs/monty-differences.md` §1.4 and §2.6.
  """
  @spec get_top_two_pose_hypotheses_for_graph_id(t(), graph_id()) :: {mlh(), mlh() | nil}
  def get_top_two_pose_hypotheses_for_graph_id(%__MODULE__{} = lm, graph_id) do
    best = calculate_most_likely_hypothesis(lm, graph_id)
    hypotheses = Map.fetch!(lm.hypotheses, graph_id)

    case Hypotheses.second_argmax_evidence(hypotheses) do
      nil -> {best, nil}
      id -> {best, get_mlh_dict_from_id(lm, graph_id, id)}
    end
  end

  @doc """
  The indices of the hypotheses of `object_id` whose evidence is within
  `x_percent_threshold` per cent of the best one, once the best is convincing.

  Nothing is possible while the best hypothesis is still below
  `object_evidence_threshold`: an object whose every explanation is weak has
  not been recognised, whatever the spread of its hypotheses.
  """
  @spec get_possible_hypothesis_ids(t(), graph_id()) :: [non_neg_integer()]
  def get_possible_hypothesis_ids(%__MODULE__{} = lm, object_id) do
    # The whole question — the best of the column, the band under it, and which
    # hypotheses are inside it — is one pass over the bytes. It used to decode
    # the column, take a maximum of the values and filter them again, once per
    # object per step.
    lm.hypotheses
    |> Map.fetch!(object_id)
    |> Hypotheses.indices_within(lm.x_percent_threshold, lm.object_evidence_threshold)
  end

  @doc """
  Poses per object, narrowed to nothing here but reported for logging.

  Evidence matching narrows hypotheses by evidence rather than by keeping a
  path per object, so this is the whole hypothesis space — with euler angles
  for a reader, or the raw matrices for a chart.
  """
  @spec get_possible_poses(t(), boolean()) :: %{optional(graph_id()) => list()}
  def get_possible_poses(%__MODULE__{} = lm, as_euler \\ true) do
    Map.new(lm.hypotheses, fn {graph_id, hypotheses} ->
      poses =
        if as_euler do
          Enum.map(Hypotheses.poses(hypotheses), fn pose ->
            pose
            |> rotation_of()
            |> Rotation.invert()
            |> Rotation.to_euler_degrees(5)
          end)
        else
          Hypotheses.poses(hypotheses)
        end

      {graph_id, poses}
    end)
  end

  # -- the terminal condition ---------------------------------------------

  @doc """
  Decides what this episode has concluded, if anything.

  Recognition needs one object left *and* a pose narrow enough to name, or
  enough repeated evidence that the object is symmetric — in which case no
  single rotation is right and every one of them is. Anything else keeps the
  episode going; a module that had concluded "match" and no longer can takes
  that back.
  """
  @spec update_terminal_condition(t()) ::
          {t(), Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.terminal_state()}
  @impl true
  def update_terminal_condition(%__MODULE__{} = lm) do
    lm = if length(lm.possible_matches) == 1, do: lm, else: clear_possible(lm)
    lm = check_terminal_condition(lm)
    {lm, lm.terminal_state}
  end

  defp check_terminal_condition(%__MODULE__{} = lm) do
    observed? = FeatureAtLocationBuffer.get_num_observations_on_object(lm.buffer) > 0

    case lm.possible_matches do
      [] ->
        lm = set_individual_ts(lm, :no_match)
        if observed?, do: record_last_location(lm), else: lm

      [object_id] when observed? ->
        {lm, pose} = get_unique_pose_if_available(lm, object_id)

        cond do
          pose != nil ->
            Monty.Trace.trace("#{lm.learning_module_id} recognised #{object_id}")
            set_individual_ts(lm, :match)

          lm.terminal_state == :match ->
            set_individual_ts(lm, nil)

          true ->
            Monty.Trace.trace("pose of #{object_id} is not narrowed down yet")
            lm
        end

      _several_or_unobserved ->
        if lm.terminal_state == :match, do: set_individual_ts(lm, nil), else: lm
    end
  end

  defp record_last_location(%__MODULE__{} = lm) do
    %{
      lm
      | buffer:
          FeatureAtLocationBuffer.add_overall_stats(lm.buffer, %{
            "detected_location_rel_body" => FeatureAtLocationBuffer.current_location(lm.buffer)
          })
    }
  end

  defp clear_possible(%__MODULE__{} = lm) do
    %{
      lm
      | hypotheses:
          Map.new(lm.hypotheses, fn {id, %Hypotheses{} = hypotheses} ->
            {id,
             %Hypotheses{
               hypotheses
               | possible: List.duplicate(false, Hypotheses.count(hypotheses))
             }}
          end)
    }
  end

  @doc """
  Records that this module has concluded something, and what it concluded.

  Monty's `set_individual_ts`: a match also settles the detected pose, which is
  what a training episode stores its graph against. Any other conclusion clears
  the pose, so a module that takes a match back does not keep claiming it.
  """
  @spec set_individual_ts(t(), :match | :no_match | :time_out | :pose_time_out | nil) :: t()
  def set_individual_ts(%__MODULE__{} = lm, terminal_state) do
    lm = set_detected_object(lm, terminal_state)

    buffer =
      if terminal_state == :match do
        FeatureAtLocationBuffer.set_individual_ts(lm.buffer, lm.detected_object, lm.detected_pose)
      else
        FeatureAtLocationBuffer.set_individual_ts(lm.buffer, nil, nil)
      end

    lm = %{lm | buffer: buffer}

    if terminal_state == :match do
      Monty.Trace.trace(fn ->
        "#{lm.learning_module_id} detected #{lm.detected_object} at " <>
          "#{inspect(Enum.take(lm.detected_pose, 3))} rotated " <>
          "#{inspect(Enum.slice(lm.detected_pose, 3, 3))}"
      end)
    end

    lm
  end

  @doc """
  Names the object this episode is about, from the conclusion and the memory.

  A match names the single possible object; a no-match names a new object, so a
  training episode has somewhere to store what it saw; a time-out names
  nothing, because a guess is not worth storing. In evaluation a time-out names
  the most likely object when its evidence is convincing — an evaluation wants
  to know what the module believed when the clock ran out, while training must
  not learn from it.
  """
  @spec set_detected_object(t(), :match | :no_match | :time_out | :pose_time_out | nil) :: t()
  def set_detected_object(%__MODULE__{} = lm, terminal_state) do
    %{lm | terminal_state: terminal_state, detected_object: detected_object(lm, terminal_state)}
  end

  defp detected_object(%__MODULE__{}, nil), do: nil

  defp detected_object(%__MODULE__{} = lm, terminal_state)
       when terminal_state == :no_match or lm.possible_matches == [] do
    if terminal_state in [:time_out, :pose_time_out] do
      # A timed-out module without possible matches has nothing to add to
      # memory, and several modules on one object can time out independently.
      nil
    else
      "new_object#{GraphMemory.size(lm.graph_memory)}"
    end
  end

  defp detected_object(%__MODULE__{} = lm, :match), do: hd(lm.possible_matches)

  defp detected_object(%__MODULE__{mode: :eval} = lm, terminal_state)
       when terminal_state in [:time_out, :pose_time_out] do
    mlh = get_current_mlh(lm)
    if mlh.evidence > lm.object_evidence_threshold, do: mlh.graph_id
  end

  defp detected_object(%__MODULE__{}, _terminal_state), do: nil

  # -- is one pose left? ---------------------------------------------------

  @doc """
  The chosen pose of `object_id`, if the hypotheses have narrowed to one.

  Two ways to be finished: every possible hypothesis agrees on where the object
  is and how it is turned, or the same alternatives have survived long enough
  that the object is symmetric and any of them will do. Both settle
  `detected_pose`, which is the seven numbers a training episode stores and an
  evaluation scores.

  Returns `{lm, nil}` while the pose is still ambiguous — the hypotheses stay
  possible, and a later step may narrow them.
  """
  @spec get_unique_pose_if_available(t(), graph_id()) :: {t(), [number()] | nil}
  def get_unique_pose_if_available(%__MODULE__{} = lm, object_id) do
    possible_ids = get_possible_hypothesis_ids(lm, object_id)

    case possible_ids do
      [] ->
        {mark_possible(lm, object_id, []), nil}

      possible_ids ->
        mlh = get_current_mlh(lm)
        hypotheses = Map.fetch!(lm.hypotheses, object_id)

        pose_is_unique = check_for_unique_poses?(lm, hypotheses, possible_ids, mlh.rotation)

        {lm, symmetry_detected} =
          check_for_symmetry(
            lm,
            possible_indices(hypotheses),
            possible_ids,
            # A step that saw nothing new cannot be evidence of symmetry.
            FeatureAtLocationBuffer.get_last_obs_processed(lm.buffer)
          )

        lm = mark_possible(lm, object_id, possible_ids)

        if pose_is_unique or symmetry_detected do
          settle_pose(lm, object_id, mlh, possible_ids, symmetry_detected)
        else
          Monty.Trace.trace("#{object_id} is detected but its pose is not resolved yet")
          {lm, nil}
        end
    end
  end

  defp check_for_unique_poses?(%__MODULE__{} = lm, hypotheses, ids, most_likely_rotation) do
    locations = Enum.map(ids, &Hypotheses.location(hypotheses, &1))
    center = centroid(locations)
    distances = Enum.map(locations, &norm(Geometry.subtract(&1, center)))

    # How far apart the possible rotations are, measured as the angle each
    # needs to turn into the most likely one.
    most_likely_matrix = Rotation.to_matrix(most_likely_rotation)

    turns =
      Enum.map(ids, fn id ->
        pose = Hypotheses.pose(hypotheses, id)
        cosine = (trace(Geometry.mul(Geometry.transpose(most_likely_matrix), pose)) - 1) / 2
        :math.acos(Monty.Math.clip(cosine, -1.0, 1.0))
      end)

    Enum.max(distances) < lm.path_similarity_threshold and
      Enum.max(turns) <= lm.pose_similarity_threshold
  end

  defp centroid(locations), do: Enum.zip_with(locations, &Monty.Math.mean/1)

  defp trace([[a, _b, _c], [_d, e, _f], [_g, _h, i]]), do: a + e + i

  defp norm(vector), do: vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

  defp possible_indices(%Hypotheses{possible: possible}) do
    for {value, index} <- Enum.with_index(possible), value, do: index
  end

  defp mark_possible(%__MODULE__{} = lm, object_id, ids) do
    %Hypotheses{} = hypotheses = Map.fetch!(lm.hypotheses, object_id)
    keep = MapSet.new(ids)

    possible =
      for {_value, index} <- Enum.with_index(hypotheses.possible), do: MapSet.member?(keep, index)

    %{
      lm
      | hypotheses:
          Map.put(lm.hypotheses, object_id, %Hypotheses{hypotheses | possible: possible})
    }
  end

  defp settle_pose(%__MODULE__{} = lm, object_id, mlh, possible_ids, symmetry_detected?) do
    inverse = Rotation.invert(mlh.rotation)
    euler = inverse |> Rotation.to_euler_degrees(3) |> Enum.map(&wrap_degrees/1)
    pose_and_scale = mlh.location ++ euler ++ [mlh.scale]

    Monty.Trace.trace(fn -> "(location, rotation, scale): #{inspect(pose_and_scale)}" end)

    stats = %{
      "detected_path" => mlh.location,
      "detected_location_on_model" => mlh.location,
      "detected_location_rel_body" => lm.buffer.last_location,
      "detected_rotation" => euler,
      "detected_rotation_quat" => Rotation.to_xyzw(inverse),
      # Monty has no scale detection yet; the field is here so a pose has seven
      # numbers, and so a scale-carrying model could fill it in later.
      "detected_scale" => 1
    }

    stats =
      if symmetry_detected? do
        hypotheses = Map.fetch!(lm.hypotheses, object_id)

        Map.merge(stats, %{
          "symmetric_rotations" => Enum.map(possible_ids, &Hypotheses.pose(hypotheses, &1)),
          "symmetric_locations" => Enum.map(possible_ids, &Hypotheses.location(hypotheses, &1))
        })
      else
        stats
      end

    {%{
       lm
       | detected_pose: pose_and_scale,
         detected_rotation_r: mlh.rotation,
         buffer: FeatureAtLocationBuffer.add_overall_stats(lm.buffer, stats)
     }, pose_and_scale}
  end

  # Monty rounds to three decimals and then wraps into [0, 360), so a rotation
  # of -0.001 reads as 0.0 and one of 359.999 reads as 359.999 rather than
  # -0.001.
  defp wrap_degrees(degrees) do
    wrapped = :math.fmod(degrees, 360)
    wrapped = if wrapped < 0, do: wrapped + 360, else: wrapped

    # numpy's `% 360` turns -0.0 into 0.0; IEEE arithmetic only does that on a
    # sum, and a logged `-0.0` reads like a different rotation.
    wrapped + 0.0
  end

  @doc """
  Counts how long the same hypotheses have stayed possible.

  A symmetric object cannot be told from a rotated copy of itself, so its
  alternatives survive every step. Counting consecutive steps where at least
  90% of the possible hypotheses were possible last step is how Monty decides
  that this is symmetry rather than slowness, and after
  `required_symmetry_evidence` such steps it accepts the pose it has.
  """
  @spec check_for_symmetry(t(), [non_neg_integer()], [non_neg_integer()], boolean()) ::
          {t(), boolean()}
  def check_for_symmetry(%__MODULE__{} = lm, last_possible_ids, possible_ids, increment_evidence?) do
    if last_possible_ids == [] do
      {lm, false}
    else
      lm =
        if increment_evidence?,
          do: count_symmetry_evidence(lm, last_possible_ids, possible_ids),
          else: lm

      {lm, enough_symmetry_evidence_accumulated?(lm)}
    end
  end

  defp count_symmetry_evidence(%__MODULE__{} = lm, last_possible_ids, possible_ids) do
    overlap = MapSet.intersection(MapSet.new(last_possible_ids), MapSet.new(possible_ids))

    if MapSet.size(overlap) / length(possible_ids) > 0.9 do
      %{lm | symmetry_evidence: lm.symmetry_evidence + 1}
    else
      # Consecutive steps only: one step of churn and the count starts again.
      %{lm | symmetry_evidence: 0}
    end
  end

  @doc "Whether the same alternatives have survived long enough to call it symmetry."
  @spec enough_symmetry_evidence_accumulated?(t()) :: boolean()
  def enough_symmetry_evidence_accumulated?(%__MODULE__{} = lm),
    do: lm.symmetry_evidence >= lm.required_symmetry_evidence

  # -- voting --------------------------------------------------------------

  @doc """
  What this module has to say in a vote round, or `nil`.

  Only hypotheses whose *scaled* evidence clears `vote_evidence_threshold` are
  sent: a module that is unsure must not drag another module's evidence down.
  Scaling puts every module's evidence in `[-1, 1]` so that a module which has
  matched for twenty steps does not drown out one which has matched for three.

  A module that has seen nothing this step stays silent — Monty's rule, and the
  reason a vote is a statement about *this* observation.
  """
  @impl true
  @spec send_out_vote(t()) :: {vote() | nil, t()}
  def send_out_vote(%__MODULE__{} = lm) do
    if FeatureAtLocationBuffer.get_num_observations_on_object(lm.buffer) < 1 or
         not FeatureAtLocationBuffer.get_last_obs_processed(lm.buffer) do
      # Either nothing has arrived yet, or this step brought nothing new to say.
      {nil, lm}
    else
      case FeatureAtLocationBuffer.get_current_pose(lm.buffer) do
        {:ok, sensed_pose} ->
          {%{possible_states: possible_states(lm), sensed_pose_rel_body: sensed_pose}, lm}

        {:error, reason} ->
          Logger.warning(
            "#{lm.learning_module_id} cannot read its own sensed pose (#{inspect(reason)}); not voting"
          )

          {nil, lm}
      end
    end
  end

  defp possible_states(%__MODULE__{} = lm) do
    evidences =
      Map.new(lm.hypotheses, fn {graph_id, hypotheses} ->
        {graph_id, Hypotheses.evidence(hypotheses)}
      end)

    evidences
    |> GraphMatchingUtils.scaled_evidences()
    |> Enum.flat_map(fn {graph_id, scaled} ->
      hypotheses = Map.fetch!(lm.hypotheses, graph_id)

      for {evidence, id} <- Enum.with_index(scaled), evidence > lm.vote_evidence_threshold do
        {graph_id, vote_message(lm, hypotheses, id, evidence)}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp vote_message(%__MODULE__{} = lm, hypotheses, id, evidence) do
    {:ok, message} =
      Message.new(
        location: Hypotheses.location(hypotheses, id),
        morphological_features: %{
          # The pose as the hypothesis holds it, not its transpose: a receiver
          # turns the sensor displacement by this matrix, and a transposed one
          # turns it by the inverse rotation, so every hypothesis would be heard
          # in a frame nobody is standing in. Monty's #1288 is this line.
          "pose_vectors" => %OrientationMatrix{value: Hypotheses.pose(hypotheses, id)},
          "pose_fully_defined" => true
        },
        non_morphological_features: %{},
        confidence: evidence,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: lm.learning_module_id,
        sender_type: :lm
      )

    message
  end

  @doc """
  Weighs another module's hypotheses into this module's evidence.

  Each incoming hypothesis lands near the hypotheses it agrees with: for every
  hypothesis of ours, the closest votes within `max_match_distance` are
  considered, and the best of them is averaged in (or added, when evidence is
  unbounded). A vote for somewhere we are not is simply not for us — the
  hypothesis keeps the evidence it had.

  Monty finds the closest votes with a KD-tree; this asks the same index the same
  question, so a hypothesis costs the logarithm of the vote count rather than the
  count.
  """
  @impl true
  @spec receive_votes(%{optional(graph_id()) => [Message.t()]}, t()) :: {:ok, t()}
  def receive_votes(votes, %__MODULE__{} = lm) do
    if votes == %{} or FeatureAtLocationBuffer.get_num_observations_on_object(lm.buffer) == 0 do
      {:ok, lm}
    else
      lm = Enum.reduce(votes, lm, &apply_votes(&2, &1))

      lm = %{
        lm
        | possible_matches: threshold_possible_matches(lm, 1.0),
          current_mlh: calculate_most_likely_hypothesis(lm)
      }

      {:ok, lm}
    end
  end

  defp apply_votes(%__MODULE__{} = lm, {graph_id, votes}) do
    case Map.fetch(lm.hypotheses, graph_id) do
      {:ok, hypotheses} ->
        %{
          lm
          | hypotheses:
              Map.put(lm.hypotheses, graph_id, update_evidence_with_vote(lm, hypotheses, votes))
        }

      :error ->
        lm
    end
  end

  defp update_evidence_with_vote(%__MODULE__{} = lm, %Hypotheses{} = hypotheses, votes) do
    # Monty puts the vote locations in a KD-tree (`vote_location_tree`) and asks
    # it for the three nearest of every hypothesis, so a hypothesis costs the
    # logarithm of the vote count rather than the count. Ours is the same index:
    # a vote's id is its place in the round, which is how it is read back.
    tree = KdTree.build(Enum.with_index(Enum.map(votes, & &1.location)))

    # A tuple, because the answer is an id and the confidence is what an id is
    # read for: reading it out of a list by index walked the list every time.
    confidences = votes |> Enum.map(& &1.confidence) |> List.to_tuple()
    neighbours = min(3, length(votes))

    evidence =
      Enum.zip_with(
        Hypotheses.evidence(hypotheses),
        nearest_votes(tree, hypotheses, neighbours),
        fn evidence, nearest ->
          case best_vote_within_reach(lm, nearest, confidences) do
            nil -> evidence
            vote -> weigh_vote(lm, evidence, vote)
          end
        end
      )

    Hypotheses.put_evidence(hypotheses, evidence)
  end

  # The three nearest votes of every hypothesis, one row each, nearest first.
  #
  # One call to the index for the whole space: a native query is a dirty NIF and
  # costs about ten microseconds whether the answer is three neighbours or one,
  # so asking it per hypothesis was the vote round's whole cost. A machine whose
  # index is the Elixir tree has no batch to ask for, and answers one at a time.
  defp nearest_votes(tree, hypotheses, neighbours) do
    case KdTree.nearest_many_with_distances(
           tree,
           Hypotheses.locations_bytes(hypotheses),
           neighbours
         ) do
      nil ->
        hypotheses
        |> Hypotheses.locations()
        |> Enum.map(&KdTree.nearest_with_distances(tree, &1, neighbours))

      rows ->
        rows
    end
  end

  # The highest confidence among the votes that reach a hypothesis: its three
  # nearest ones, each weighed by how far off it is, and the ones out of reach
  # masked.
  #
  # The index answers nearest first and breaks a tie between equidistant votes by
  # the order they were cast, which is the order the sort this replaces gave.
  #
  # One walk: a weight and a maximum over at most three votes, with nothing built
  # beside them — this ran once per hypothesis of every object of every step.
  defp best_vote_within_reach(%__MODULE__{} = lm, nearest, confidences) do
    Enum.reduce(nearest, nil, fn {distance, cast}, best ->
      # `too_far_away = node_distance_weights <= 0` in Monty, and the same votes
      # are masked here: the weight is zero exactly at `max_match_distance`.
      if weight(lm, distance) > 0 do
        larger(best, elem(confidences, cast))
      else
        best
      end
    end)
  end

  defp larger(nil, confidence), do: confidence
  defp larger(best, confidence) when confidence > best, do: confidence
  defp larger(best, _confidence), do: best

  # Monty's `_get_node_distance_weights`: how much a vote counts by how far from
  # the hypothesis it was cast. The vote round reads only its sign, but the
  # number is Monty's, so it is computed as his.
  defp weight(%__MODULE__{max_match_distance: max}, distance) when max > 0,
    do: (max - distance) / max

  # A zero radius divides by zero in Monty too, where numpy answers `-inf` (or
  # `nan` at the point itself). There is no infinity in the BEAM; `-1` masks the
  # vote, which is what `-inf` does there.
  defp weight(%__MODULE__{}, _distance), do: -1.0

  # Bounded evidence averages, unbounded evidence adds: the same rule the
  # displacer uses for an observation, so a vote and a percept of equal
  # strength move a hypothesis equally far.
  defp weigh_vote(%__MODULE__{} = lm, evidence, vote) do
    if lm.past_weight + lm.present_weight == 1 do
      (evidence + lm.vote_weight * vote) / (1 + lm.vote_weight)
    else
      evidence + lm.vote_weight * vote
    end
  end

  @doc """
  What the vote round left this module believing.

  Monty's `update_stats_after_vote`: the step's statistics are written into the
  last entry the buffer holds, and then the module's own conclusion is settled.
  Nothing possible is `:no_match`; a module that was `:no_match` is let back
  when other modules' votes have given it possibilities again.

  The second half is the one that cannot be left to the terminal check: that
  check clears `:match` when a module loses its object, never `:no_match`, so a
  module that lost its hypotheses once would stay concluded for the episode.
  """
  @impl true
  @spec update_stats_after_vote(t()) :: t()
  def update_stats_after_vote(%__MODULE__{} = lm) do
    {lm, stats} = collect_stats_to_save(lm)
    lm = %{lm | buffer: FeatureAtLocationBuffer.update_last_stats_entry(lm.buffer, stats)}

    cond do
      lm.possible_matches == [] -> set_individual_ts(lm, :no_match)
      lm.terminal_state == :no_match -> set_individual_ts(lm, nil)
      true -> lm
    end
  end

  # -- what the module above hears -----------------------------------------

  @doc """
  This module's hypothesis, as a message to the module above it.

  The pose is the object's orientation, inverted because the message describes
  how the *object* sits rather than how the sensor sees it. `object_id` is a
  stable number derived from the id, so the module above can match on it as a
  categorical feature.

  `pass_message` is true only while all three of Monty's conditions hold: the
  object is recognised, the sensor is still on it, and the most likely
  hypothesis still lies near the stored points of the object it names
  (`mlh_on_model/2`). A guess is not something to build on, and neither is a
  conclusion the model has drifted away from.

  Monty's returns the `Message` alone; this comes back with the module, like
  every other step in this port (`docs/monty-differences.md` §2.4).
  """
  @impl true
  @spec get_output(t()) :: {Message.t() | nil, t()}
  def get_output(%__MODULE__{} = lm) do
    mlh = get_current_mlh(lm)

    # A most likely hypothesis with no evidence behind it — the port's NaN, read
    # back as `nil` — has no confidence to report. The message's confidence is
    # not a feature anything matches on, so zero is the honest encoding of "the
    # module has not concluded anything here".
    size = FeatureAtLocationBuffer.size(lm.buffer)
    on_object = FeatureAtLocationBuffer.get_currently_on_object(lm.buffer)

    confidence =
      cond do
        size == 0 -> 0.0
        is_number(mlh.evidence) -> Monty.Math.clip(mlh.evidence / size, 0, 1)
        true -> 0.0
      end

    {:ok, message} =
      Message.new(
        # The module above takes the location from the sensor directly, so this
        # message carries an orientation and an identity, not a place.
        location: nil,
        morphological_features: %{
          "pose_vectors" => object_pose_to_features(Rotation.invert(mlh.rotation)),
          "pose_fully_defined" => not enough_symmetry_evidence_accumulated?(lm),
          "on_object" => on_object
        },
        non_morphological_features: %{"object_id" => object_id_to_features(mlh.graph_id)},
        confidence: confidence,
        pass_message: on_object and lm.terminal_state == :match and mlh_on_model(lm, mlh),
        process_features_in_lm: true,
        sender_id: lm.learning_module_id,
        sender_type: :lm
      )

    {message, lm}
  end

  # Monty's `_object_pose_to_features`: an object's orientation as the matrix a
  # module above reads. The call site inverts, this function transposes, which is
  # how Monty splits it. His `None` clause answers the identity matrix for a
  # module with no pose yet; here an mlh always carries a rotation (`empty_mlh/0`
  # gives it the identity), so there is no such module to answer for.
  defp object_pose_to_features(%Rotation{} = pose),
    do: %OrientationMatrix{value: pose |> Rotation.to_matrix() |> Geometry.transpose()}

  @doc """
  Whether the most likely hypothesis still lies on the object it names.

  A module can conclude `:match` and then travel: the hypothesis keeps the
  evidence it earned while the sensor moves past the object it matched, so a
  conclusion on its own says nothing about where the module is now. Monty asks
  each of the object's graphs for the stored point nearest the hypothesis'
  location and keeps the nearest of those answers; within
  `max_match_distance` the model still supports the conclusion.

  An object that is not in memory — and a hypothesis with no location — is not
  on the model. Monty writes the latter as a `None` location.
  """
  @spec mlh_on_model(
          t(),
          %{required(:graph_id) => graph_id(), required(:location) => [float()] | nil}
        ) :: boolean()
  def mlh_on_model(%__MODULE__{} = lm, %{graph_id: graph_id, location: location}) do
    if is_nil(location) or graph_id not in get_all_known_object_ids(lm) do
      false
    else
      nearest =
        lm.graph_memory
        |> GraphMemory.get_input_channels_in_graph(graph_id)
        |> Enum.map(&nearest_node_distance(lm, graph_id, &1, location))
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> nil end)

      is_number(nearest) and nearest <= lm.max_match_distance
    end
  end

  # The distance from the hypothesis to the closest stored point of one
  # channel's graph, or `nil` when that graph holds no node to be near.
  defp nearest_node_distance(%__MODULE__{} = lm, graph_id, channel, location) do
    graph = GraphMemory.get_graph(lm.graph_memory, graph_id, channel)
    model = lm.graph_memory.object_model

    case model.find_nearest_neighbors(graph, [location], 1, distance: true) do
      [[{distance, _node_id} | _rest]] -> distance
      [_no_node] -> nil
    end
  end

  # A stable number for an object id, so a module above can match on identity
  # without matching on strings: the first 24 bits of its SHA-256, which stay
  # exact in a float32 feature.  @doc false
  @spec object_id_to_features(graph_id()) :: non_neg_integer()
  def object_id_to_features(object_id) do
    <<head::binary-size(3), _rest::binary>> = :crypto.hash(:sha256, object_id)
    :binary.decode_unsigned(head, :big)
  end

  # -- statistics ----------------------------------------------------------

  @doc """
  The statistics of this step, and the module with the buffer that holds them.

  `mlh_prediction_error` is how far the prediction was from the observation, so
  it is recorded against the *previous* MLH — the buffer's copy is what a later
  step's error is measured from.
  """
  @spec collect_stats_to_save(t()) :: {t(), map()}
  def collect_stats_to_save(%__MODULE__{} = lm),
    do: collect_stats_to_save(lm, &add_detailed_stats/2)

  @doc """
  The same, with the detailed fields supplied by whoever owns the module.

  Monty adds the whole hypothesis space to the step's statistics only for a
  module with a detailed logger, through `_add_detailed_stats` — a method a
  mixin may *replace*: `TheoreticalLimitLMLoggingMixin` states its own and does
  not call `super()`, so the learning module that mixes it in logs its four
  fields and not this module's four. Elixir has no inheritance, so the replacing
  function is passed in and the rest of the step stays here
  (`docs/monty-differences.md` §2.9).
  """
  @spec collect_stats_to_save(t(), (t(), map() -> map())) :: {t(), map()}
  def collect_stats_to_save(%__MODULE__{} = lm, detailed) do
    lm = append_mlh_prediction_error_to_stats(lm)

    stats = %{
      "possible_matches" => lm.possible_matches,
      "current_mlh" => get_current_mlh(lm)
    }

    {lm, if(lm.has_detailed_logger, do: detailed.(lm, stats), else: stats)}
  end

  defp log_stats(%__MODULE__{} = lm, _ctx) do
    {lm, stats} = collect_stats_to_save(lm)

    %{
      lm
      | buffer:
          FeatureAtLocationBuffer.update_stats(lm.buffer, stats, append: lm.has_detailed_logger)
    }
  end

  defp append_mlh_prediction_error_to_stats(%__MODULE__{} = lm) do
    graph_id = lm.previous_mlh.graph_id

    if graph_id in ["no_observations_yet", "new_object0"] do
      # Nothing was predicted, so there is no error to log.
      lm
    else
      case lm.hypotheses_updater_telemetry
           |> Map.get(graph_id, %{})
           |> Map.get(:mlh_prediction_error) do
        nil ->
          lm

        error ->
          %{
            lm
            | buffer:
                FeatureAtLocationBuffer.update_stats(
                  lm.buffer,
                  %{"mlh_prediction_error" => error},
                  update_time: false,
                  append: true
                )
          }
      end
    end
  end

  # The whole hypothesis space, for the charts and the replays: locations and
  # evidences every step, rotations once because they never change in an
  # episode.
  #
  # Read through `Hypotheses.locations/1`, not the field: a hypothesis set holds
  # its rows as one f64 binary, and a binary that is not text is not JSON — it
  # took a run with a ported learning module and the detailed logger to find,
  # because until then every run of it was a stand-in with no hypotheses at all.
  defp add_detailed_stats(%__MODULE__{} = lm, stats) do
    stats
    |> Map.put(
      "possible_locations",
      Map.new(lm.hypotheses, fn {id, h} -> {id, Hypotheses.locations(h)} end)
    )
    |> Map.put(
      "evidences",
      Map.new(lm.hypotheses, fn {id, h} -> {id, Hypotheses.evidence(h)} end)
    )
    |> Map.put("symmetry_evidence", lm.symmetry_evidence)
    |> then(fn stats ->
      if Map.has_key?(lm.buffer.stats, "possible_rotations"),
        do: stats,
        else: Map.put(stats, "possible_rotations", get_possible_poses(lm, false))
    end)
  end

  # -- episodes ------------------------------------------------------------

  @doc "Monty's `set_experiment_mode`: decides whether episodes write to memory."
  @impl true
  @spec set_experiment_mode(
          t(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
        ) :: t()
  def set_experiment_mode(%__MODULE__{} = lm, mode), do: %{lm | mode: mode}

  @doc "The graphs this module matches against, and writes to after a training episode."
  @impl true
  @spec graph_memory(t()) :: GraphMemory.t()
  def graph_memory(%__MODULE__{graph_memory: memory}), do: memory

  @doc """
  Takes the episode's ending as this module's, without asking it to reconsider.

  Monty writes the module's `terminal_state` when the system has decided the
  episode is over: a module that never concluded claims nothing, but it is not
  left open either, so an episode has one answer per module.
  """
  @impl true
  @spec set_terminal_state(
          t(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.terminal_state()
        ) ::
          t()
  def set_terminal_state(%__MODULE__{} = lm, terminal_state),
    do: %{lm | terminal_state: terminal_state}

  @doc "Whether the last buffered observation was one this module processed."
  @impl true
  @spec observation_processed?(t()) :: boolean()
  def observation_processed?(%__MODULE__{} = lm),
    do: FeatureAtLocationBuffer.get_last_obs_processed(lm.buffer)

  @doc """
  What the module has concluded so far, read and not recomputed.

  Monty's `lm.terminal_state`, which this module's own `matching_step` writes
  the moment nothing is possible. The model decides the step from it; deciding
  what to conclude is `update_terminal_condition/1`.
  """
  @impl true
  @spec conclusion(t()) ::
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.terminal_state()
  def conclusion(%__MODULE__{} = lm), do: lm.terminal_state

  @doc "Records whether this step's observation reached the learning module."
  @impl true
  @spec add_lm_processing_to_buffer_stats(t(), boolean()) :: t()
  def add_lm_processing_to_buffer_stats(%__MODULE__{} = lm, processed) do
    %{
      lm
      | buffer:
          FeatureAtLocationBuffer.update_stats(lm.buffer, %{"lm_processed_steps" => processed},
            update_time: false
          )
    }
  end

  @doc """
  Folds what this episode saw into long-term memory, if it was a training
  episode and if it saw anything.

  The graph is stored against `detected_object` and in the object's own frame:
  `detected_rotation_r` describes how the object sits, so its inverse is what
  turns observations into model coordinates. When nothing was detected in time,
  `detected_object` is `nil` and the memory is left alone.
  """
  @impl true
  @spec update_ltm_from_stm(t()) :: t()
  def update_ltm_from_stm(%__MODULE__{mode: :train} = lm) do
    if FeatureAtLocationBuffer.size(lm.buffer) > 0 do
      Monty.Trace.trace("updating the memory of #{lm.learning_module_id}")
      lm |> update_memory() |> build_updater()
    else
      lm
    end
  end

  def update_ltm_from_stm(%__MODULE__{} = lm), do: lm

  @doc """
  `GraphLM._set_target`: names the object this episode is about.

  The target is what makes a performance measurable at all — "correct" is
  "recognised the object it was asked about", and the rotation error is measured
  against the pose the object was placed with. A new episode clears the object it
  was on last, which Monty does here as well: a stale stepwise target would make
  the next episode's stepwise performance a statement about the previous one.

  `nil` leaves the target alone, which is Monty's guard and its reason: a caller
  that has no target for this episode (an unsupervised run) must not erase the
  one the module learned from.
  """
  @spec set_target(t(), map() | nil) :: t()
  @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
  def set_target(%__MODULE__{} = lm, nil),
    do: %{lm | stepwise_target_object: nil, stepwise_targets_list: []}

  def set_target(%__MODULE__{} = lm, primary_target) do
    %{
      lm
      | primary_target: Map.get(primary_target, "object_name"),
        primary_target_rotation_quat: Map.get(primary_target, "quat_rotation"),
        stepwise_target_object: nil,
        stepwise_targets_list: []
    }
  end

  @doc """
  `GraphLM`'s stepwise target: the object under the module's sensor this step.

  Set by the model from the percept's semantic id, and kept as a list because a
  run's log says what the module was looking at on every step — the stepwise
  performance of an episode is a statement about that list, and a graph built
  from a patch that wandered off the object is explained by it.
  """
  @spec set_stepwise_target(t(), String.t()) :: t()
  @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
  def set_stepwise_target(%__MODULE__{} = lm, label) do
    %{
      lm
      | stepwise_target_object: label,
        stepwise_targets_list: lm.stepwise_targets_list ++ [label]
    }
  end

  @doc """
  `GraphLM.fixme_update_ground_truth`: records which object the graph this
  episode built came from.

  Monty's name, and its comment: this is the ground truth an evaluation is
  scored against, not something the model worked out. It is written after a
  training episode, from the object the module detected and the object it was
  told to expect, and it is what lets a later run answer "was `mug` recognised as
  `mug`" without the training run's target being available.

  A graph can come from more than one target and a target can give more than one
  graph, so both directions are sets, exactly as Monty keeps them.
  """
  @spec fixme_update_ground_truth(t()) :: t()
  @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
  def fixme_update_ground_truth(%__MODULE__{mode: :train} = lm) do
    if FeatureAtLocationBuffer.size(lm.buffer) > 0 do
      update_target_graph_mapping(lm, lm.detected_object, lm.primary_target)
    else
      lm
    end
  end

  def fixme_update_ground_truth(%__MODULE__{} = lm), do: lm

  # Monty's guard: a training episode that detected nothing has no graph to
  # attribute. A target of `nil` is recorded rather than skipped, because that is
  # what Monty does and an unsupervised training run genuinely has none.
  defp update_target_graph_mapping(%__MODULE__{} = lm, nil, _target), do: lm

  defp update_target_graph_mapping(%__MODULE__{} = lm, detected_object, target_object) do
    %{
      lm
      | graph_id_to_target:
          Map.update(
            lm.graph_id_to_target,
            detected_object,
            MapSet.new([target_object]),
            &MapSet.put(&1, target_object)
          ),
        target_to_graph_id:
          Map.update(
            lm.target_to_graph_id,
            target_object,
            MapSet.new([detected_object]),
            &MapSet.put(&1, detected_object)
          )
    }
  end

  defp update_memory(%__MODULE__{} = lm) do
    %{
      locations: locations,
      features: features,
      object_location_rel_body: rel_body,
      location_rel_model: rel_model
    } = FeatureAtLocationBuffer.get_infos_for_graph_update(lm.buffer)

    memory =
      GraphMemory.update_memory(
        lm.graph_memory,
        locations,
        features,
        lm.detected_object,
        rel_body,
        rel_model,
        if(lm.detected_rotation_r, do: Rotation.invert(lm.detected_rotation_r))
      )

    %{lm | graph_memory: memory}
  end

  @doc """
  What has to be kept to resume this module: its memory, and how much detail it
  was asked to log.
  """
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = lm) do
    %{
      graph_memory: GraphMemory.state_dict(lm.graph_memory),
      has_detailed_logger: lm.has_detailed_logger
    }
  end

  @doc """
  Resumes from `state_dict/1` and re-derives what depends on memory.

  Memory that changed has to be re-read: Monty's `load_state_dict` gives the
  module a chance to update internal state from the contents of memory, which is
  `init_from_ltm/1` here. This port also rebuilds the comparison, because an
  updater is handed feature arrays and loading returns a memory it has not seen.
  """
  @spec load_state_dict(t(), map()) :: t()
  def load_state_dict(%__MODULE__{} = lm, memento) do
    %{
      lm
      | graph_memory: GraphMemory.load_state_dict(lm.graph_memory, memento.graph_memory),
        has_detailed_logger: Map.get(memento, :has_detailed_logger, lm.has_detailed_logger)
    }
    |> init_from_ltm()
    |> build_updater()
  end
end
