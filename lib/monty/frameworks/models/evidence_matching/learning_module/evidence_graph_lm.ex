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
      `use_multithreading` switch threads the per-object updates; each is
      independent, so the result is identical either way, and parallelism
      belongs to whoever calls the steps rather than to the algorithm.
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
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
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
            previous_mlh: nil

  @type graph_id :: String.t()

  @typedoc "Monty's `ExperimentMode`: training writes memory, evaluation does not."
  @type mode :: :train | :eval | nil

  @typedoc """
  The best hypothesis of a graph, or of everything, as one record.

  `mlh_id` indexes into that graph's hypothesis space — `nil` until a space
  exists, which is why `current_mlh/1` has a location to refresh only when
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
          fill_default_weights(Keyword.get(options, :feature_weights, %{}), tolerances),
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
  def from_config(config) when is_map(config) do
    with :ok <- check_target(Map.get(config, "_target_", @evidence_graph_lm_target)),
         {:ok, updater} <- updater_for(config) do
      memory =
        EvidenceGraphMemory.new(
          max_nodes_per_graph: Map.get(config, "max_nodes_per_graph", 2000),
          max_graph_size: Map.get(config, "max_graph_size", 0.3),
          num_model_voxels_per_dim: Map.get(config, "num_model_voxels_per_dim", 50)
        )

      new(memory,
        max_match_distance: Map.get(config, "max_match_distance", 0.01),
        tolerances: Map.get(config, "tolerances", %{}),
        feature_weights: Map.get(config, "feature_weights", %{}),
        x_percent_threshold: Map.get(config, "x_percent_threshold", 10),
        evidence_threshold_config: Map.get(config, "evidence_threshold_config", "all"),
        learning_module_id: Map.get(config, "learning_module_id", "LM_0"),
        max_nneighbors:
          get_in(config, ["hypotheses_updater_args", "max_nneighbors"]) || @default_max_nneighbors,
        hypotheses_updater: updater
      )
    end
  end

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
  defp fill_default_weights(feature_weights, tolerances) do
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
    memory = GraphMemory.initialize_feature_arrays(lm.graph_memory)
    mlh = fresh_mlh()

    lm
    |> Map.merge(%{
      graph_memory: memory,
      buffer: FeatureAtLocationBuffer.new(),
      hypotheses: %{},
      hypotheses_updater_telemetry: %{},
      possible_matches: EvidenceGraphMemory.get_initial_hypotheses(memory),
      symmetry_evidence: 0,
      terminal_state: nil,
      detected_object: nil,
      detected_pose: List.duplicate(nil, @detected_pose_width),
      detected_rotation_r: nil,
      current_mlh: mlh,
      previous_mlh: mlh
    })
    |> reset_goal_generator()
    |> build_updater()
  end

  # Monty resets the goal generator with the rest of the short-term memory: a
  # schedule built against another object's observations says nothing here.
  defp reset_goal_generator(%__MODULE__{gsg: nil} = lm), do: lm

  defp reset_goal_generator(%__MODULE__{} = lm) do
    %{lm | gsg: lm.gsg.__struct__.reset(lm.gsg.__struct__.point_at(lm.gsg, lm))}
  end

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
    gsg = lm.gsg.__struct__.point_at(lm.gsg, lm)
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
  def add_displacements(%__MODULE__{} = lm, percepts) do
    sensor_module_percepts = Enum.filter(percepts, &Message.from_sensor_module?/1)

    case Cmp.location_mean(sensor_module_percepts) do
      nil ->
        {:error, :no_sensor_module_location}

      location ->
        displacement =
          case lm.buffer.last_location do
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

  defp compute_possible_matches(%__MODULE__{} = lm, observations, moved?) do
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

    lm =
      lm
      |> get_all_known_object_ids()
      |> Enum.reduce(lm, &update_evidence(&2, features, displacement, &1))

    lm = end_step(lm)

    %{
      lm
      | possible_matches: threshold_possible_matches(lm, 1.0),
        previous_mlh: lm.current_mlh,
        current_mlh: most_likely_hypothesis(lm)
    }
  end

  defp update_evidence(%__MODULE__{} = lm, features, displacement, graph_id) do
    hypotheses = Map.get(lm.hypotheses, graph_id, Hypotheses.empty())

    update_threshold =
      LearningModule.evidence_update_threshold(
        lm.threshold_config,
        current_mlh(lm).evidence,
        hypotheses.evidence
      )

    {lm, displaced} = displace(lm, hypotheses, displacement)

    {lm, updated, telemetry} =
      update_with_updater(lm, displaced, features, graph_id, update_threshold)

    lm = %{
      lm
      | hypotheses_updater_telemetry:
          put_telemetry(lm.hypotheses_updater_telemetry, graph_id, telemetry)
    }

    # Monty keeps the hypotheses it had when the updater had nothing to do with
    # them: a graph whose channel this observation does not carry learns
    # nothing from it, and its (undisplaced) space says as much.
    case updated do
      nil -> lm
      updated -> %{lm | hypotheses: Map.put(lm.hypotheses, graph_id, updated)}
    end
  end

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

  defp displace(%__MODULE__{hypotheses_updater: {module, updater}} = lm, hypotheses, displacement) do
    displaced = module.displace_hypotheses(updater, hypotheses, displacement)
    {lm, displaced}
  end

  defp update_with_updater(
         %__MODULE__{hypotheses_updater: {module, updater}} = lm,
         hypotheses,
         features,
         graph_id,
         threshold
       ) do
    {updater, updated, telemetry} =
      module.update_evidence(updater, hypotheses, features, graph_id, threshold)

    {%{lm | hypotheses_updater: {module, updater}}, updated, telemetry}
  end

  @doc """
  Moves every hypothesis of every object by the sensor's movement.

  Used on location-only steps: the sensor travelled without looking, so the
  hypotheses must keep up while their evidence stays exactly as it was. The
  hypothesis ids do not change, which is why the MLH still points at the same
  hypothesis afterwards.
  """
  @spec displace_all(t(), [Message.t()]) :: t()
  def displace_all(%__MODULE__{buffer: %{last_location: nil}} = lm, _percepts), do: lm

  def displace_all(%__MODULE__{} = lm, percepts) do
    case Cmp.location_mean(Enum.filter(percepts, &Message.from_sensor_module?/1)) do
      nil ->
        Logger.warning(
          "#{lm.learning_module_id} was moved without a sensor location; nothing to displace by"
        )

        lm

      location ->
        displacement = Geometry.subtract(location, lm.buffer.last_location)

        hypotheses =
          Map.new(lm.hypotheses, fn {graph_id, hypotheses} ->
            {_lm, displaced} = displace(lm, hypotheses, displacement)
            {graph_id, displaced}
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

  defp possible_of(%__MODULE__{} = lm, graph_ids, evidences, x_percent_scale_factor) do
    max_evidence = Enum.max(evidences)

    cond do
      Monty.Math.population_std(evidences) > 0.1 or max_evidence < 0 ->
        threshold =
          if max_evidence > 0,
            do:
              max_evidence - max_evidence / 100 * lm.x_percent_threshold * x_percent_scale_factor,
            else: 0.0

        keep_where(graph_ids, evidences, &(&1 > threshold))

      GraphMemory.size(lm.graph_memory) == 1 ->
        keep_where(graph_ids, evidences, &(&1 >= 0))

      true ->
        graph_ids
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
          %Hypotheses{evidence: []} -> []
          %Hypotheses{evidence: evidence} -> [{graph_id, Enum.max(evidence)}]
          nil -> []
        end
      end)
      |> Enum.unzip()
    end
  end

  @doc "Every object the memory knows about."
  @spec get_all_known_object_ids(t()) :: [graph_id()]
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
  @spec current_mlh(t()) :: mlh()
  def current_mlh(%__MODULE__{current_mlh: mlh} = lm) do
    with id when not is_nil(id) <- mlh.mlh_id,
         %Hypotheses{} = hypotheses <- Map.get(lm.hypotheses, mlh.graph_id) do
      %{mlh | location: Enum.at(hypotheses.locations, id)}
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
  @spec most_likely_hypothesis(t(), graph_id() | nil) :: mlh()
  def most_likely_hypothesis(lm, graph_id \\ nil)

  def most_likely_hypothesis(%__MODULE__{} = lm, graph_id) when is_binary(graph_id) do
    lm
    |> best_of(graph_id)
    |> finish_mlh(lm)
  end

  def most_likely_hypothesis(%__MODULE__{} = lm, nil) do
    lm
    |> get_all_known_object_ids()
    |> Enum.reduce(nil, fn graph_id, best -> better(best, best_of(lm, graph_id)) end)
    |> finish_mlh(lm)
  end

  defp best_of(%__MODULE__{} = lm, graph_id) do
    case Map.get(lm.hypotheses, graph_id) do
      %Hypotheses{evidence: []} -> nil
      %Hypotheses{} = hypotheses -> mlh_from_id(lm, graph_id, argmax(hypotheses.evidence))
      nil -> nil
    end
  end

  # numpy's `argmax`, which reports the first of several equal maxima.
  defp argmax(values) do
    values
    |> Enum.with_index()
    |> Enum.max_by(fn {value, index} -> {value, -index} end)
    |> elem(1)
  end

  # The index of the second highest value, or `nil` when there is no second.
  defp second_argmax([_only]), do: nil

  defp second_argmax(values) do
    values
    |> Enum.with_index()
    |> Enum.sort_by(fn {value, index} -> {value, index} end)
    |> Enum.at(-2)
    |> elem(1)
  end

  # Ties keep the first object in memory order, which is the order
  # `get_all_known_object_ids/1` gives.
  defp better(nil, candidate), do: candidate

  defp better(%{evidence: best}, %{evidence: candidate} = candidate_mlh) when candidate > best,
    do: candidate_mlh

  defp better(current, _candidate), do: current

  defp finish_mlh(nil, %__MODULE__{} = lm), do: %{current_mlh(lm) | graph_id: "new_object0"}
  defp finish_mlh(mlh, %__MODULE__{}), do: mlh

  @doc "The most likely hypothesis of one object, whether or not it is the best overall."
  @spec get_mlh_for_object(t(), graph_id()) :: mlh()
  def get_mlh_for_object(%__MODULE__{} = lm, graph_id), do: most_likely_hypothesis(lm, graph_id)

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
      %Hypotheses{evidence: evidence} -> length(evidence)
      nil -> 0
    end
  end

  defp mlh_from_id(%__MODULE__{} = lm, graph_id, id) do
    hypotheses = Map.fetch!(lm.hypotheses, graph_id)

    %{
      graph_id: graph_id,
      mlh_id: id,
      location: Enum.at(hypotheses.locations, id),
      rotation: rotation_of(Enum.at(hypotheses.poses, id)),
      scale: get_object_scale(lm, graph_id),
      evidence: Enum.at(hypotheses.evidence, id)
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
    current_id = current_mlh(lm).graph_id

    cond do
      top_id == current_id -> {top_id, second_id}
      second_id == current_id -> {second_id, top_id}
      true -> {current_id, second_id}
    end
  end

  @doc """
  The best and second-best hypotheses of one object.

  `{best, nil}` when the object has a single hypothesis: there is no second
  best, and Monty's `argsort(...)[-2]` would fail on it.
  """
  @spec get_top_two_pose_hypotheses_for_graph_id(t(), graph_id()) :: {mlh(), mlh() | nil}
  def get_top_two_pose_hypotheses_for_graph_id(%__MODULE__{} = lm, graph_id) do
    best = most_likely_hypothesis(lm, graph_id)

    case second_argmax(Map.fetch!(lm.hypotheses, graph_id).evidence) do
      nil -> {best, nil}
      id -> {best, mlh_from_id(lm, graph_id, id)}
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
    evidence = Map.fetch!(lm.hypotheses, object_id).evidence
    max_evidence = Enum.max(evidence)

    if max_evidence > lm.object_evidence_threshold do
      threshold = max_evidence - max_evidence / 100 * lm.x_percent_threshold

      for {value, index} <- Enum.with_index(evidence), value > threshold, do: index
    else
      []
    end
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
          Enum.map(hypotheses.poses, fn pose ->
            pose
            |> rotation_of()
            |> Rotation.invert()
            |> Rotation.to_euler_degrees(5)
          end)
        else
          hypotheses.poses
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
            Logger.info("#{lm.learning_module_id} recognised #{object_id}")
            set_individual_ts(lm, :match)

          lm.terminal_state == :match ->
            set_individual_ts(lm, nil)

          true ->
            Logger.info("pose of #{object_id} is not narrowed down yet")
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
      Logger.info(
        "#{lm.learning_module_id} detected #{lm.detected_object} at " <>
          "#{inspect(Enum.take(lm.detected_pose, 3))} rotated " <>
          "#{inspect(Enum.slice(lm.detected_pose, 3, 3))}"
      )
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
    mlh = current_mlh(lm)
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
        mlh = current_mlh(lm)
        hypotheses = Map.fetch!(lm.hypotheses, object_id)

        pose_is_unique = unique_pose?(lm, hypotheses, possible_ids, mlh.rotation)

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
          Logger.debug("#{object_id} is detected but its pose is not resolved yet")
          {lm, nil}
        end
    end
  end

  defp unique_pose?(%__MODULE__{} = lm, hypotheses, ids, most_likely_rotation) do
    locations = Enum.map(ids, &Enum.at(hypotheses.locations, &1))
    center = centroid(locations)
    distances = Enum.map(locations, &norm(Geometry.subtract(&1, center)))

    # How far apart the possible rotations are, measured as the angle each
    # needs to turn into the most likely one.
    most_likely_matrix = Rotation.to_matrix(most_likely_rotation)

    turns =
      Enum.map(ids, fn id ->
        pose = Enum.at(hypotheses.poses, id)
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

    Logger.debug("(location, rotation, scale): #{inspect(pose_and_scale)}")

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
          "symmetric_rotations" => Enum.map(possible_ids, &Enum.at(hypotheses.poses, &1)),
          "symmetric_locations" => Enum.map(possible_ids, &Enum.at(hypotheses.locations, &1))
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

      {lm, enough_symmetry_evidence?(lm)}
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
  @spec enough_symmetry_evidence?(t()) :: boolean()
  def enough_symmetry_evidence?(%__MODULE__{} = lm),
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
      Map.new(lm.hypotheses, fn {graph_id, hypotheses} -> {graph_id, hypotheses.evidence} end)

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
        location: Enum.at(hypotheses.locations, id),
        morphological_features: %{
          "pose_vectors" => %OrientationMatrix{
            value: Geometry.transpose(Enum.at(hypotheses.poses, id))
          },
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

  Monty finds the closest votes with a KD-tree; this compares every hypothesis
  against every vote, which gives the same neighbours for the handful of votes
  a round carries.
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
          current_mlh: most_likely_hypothesis(lm)
      }

      {:ok, lm}
    end
  end

  defp apply_votes(%__MODULE__{} = lm, {graph_id, votes}) do
    case Map.fetch(lm.hypotheses, graph_id) do
      {:ok, hypotheses} ->
        %{lm | hypotheses: Map.put(lm.hypotheses, graph_id, vote_evidence(lm, hypotheses, votes))}

      :error ->
        lm
    end
  end

  defp vote_evidence(%__MODULE__{} = lm, %Hypotheses{} = hypotheses, votes) do
    vote_locations = Enum.map(votes, & &1.location)
    vote_confidences = Enum.map(votes, & &1.confidence)
    neighbours = min(3, length(votes))

    evidence =
      Enum.zip_with(hypotheses.evidence, hypotheses.locations, fn evidence, location ->
        case best_vote_within_reach(lm, location, vote_locations, vote_confidences, neighbours) do
          nil -> evidence
          vote -> weigh_vote(lm, evidence, vote)
        end
      end)

    %Hypotheses{hypotheses | evidence: evidence}
  end

  defp best_vote_within_reach(
         %__MODULE__{} = lm,
         location,
         vote_locations,
         vote_confidences,
         neighbours
       ) do
    vote_locations
    |> Enum.with_index()
    |> Enum.map(fn {vote_location, index} ->
      {norm(Geometry.subtract(location, vote_location)), index}
    end)
    |> Enum.sort()
    |> Enum.take(neighbours)
    |> Enum.filter(fn {distance, _index} -> distance < lm.max_match_distance end)
    |> Enum.map(fn {_distance, index} -> Enum.at(vote_confidences, index) end)
    |> Enum.max(fn -> nil end)
  end

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

  # -- what the module above hears -----------------------------------------

  @doc """
  This module's hypothesis, as a message to the module above it.

  The pose is the object's orientation, inverted because the message describes
  how the *object* sits rather than how the sensor sees it, and
  `pass_message` is only true once the object is recognised — a guess is not
  something to build on. `object_id` is a stable number derived from the id, so
  the module above can match on it as a categorical feature.
  """
  @impl true
  @spec get_output(t()) :: {Message.t() | nil, t()}
  def get_output(%__MODULE__{} = lm) do
    mlh = current_mlh(lm)

    confidence =
      case FeatureAtLocationBuffer.size(lm.buffer) do
        0 -> 0.0
        size -> Monty.Math.clip(mlh.evidence / size, 0, 1)
      end

    {:ok, message} =
      Message.new(
        # The module above takes the location from the sensor directly, so this
        # message carries an orientation and an identity, not a place.
        location: nil,
        morphological_features: %{
          "pose_vectors" => %OrientationMatrix{
            value:
              mlh.rotation |> Rotation.invert() |> Rotation.to_matrix() |> Geometry.transpose()
          },
          "pose_fully_defined" => not enough_symmetry_evidence?(lm),
          "on_object" => FeatureAtLocationBuffer.get_currently_on_object(lm.buffer)
        },
        non_morphological_features: %{"object_id" => object_id_of(mlh.graph_id)},
        confidence: confidence,
        pass_message:
          FeatureAtLocationBuffer.get_currently_on_object(lm.buffer) and
            lm.terminal_state == :match,
        process_features_in_lm: true,
        sender_id: lm.learning_module_id,
        sender_type: :lm
      )

    {message, lm}
  end

  # A stable number for an object id, so a module above can match on identity
  # without matching on strings: the first 24 bits of its SHA-256, which stay
  # exact in a float32 feature.
  @doc false
  @spec object_id_of(graph_id()) :: non_neg_integer()
  def object_id_of(object_id) do
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
  def collect_stats_to_save(%__MODULE__{} = lm) do
    lm = append_mlh_prediction_error(lm)

    stats = %{
      "possible_matches" => lm.possible_matches,
      "current_mlh" => current_mlh(lm)
    }

    {lm, if(lm.has_detailed_logger, do: detailed_stats(lm, stats), else: stats)}
  end

  defp log_stats(%__MODULE__{} = lm, _ctx) do
    {lm, stats} = collect_stats_to_save(lm)

    %{
      lm
      | buffer:
          FeatureAtLocationBuffer.update_stats(lm.buffer, stats, append: lm.has_detailed_logger)
    }
  end

  defp append_mlh_prediction_error(%__MODULE__{} = lm) do
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
  defp detailed_stats(%__MODULE__{} = lm, stats) do
    stats
    |> Map.put("possible_locations", Map.new(lm.hypotheses, fn {id, h} -> {id, h.locations} end))
    |> Map.put("evidences", Map.new(lm.hypotheses, fn {id, h} -> {id, h.evidence} end))
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
      Logger.info("updating the memory of #{lm.learning_module_id}")
      lm |> update_memory() |> build_updater()
    else
      lm
    end
  end

  def update_ltm_from_stm(%__MODULE__{} = lm), do: lm

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
  Resumes from `state_dict/1` and re-derives everything that depends on memory.

  Memory that changes has to be re-read: the feature arrays are rebuilt and the
  comparison is rebuilt with them, or the module would keep matching against
  the memory it was constructed with.
  """
  @spec load_state_dict(t(), map()) :: t()
  def load_state_dict(%__MODULE__{} = lm, memento) do
    lm = %{
      lm
      | graph_memory: GraphMemory.load_state_dict(lm.graph_memory, memento.graph_memory),
        has_detailed_logger: Map.get(memento, :has_detailed_logger, lm.has_detailed_logger)
    }

    reset_stm(lm)
  end
end
