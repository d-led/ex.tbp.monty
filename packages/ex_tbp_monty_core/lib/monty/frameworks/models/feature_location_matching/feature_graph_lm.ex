defmodule Monty.Frameworks.Models.FeatureLocationMatching.FeatureGraphLM do
  @moduledoc """
  A learning module that recognises objects by the features it senses at
  locations: Monty's `FeatureGraphLM`.

  This is the first learning module Monty had, and it is the one to read to see
  what recognising an object out of a graph means. A step carries a location and
  the features there. Memory is a graph of locations, each with the features
  sensed at it. The module asks two questions per graph:

    1. **Which nodes could I be standing on?** Every node whose stored features
       are within tolerance of what was just sensed, ignoring where they are.
    2. **Does the move agree with a pose I could be in?** For every path still
       possible and every rotation still possible on it, turn the observed step
       into the model's frame by that rotation, land on a place, and keep the
       path if a node near that place carries the pose the rotation predicted.

  A path that survives is where the sensor would be if that pose were right.
  Recognition is one object left whose path is unique and whose rotation is
  unique — or, for an object that looks the same from several sides, the same
  set of poses lasting `required_symmetry_evidence` steps.

  ## What it composes

  `%Monty.Frameworks.Models.GraphMatching.GraphLM{}` is the graph module
  underneath: the buffer, the goal generator, the votes, the conclusion, the
  memory write. This adds what only a feature match has — the poses still
  possible on each path, and the symmetry evidence that lets a symmetric object
  be recognised at all. The paths themselves stay in the graph module's
  `possible_paths`, because they are what its conclusion reads.

  ## Differences from Monty, on purpose

    * **A step returns a new module** rather than mutating one, so the callbacks
      that narrow the pose hand back the module they changed.
    * **The nearest matching node is found by sorting the candidate nodes**, not
      by asking a k-d tree for them in order. Monty's tree is faster on a graph
      of tens of thousands of nodes; this module's experiments are graphs of
      hundreds, and a sort is the same answer with nothing to keep consistent.
    * **Poses are not jittered.** Monty samples `n_samples` extra rotations
      around each aligned pose with `ctx.rng.vonmises`, and its only caller
      passes zero, so the sampling is not ported; a config asking for it would
      need the RNG threaded in, and no config does.
    * **Votes are negative only.** Monty's feature module also votes on the
      locations and rotations it still considers, and uses the other modules'
      such votes to prune paths. This port's model routes one kind of vote — the
      objects a module has ruled out — so a feature module votes like the rest
      and does no location pruning from other modules' votes. Monty's own
      comment on that path says it is not being developed further.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule


  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.FeatureLocationMatching.FeatureGraphMemory
  alias Monty.Frameworks.Models.GraphMatching.GraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.{Rotation, SurfacePoseVectors}

  @default_path_similarity_threshold 0.1
  @default_pose_similarity_threshold 0.35
  @default_required_symmetry_evidence 5
  @default_umbilical_num_poses 8
  @default_curvature_tolerance_degrees 20

  @enforce_keys [:graph_lm, :max_match_distance]
  defstruct graph_lm: nil,
            max_match_distance: nil,
            tolerances: %{},
            path_similarity_threshold: @default_path_similarity_threshold,
            pose_similarity_threshold: @default_pose_similarity_threshold,
            required_symmetry_evidence: @default_required_symmetry_evidence,
            initial_possible_poses: nil,
            umbilical_num_poses: @default_umbilical_num_poses,
            possible_poses: %{},
            symmetry_evidence: 0,
            last_unique_poses: nil,
            last_num_unique_locations: nil

  @type t :: %__MODULE__{}

  @doc """
  The module a config asks for, as Monty's `__init__` reads its arguments.

  `:memory` is the graphs the module starts from: Monty loads a state dict into
  a module it has just built, which is the same thing one step earlier.
  """
  @spec from_config(map(), keyword()) :: {:ok, t()}
  def from_config(config, options \\ []) when is_map(config) do
    {:ok,
     new(
       max_match_distance: Map.get(config, "max_match_distance"),
       tolerances: Map.get(config, "tolerances", %{}),
       path_similarity_threshold:
         Map.get(config, "path_similarity_threshold", @default_path_similarity_threshold),
       pose_similarity_threshold:
         Map.get(config, "pose_similarity_threshold", @default_pose_similarity_threshold),
       required_symmetry_evidence:
         Map.get(config, "required_symmetry_evidence", @default_required_symmetry_evidence),
       graph_delta_thresholds: Map.get(config, "graph_delta_thresholds"),
       initial_possible_poses: Map.get(config, "initial_possible_poses", "informed"),
       umbilical_num_poses: Map.get(config, "umbilical_num_poses", @default_umbilical_num_poses),
       learning_module_id: Map.get(config, "learning_module_id", "LM_0"),
       has_detailed_logger: Keyword.get(options, :has_detailed_logger, false),
       memory: Keyword.get(options, :memory)
     )}
  end

  @doc """
  A module with an empty memory.

  `:max_match_distance` is how far from a place a node may be and still be the
  node the sensor arrived at. `:tolerances` is per input channel and per feature,
  in the units that feature is sensed in — except pose vectors, which are
  degrees in a config and radians everywhere in the matching, so they are
  converted here, once.

  `:initial_possible_poses` is `"uniform"` (try every rotation in 45° steps),
  `"informed"` (start from the pose the sensed pose vectors imply — Monty's
  default), or a list of Euler poses to try exactly.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    tolerances =
      options
      |> Keyword.get(:tolerances, %{})
      |> GraphMatchingUtils.add_pose_features_to_tolerances(
        Keyword.get(options, :default_tolerances, @default_curvature_tolerance_degrees)
      )

    memory =
      Keyword.get(options, :memory) ||
        options
        |> Keyword.take([:graph_delta_thresholds, :k, :object_model, :object_model_options])
        |> FeatureGraphMemory.new()

    # Monty sets `graph_memory.features_to_use = self.tolerances` after building
    # the memory, whatever the memory was built with: the features a match
    # compares are the ones this module tolerates, and nowhere else says so. This
    # port's memory keeps the names it stores rows for and nothing else, so the
    # names are what is handed over — the numbers stay with the module that
    # compares them.
    memory = %{memory | features_to_use: features_to_use(tolerances)}

    %__MODULE__{
      graph_lm:
        GraphLM.new(
          options
          |> Keyword.take([:learning_module_id, :has_detailed_logger, :gsg])
          |> Keyword.put(:tolerances, tolerances)
          |> Keyword.put(:graph_memory, memory)
        ),
      max_match_distance: Keyword.fetch!(options, :max_match_distance),
      tolerances: tolerances,
      path_similarity_threshold:
        Keyword.get(options, :path_similarity_threshold, @default_path_similarity_threshold),
      pose_similarity_threshold:
        Keyword.get(options, :pose_similarity_threshold, @default_pose_similarity_threshold),
      required_symmetry_evidence:
        Keyword.get(options, :required_symmetry_evidence, @default_required_symmetry_evidence),
      initial_possible_poses: initial_possible_poses(options),
      umbilical_num_poses:
        Keyword.get(options, :umbilical_num_poses, @default_umbilical_num_poses)
    }
    |> init_from_ltm()
  end

  defp features_to_use(tolerances),
    do:
      Map.new(tolerances, fn {channel, channel_tolerances} ->
        {channel, Map.keys(channel_tolerances)}
      end)

  # `nil` is "informed": the poses come from the first observation's pose
  # vectors, so there is nothing to try in advance.
  defp initial_possible_poses(options) do
    {:ok, poses} =
      GraphMatchingUtils.initial_possible_poses(
        named_poses(Keyword.get(options, :initial_possible_poses, :informed))
      )

    case poses do
      :first_observation -> nil
      poses -> poses
    end
  end

  defp named_poses("uniform"), do: :uniform
  defp named_poses("informed"), do: :informed
  defp named_poses(:uniform), do: :uniform
  defp named_poses(:informed), do: :informed
  defp named_poses(poses) when is_list(poses), do: {:euler_degrees, poses}

  defp named_poses(other) do
    raise ArgumentError,
          "initial_possible_poses #{inspect(other)} is not one this port reads: " <>
            ~s("uniform", "informed", or a list of Euler poses)
  end

  @doc """
  Monty's `init_from_ltm`: the hypotheses a memory gives a module at the start.

  Every object in memory is possible, every node of it is a place to have
  started, and no pose is ruled out — and the symmetry counter starts again,
  because evidence about *this* episode's poses says nothing about an episode
  that has not begun.
  """
  @spec init_from_ltm(t()) :: t()
  def init_from_ltm(%__MODULE__{} = lm) do
    {possible_matches, possible_paths, possible_poses} =
      FeatureGraphMemory.get_initial_hypotheses(lm.graph_lm.graph_memory)

    graph_memory =
      if map_size(lm.tolerances) > 0 do
        GraphMemory.initialize_feature_arrays(lm.graph_lm.graph_memory)
      else
        lm.graph_lm.graph_memory
      end

    graph_lm = %{
      lm.graph_lm
      | graph_memory: graph_memory,
        possible_matches: possible_matches,
        possible_paths: possible_paths
    }

    %{
      lm
      | graph_lm: graph_lm,
        possible_poses: possible_poses,
        symmetry_evidence: 0,
        last_unique_poses: nil,
        last_num_unique_locations: nil
    }
  end

  @doc "The same, with the buffer and the hypotheses emptied first — Monty's `reset_stm`."
  @impl true
  @spec reset_stm(t()) :: t()
  def reset_stm(%__MODULE__{} = lm) do
    %{lm | graph_lm: GraphLM.reset_stm(lm.graph_lm)} |> init_from_ltm()
  end

  # -- what the model and the experiment ask --------------------------------
  #
  # Everything below is the graph module's answer, because the buffer, the
  # hypotheses, the votes and the memory are its fields. Monty inherits these; a
  # class that composes says instead which module it is answering on behalf of.

  @doc "Monty's `send_out_vote`: the objects this module knows this one is not."
  @impl true
  @spec send_out_vote(t()) :: {term(), t()}
  def send_out_vote(%__MODULE__{} = lm) do
    {vote, graph_lm} = GraphLM.send_out_vote(lm.graph_lm)
    {vote, %{lm | graph_lm: graph_lm}}
  end

  @doc "Monty's `receive_votes`: another module ruling an object out."
  @impl true
  @spec receive_votes(term(), t()) :: {:ok, t()}
  def receive_votes(votes, %__MODULE__{} = lm) do
    {:ok, graph_lm} = GraphLM.receive_votes(votes, lm.graph_lm)
    {:ok, %{lm | graph_lm: graph_lm}}
  end

  @doc "Monty's `update_stats_after_vote`: what a vote round left it believing."
  @impl true
  @spec update_stats_after_vote(t()) :: t()
  def update_stats_after_vote(%__MODULE__{} = lm),
    do: %{lm | graph_lm: GraphLM.update_stats_after_vote(lm.graph_lm)}

  @doc "Monty's `propose_goals`: what the goal generator last asked for."
  @impl true
  @spec propose_goals(t()) :: {[Monty.Cmp.Goal.t()], t()}
  def propose_goals(%__MODULE__{} = lm) do
    {goals, graph_lm} = GraphLM.propose_goals(lm.graph_lm)
    {goals, %{lm | graph_lm: graph_lm}}
  end

  @doc "Monty's `propose_region`: the region its goals are in."
  @impl true
  @spec propose_region(t()) :: {Monty.Cmp.AttentionRegion.t(), t()}
  def propose_region(%__MODULE__{} = lm) do
    {region, graph_lm} = GraphLM.propose_region(lm.graph_lm)
    {region, %{lm | graph_lm: graph_lm}}
  end

  @doc "Monty's `get_output`: a feature module publishes no hypothesis upward."
  @impl true
  @spec get_output(t()) :: {nil, t()}
  def get_output(%__MODULE__{} = lm) do
    {output, graph_lm} = GraphLM.get_output(lm.graph_lm)
    {output, %{lm | graph_lm: graph_lm}}
  end

  @doc "Monty's `_reset_modules_buffers`: drop the observations, keep the memory."
  @impl true
  @spec clear_buffers(t()) :: t()
  def clear_buffers(%__MODULE__{} = lm),
    do: %{lm | graph_lm: GraphLM.clear_buffers(lm.graph_lm)}

  @doc "Records whether this step's observation reached the module."
  @impl true
  @spec add_lm_processing_to_buffer_stats(t(), boolean()) :: t()
  def add_lm_processing_to_buffer_stats(%__MODULE__{} = lm, processed),
    do: %{lm | graph_lm: GraphLM.add_lm_processing_to_buffer_stats(lm.graph_lm, processed)}

  @doc "Whether the last buffered observation was one this module processed."
  @impl true
  @spec observation_processed?(t()) :: boolean()
  def observation_processed?(%__MODULE__{} = lm),
    do: GraphLM.observation_processed?(lm.graph_lm)

  @doc "What this module concluded, as the model reads it."
  @impl true
  @spec conclusion(t()) :: GraphLM.terminal_state()
  def conclusion(%__MODULE__{} = lm), do: GraphLM.conclusion(lm.graph_lm)

  @doc "Sets the conclusion without asking the module to reconsider."
  @impl true
  @spec set_terminal_state(t(), GraphLM.terminal_state()) :: t()
  def set_terminal_state(%__MODULE__{} = lm, terminal_state),
    do: %{lm | graph_lm: GraphLM.set_terminal_state(lm.graph_lm, terminal_state)}

  @doc "Forgets what the module concluded, keeping what it believes."
  @impl true
  @spec clear_conclusion(t()) :: t()
  def clear_conclusion(%__MODULE__{} = lm),
    do: %{lm | graph_lm: GraphLM.clear_conclusion(lm.graph_lm)}

  @doc "Tells the module whether this episode trains or evaluates."
  @impl true
  @spec set_experiment_mode(
          t(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
        ) ::
          t()
  def set_experiment_mode(%__MODULE__{} = lm, mode),
    do: %{lm | graph_lm: GraphLM.set_experiment_mode(lm.graph_lm, mode)}

  @doc "The graph memory this module holds, passed to the next episode."
  @impl true
  @spec graph_memory(t()) :: GraphMemory.t() | :none
  def graph_memory(%__MODULE__{} = lm), do: GraphLM.graph_memory(lm.graph_lm)

  @doc "Monty's `update_ltm_from_stm`: a training episode's observations, into memory."
  @impl true
  @spec update_ltm_from_stm(t()) :: t()
  def update_ltm_from_stm(%__MODULE__{} = lm),
    do: %{lm | graph_lm: GraphLM.update_ltm_from_stm(lm.graph_lm)}

  @doc "Monty's `fixme_reset_ground_truth`: the object this episode is about."
  @impl true
  @spec set_target(t(), map() | nil) :: t()
  def set_target(%__MODULE__{} = lm, primary_target),
    do: %{lm | graph_lm: GraphLM.set_target(lm.graph_lm, primary_target)}

  @doc "Monty's `fixme_update_ground_truth`: which objects the graph was built from."
  @impl true
  @spec fixme_update_ground_truth(t()) :: t()
  def fixme_update_ground_truth(%__MODULE__{} = lm),
    do: %{lm | graph_lm: GraphLM.fixme_update_ground_truth(lm.graph_lm)}

  @doc "Records which object the module's sensor is on this step."
  @impl true
  @spec set_stepwise_target(t(), String.t() | nil) :: t()
  def set_stepwise_target(%__MODULE__{} = lm, label),
    do: %{lm | graph_lm: GraphLM.set_stepwise_target(lm.graph_lm, label)}

  @doc "The supervised conclusion an experiment states, in place of matching one."
  @spec supervise(t(), map(), [number()]) :: t()
  def supervise(%__MODULE__{} = lm, target, location_on_model),
    do: %{lm | graph_lm: GraphLM.supervise(lm.graph_lm, target, location_on_model)}

  @doc "Drops the hypotheses an unsupervised module never earned."
  @spec clear_hypotheses(t()) :: t()
  def clear_hypotheses(%__MODULE__{} = lm),
    do: %{lm | graph_lm: GraphLM.clear_hypotheses(lm.graph_lm)}

  @doc "Monty's `state_dict`: the memory, and which objects it was built from."
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = lm), do: GraphLM.state_dict(lm.graph_lm)

  @doc "Monty's `load_state_dict`: a memory, and the module state that follows it."
  @spec load_state_dict(t(), map()) :: t()
  def load_state_dict(%__MODULE__{} = lm, memento) do
    %{lm | graph_lm: GraphLM.load_state_dict(lm.graph_lm, memento)} |> init_from_ltm()
  end

  # -- the step -------------------------------------------------------------

  @doc """
  Monty's `matching_step`: what this step's features and move leave possible.

  A step that carried only a location is nothing to match; the rest narrow the
  hypotheses, and a module nothing is possible for any more concludes
  `:no_match`.
  """
  @impl true
  @spec matching_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()}
  def matching_step(percepts, ctx, %__MODULE__{} = lm) do
    if Monty.Runtime.location_only_step?(percepts) do
      {:ok, lm}
    else
      first_movement_detected? = GraphLM.agent_moved_since_reset?(lm.graph_lm)
      feature_percepts = Enum.filter(percepts, & &1.process_features_in_lm)

      case GraphLM.add_displacements(lm.graph_lm, percepts) do
        {:error, _reason} ->
          {:ok, lm}

        {:ok, displaced} ->
          lm = %{lm | graph_lm: GraphLM.buffer_percepts(displaced, lm.graph_lm)}

          lm
          |> compute_possible_matches(ctx, feature_percepts, first_movement_detected?)
          |> conclude_if_nothing_left()
          |> step_the_goal_generator(ctx, feature_percepts)
          |> then(&{:ok, &1})
      end
    end
  end

  @doc "Monty's `exploratory_step`: keep the observation, match nothing yet."
  @impl true
  @spec exploratory_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()}
  def exploratory_step(percepts, ctx, %__MODULE__{} = lm) do
    with {:ok, stepped} <- GraphLM.exploratory_step(percepts, ctx, lm.graph_lm) do
      {:ok, %{lm | graph_lm: stepped}}
    end
  end

  defp conclude_if_nothing_left(lm) do
    if GraphLM.get_possible_matches(lm.graph_lm) == [] do
      %{lm | graph_lm: GraphLM.set_individual_ts(lm.graph_lm, :no_match)}
    else
      lm
    end
  end

  defp step_the_goal_generator(lm, ctx, feature_percepts) do
    graph_lm =
      lm.graph_lm
      |> GraphLM.step_goal_generator(ctx, feature_percepts)
      |> GraphLM.record_stats(add_detailed_stats(lm, %{}))

    %{lm | graph_lm: graph_lm}
  end

  @doc """
  Monty's `_compute_possible_matches` for this class: features, and the move.

  The move is `nil` on the first observation of an episode — there is nothing
  behind it to have moved from — and that `nil` is what tells the narrowing to
  look for starting places rather than to extend paths.
  """
  @spec compute_possible_matches(t(), Monty.Context.t(), [Message.t()], boolean()) :: t()
  def compute_possible_matches(%__MODULE__{} = lm, _ctx, observation, first_movement_detected?) do
    features = GraphLM.select_features_to_use(lm.graph_lm, observation)

    displacement =
      if first_movement_detected? do
        FeatureAtLocationBuffer.current_displacement(lm.graph_lm.buffer)
      end

    update_possible_matches(lm, features, displacement)
  end

  # Every object still possible is asked whether it could be where the sensor is;
  # one that answers no is not possible any more.
  defp update_possible_matches(%__MODULE__{} = lm, features, displacement) do
    lm.graph_lm
    |> GraphLM.get_possible_matches()
    |> Enum.reduce(lm, fn graph_id, lm ->
      {lm, consistent?} = update_matches_using_features(lm, features, displacement, graph_id)

      if consistent?, do: lm, else: remove_object_from_matches(lm, graph_id)
    end)
  end

  # The first observation has no move behind it, so the question is which nodes
  # carry what was sensed. Every following one asks where the move lands, from
  # every place and every rotation still possible.
  defp update_matches_using_features(lm, features, nil, graph_id) do
    {path_start_ids, path_locations} =
      FeatureGraphMemory.get_nodes_with_matching_features(
        lm.graph_lm.graph_memory,
        graph_id,
        features,
        lm.tolerances,
        list_of_lists: true
      )

    {paths, poses} =
      starting_paths_and_poses(lm, graph_id, path_start_ids, path_locations, features)

    lm = put_paths_and_poses(lm, graph_id, paths, poses)

    {lm, paths != []}
  end

  defp update_matches_using_features(lm, features, displacement, graph_id) do
    {paths, poses} = extended_paths_and_poses(lm, graph_id, features, displacement)

    unless length(poses) >= 10 do
      Monty.Trace.trace(fn ->
        "possible poses after matching for #{graph_id}: #{inspect(poses)}"
      end)
    end

    lm = put_paths_and_poses(lm, graph_id, paths, poses)
    Monty.Trace.trace("possible paths after matching for #{graph_id}: #{length(paths)}")

    {lm, paths != []}
  end

  defp put_paths_and_poses(lm, graph_id, paths, poses) do
    %{
      lm
      | graph_lm: %{
          lm.graph_lm
          | possible_paths: Map.put(lm.graph_lm.possible_paths, graph_id, paths)
        },
        possible_poses: Map.put(lm.possible_poses, graph_id, poses)
    }
  end

  # A path whose rotations cannot be worked out from the first observation is
  # dropped: it is a place the sensor could be, with no pose that explains what
  # it senses there.
  defp starting_paths_and_poses(lm, graph_id, path_start_ids, path_locations, features) do
    case lm.initial_possible_poses do
      nil ->
        path_start_ids
        |> Enum.zip(path_locations)
        |> Enum.reduce({[], []}, fn {node_id, location}, {paths, poses} ->
          case informed_possible_poses(lm, graph_id, node_id, features) do
            [] -> {paths, poses}
            possible -> {paths ++ [location], poses ++ [possible]}
          end
        end)

      initial ->
        {path_locations, Enum.map(path_locations, fn _location -> initial end)}
    end
  end

  # With a move to place, every path is tested from its last location under every
  # rotation still possible on it.
  defp extended_paths_and_poses(lm, graph_id, features, displacement) do
    channel = features |> Map.keys() |> hd()

    {matched_ids, matched_locations} =
      FeatureGraphMemory.get_nodes_with_matching_features(
        lm.graph_lm.graph_memory,
        graph_id,
        features,
        lm.tolerances
      )

    if matched_ids == [] do
      {[], []}
    else
      # What every path is tested against this step: the nodes the shade allows,
      # and the frame the sensor sees here.
      target = %{
        graph_id: graph_id,
        channel: channel,
        candidates: Enum.zip(matched_ids, matched_locations),
        pose_vectors: Map.fetch!(Map.fetch!(features, channel), "pose_vectors"),
        pose_defined?: Map.fetch!(Map.fetch!(features, channel), "pose_fully_defined")
      }

      paths = Map.get(lm.graph_lm.possible_paths, graph_id, [])
      poses = Map.get(lm.possible_poses, graph_id, [])

      paths
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {path, index}, acc ->
        # Every rotation still possible on this path is a candidate that has to
        # explain the move; one that does not is dropped with the path it was on.
        poses
        |> Enum.at(index, [])
        |> Enum.reduce(acc, fn pose, acc ->
          extend_path(lm, target, path, pose, displacement, acc)
        end)
      end)
    end
  end

  defp extend_path(lm, target, path, pose, displacement, {paths, poses}) do
    search_location =
      SpatialArithmetics.add(List.last(path), Rotation.apply(pose, displacement))

    query_pose_vectors = SpatialArithmetics.rotate_pose_vectors(target.pose_vectors, pose)

    case nearest_node_with_matching_pose(lm, target, search_location, query_pose_vectors) do
      :none -> {paths, poses}
      {:ok, _node_id} -> {paths ++ [path ++ [search_location]], poses ++ [[pose]]}
    end
  end

  # Monty walks the candidate nodes nearest-first and takes the first whose pose
  # features agree; the first node further away than `max_match_distance` ends
  # the walk, because every node after it is further still.
  defp nearest_node_with_matching_pose(lm, target, search_location, query_pose_vectors) do
    target.candidates
    |> Enum.sort_by(fn {_node_id, location} -> distance(location, search_location) end)
    |> Enum.reduce_while(:none, fn {node_id, location}, _acc ->
      if distance(location, search_location) > lm.max_match_distance do
        {:halt, :none}
      else
        agrees? =
          pose_features_match?(
            lm,
            target.graph_id,
            target.channel,
            node_id,
            query_pose_vectors,
            target.pose_defined?
          )

        if agrees?, do: {:halt, {:ok, node_id}}, else: {:cont, :none}
      end
    end)
  end

  defp distance(point, other),
    do: point |> SpatialArithmetics.subtract(other) |> SpatialArithmetics.magnitude()

  @doc """
  Monty's `_match_pose_dependent_features`: does the node's pose agree.

  Two comparisons, both angles: the surface normal, and — when the sensor's pose
  is fully defined — the first curvature direction, whose sign is not
  meaningful, so an angle past a quarter turn is folded back (`π/2 - |θ - π/2|`).
  """
  @spec pose_features_match?(
          t(),
          GraphMemory.graph_id(),
          GraphMemory.input_channel(),
          non_neg_integer(),
          SurfacePoseVectors.t(),
          boolean()
        ) :: boolean()
  def pose_features_match?(%__MODULE__{} = lm, graph_id, channel, node_id, query, query_defined?) do
    node = node_pose_vectors(lm, graph_id, channel, node_id)
    [normal_tolerance, curvature_tolerance] = pose_vector_tolerances(lm, channel)

    normal_agrees? =
      SpatialArithmetics.get_angle(
        SurfacePoseVectors.surface_normal(query),
        SurfacePoseVectors.surface_normal(node)
      ) < normal_tolerance

    curvature_agrees? =
      if query_defined? do
        angle =
          SpatialArithmetics.get_angle(
            SurfacePoseVectors.principal_curvature_1(query),
            SurfacePoseVectors.principal_curvature_1(node)
          )

        :math.pi() / 2 - abs(angle - :math.pi() / 2) < curvature_tolerance
      else
        true
      end

    normal_agrees? and curvature_agrees?
  end

  defp node_pose_vectors(lm, graph_id, channel, node_id) do
    rows =
      GraphMemory.get_features_at_node(
        lm.graph_lm.graph_memory,
        graph_id,
        channel,
        node_id,
        ["pose_vectors"]
      )

    [normal, curvature_1, curvature_2] = rows |> Map.fetch!("pose_vectors") |> Enum.chunk_every(3)
    SurfacePoseVectors.new(normal, curvature_1, curvature_2)
  end

  defp pose_vector_tolerances(lm, channel) do
    case Map.fetch!(lm.tolerances, channel) |> Map.fetch!("pose_vectors") do
      [normal, curvature_1, _curvature_2] ->
        [normal, curvature_1]

      other ->
        raise ArgumentError, "pose_vectors tolerances must be three angles: #{inspect(other)}"
    end
  end

  # Monty's `_get_informed_possible_poses`: the rotations that would make the
  # sensed frame line up with a node's stored frame. A patch whose curvature
  # directions are meaningful gives two candidates, the second with both
  # directions flipped, because a surface looks the same upside down; a patch
  # where they are not meaningful is sampled round the normal instead.
  defp informed_possible_poses(lm, graph_id, node_id, sensed_features) do
    channel = sensed_features |> Map.keys() |> hd()
    sensed = Map.fetch!(Map.fetch!(sensed_features, channel), "pose_vectors")

    node_directions =
      FeatureGraphMemory.get_rotation_features_at_node(
        lm.graph_lm.graph_memory,
        graph_id,
        node_id,
        channel
      )

    sensed_directions =
      if Map.fetch!(Map.fetch!(sensed_features, channel), "pose_fully_defined") do
        GraphMatchingUtils.possible_sensed_directions(sensed, 2)
      else
        Monty.Trace.trace("PC 1 is similar to PC2 -> Their directions are not meaningful")
        GraphMatchingUtils.possible_sensed_directions(sensed, lm.umbilical_num_poses)
      end

    for direction <- sensed_directions,
        {rotation, error} =
          SpatialArithmetics.align_orthonormal_vectors(node_directions, direction),
        error < 1.0,
        do: rotation
  end

  defp remove_object_from_matches(lm, graph_id) do
    %{
      lm
      | graph_lm: %{
          lm.graph_lm
          | possible_matches: Map.delete(lm.graph_lm.possible_matches, graph_id),
            possible_paths: Map.put(lm.graph_lm.possible_paths, graph_id, [])
        },
        possible_poses: Map.put(lm.possible_poses, graph_id, [])
    }
  end

  # -- the pose -------------------------------------------------------------

  @doc """
  Monty's `get_unique_pose_if_available`: where the object is, once the paths and
  the rotations have stopped multiplying.

  `[x, y, z, euler_x, euler_y, euler_z, scale]`: the last location of the one
  path left, the rotation that turns the model into what the sensor saw, and a
  scale — which a feature module does not measure, so it is always 1.

  The symmetry counter is evidence gathered across steps, so it comes back with
  the answer rather than being kept to one side.
  """
  @spec get_unique_pose_if_available(t(), GraphMemory.graph_id()) ::
          {t(), {:ok, map()} | :not_narrowed}
  def get_unique_pose_if_available(%__MODULE__{} = lm, object_id) do
    case object_rotation(lm, object_id, reverse?: true) do
      {lm, {:ok, {euler_poses, rotations}}} ->
        detected_path = lm.graph_lm.possible_paths |> Map.fetch!(object_id) |> hd()
        location_on_model = List.last(detected_path)
        scale = GraphLM.get_object_scale(lm.graph_lm, object_id)
        pose = location_on_model ++ hd(euler_poses) ++ [scale]

        lm = %{
          lm
          | graph_lm: %{lm.graph_lm | detected_pose: pose, detected_rotation_r: hd(rotations)}
        }

        lm =
          record_pose_stats(lm, detected_path, location_on_model, euler_poses, rotations, scale)

        lm = record_symmetry_stats_if_detected(lm, object_id)
        {lm, {:ok, %{path: detected_path, pose: pose, location_on_model: location_on_model}}}

      {lm, :not_narrowed} ->
        {lm, :not_narrowed}
    end
  end

  # Monty's `get_object_rotation`: whether the pose is known — either one location
  # and one rotation, or a symmetry that has held for long enough.
  defp object_rotation(lm, graph_id, options) do
    reverse? = Keyword.get(options, :reverse?, true)
    unique_locations = recent_unique_paths(lm, graph_id)
    location_is_unique? = length(unique_locations) == 1

    {euler_poses, rotations} =
      SpatialArithmetics.get_unique_rotations(
        Map.get(lm.possible_poses, graph_id, []),
        lm.pose_similarity_threshold,
        reverse?: reverse?
      )

    rotation_is_unique? = length(rotations) == 1
    {lm, symmetry_detected?} = check_for_symmetry(lm, euler_poses, length(unique_locations))

    if location_is_unique? and rotation_is_unique? and symmetry_detected? do
      raise "a symmetric object also has one location and one rotation: " <>
              "#{lm.graph_lm.learning_module_id} cannot be in both terminal conditions, " <>
              "and Monty asserts the same"
    end

    if (location_is_unique? and rotation_is_unique?) or symmetry_detected? do
      {lm, {:ok, {euler_poses, rotations}}}
    else
      lm = %{
        lm
        | last_unique_poses: euler_poses,
          last_num_unique_locations: length(unique_locations)
      }

      {lm, :not_narrowed}
    end
  end

  # Monty's `_check_for_symmetry`: the same handful of poses, step after step, is
  # what a symmetric object looks like. Anything else resets the count, because
  # the evidence has to be consecutive.
  defp check_for_symmetry(%__MODULE__{last_unique_poses: nil} = lm, _poses, _count),
    do: {lm, false}

  defp check_for_symmetry(lm, euler_poses, num_locations) do
    unchanged? =
      num_locations == lm.last_num_unique_locations and
        length(euler_poses) == length(lm.last_unique_poses) and
        euler_poses == lm.last_unique_poses

    lm = %{lm | symmetry_evidence: if(unchanged?, do: lm.symmetry_evidence + 1, else: 0)}

    if enough_symmetry_evidence?(lm) do
      Monty.Trace.trace(fn -> "Symmetry detected for poses #{inspect(euler_poses)}" end)
      {lm, true}
    else
      {lm, false}
    end
  end

  defp enough_symmetry_evidence?(%__MODULE__{} = lm),
    do: lm.symmetry_evidence >= lm.required_symmetry_evidence

  # Monty's `_get_possible_recent_paths`: the last few steps of the paths that
  # are not the same visit as an earlier one. Two paths that have converged onto
  # the same trajectory are one place to be, and without folding them together
  # the uniqueness test never passes.
  defp recent_unique_paths(lm, object_id) do
    case Map.get(lm.graph_lm.possible_paths, object_id, []) do
      [] ->
        []

      [first | _rest] = paths when is_number(first) ->
        paths

      paths ->
        recent =
          if length(hd(paths)) <= 4, do: paths, else: Enum.map(paths, &Enum.take(&1, -4))

        GraphMatchingUtils.unique_paths(recent, lm.path_similarity_threshold)
    end
  end

  defp record_pose_stats(lm, detected_path, location_on_model, euler_poses, rotations, scale) do
    stats = %{
      "detected_path" => detected_path,
      "detected_location_on_model" => location_on_model,
      "detected_location_rel_body" =>
        FeatureAtLocationBuffer.current_location(lm.graph_lm.buffer),
      "detected_rotation" => hd(euler_poses),
      "detected_rotation_quat" => Rotation.to_xyzw(hd(rotations)),
      "detected_scale" => scale
    }

    %{
      lm
      | graph_lm: %{
          lm.graph_lm
          | buffer: FeatureAtLocationBuffer.add_overall_stats(lm.graph_lm.buffer, stats)
        }
    }
  end

  defp record_symmetry_stats_if_detected(lm, object_id) do
    if enough_symmetry_evidence?(lm) do
      stats = %{
        "symmetric_rotations" => lm.last_unique_poses,
        "symmetric_locations" =>
          lm.graph_lm.possible_paths |> Map.fetch!(object_id) |> Enum.map(&List.last/1)
      }

      %{
        lm
        | graph_lm: %{
            lm.graph_lm
            | buffer: FeatureAtLocationBuffer.add_overall_stats(lm.graph_lm.buffer, stats)
          }
      }
    else
      lm
    end
  end

  @doc """
  Monty's `update_terminal_condition`: has this module concluded?

  The decision is `GraphLM`'s; what a feature module adds is the pose, which
  Monty records as a side effect of being asked. So it is worked out first, here,
  and handed to the base as the answer to "is the pose narrowed down".
  """
  @impl true
  @spec update_terminal_condition(t()) :: {t(), GraphLM.terminal_state()}
  def update_terminal_condition(%__MODULE__{} = lm) do
    {lm, pose} =
      case GraphLM.get_possible_matches(lm.graph_lm) do
        [object_id] ->
          case get_unique_pose_if_available(lm, object_id) do
            {lm, {:ok, %{pose: pose}}} -> {lm, pose}
            {lm, :not_narrowed} -> {lm, nil}
          end

        _several_or_none ->
          {lm, nil}
      end

    {graph_lm, terminal_state} =
      GraphLM.update_terminal_condition(lm.graph_lm, fn _graph_lm, _object_id -> pose end)

    {%{lm | graph_lm: graph_lm}, terminal_state}
  end

  # -- what a step is worth logging -----------------------------------------

  @doc """
  The rotations still possible on each object, one list per path.

  Monty's `get_possible_poses`: as Euler angles in degrees, each the *inverse* of
  the stored rotation — the turn that takes the sensed frame onto the model's —
  which is the form a reader of a log or a chart expects to compare against the
  object's pose.
  """
  @spec get_possible_poses(t(), boolean()) :: %{optional(GraphMemory.graph_id()) => list()}
  def get_possible_poses(%__MODULE__{} = lm, as_euler \\ true) do
    if as_euler do
      Map.new(lm.possible_poses, fn {graph_id, paths} ->
        {graph_id,
         Enum.map(paths, fn poses ->
           Enum.map(poses, fn pose ->
             pose |> Rotation.invert() |> Rotation.to_euler_degrees(5)
           end)
         end)}
      end)
    else
      lm.possible_poses
    end
  end

  @doc "Monty's `_add_detailed_stats`: the paths, the poses and the symmetry count."
  @spec add_detailed_stats(t(), map()) :: map()
  def add_detailed_stats(%__MODULE__{} = lm, stats) do
    Map.merge(stats, %{
      "possible_paths" => lm.graph_lm.possible_paths,
      "possible_poses" => get_possible_poses(lm),
      "symmetry_evidence" => lm.symmetry_evidence
    })
  end
end
