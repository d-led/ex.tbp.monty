defmodule Monty.Frameworks.Models.DisplacementMatching.DisplacementGraphLM do
  @moduledoc """
  A learning module that recognises objects by the displacements between what it
  senses: Monty's `DisplacementGraphLM`.

  Every step, the module knows how far the sensor moved. A graph of an object
  knows which nodes are joined by which displacement, so "did this object's
  graph have an edge like that, from where I think I am" narrows the object
  down without comparing a single feature. Two answers at the end: the object,
  and the turn between the displacements it sensed and the ones its graph
  predicted — which together with a scale is the object's pose.

  This is the simplest learning module in Monty and the one the tutorial starts
  from: one sensor, one module, one object, a thousand exploratory steps.

  ## What it composes

  `%Monty.Frameworks.Models.GraphMatching.GraphLM{}` is the graph module
  underneath — the buffer, the goal generator, the votes, the conclusion — and
  this adds the three things a displacement match needs: the paths being tested,
  the paths each step extends them to, and the scale factors that make the
  length comparison relative. Monty inherits those from `GraphLM`; here they are
  fields of the class that uses them, and the matching step is written out
  rather than delegated, because the paths are this class's state and a callback
  could not hand them back.

  ## Not ported

  `match_attribute: "PPF"` — matching on point-pair features instead of raw
  displacements, which also brings relative lengths and a different edge.
  `new/1` refuses it rather than matching something else, and the tutorial's
  config asks for `"displacement"`.
  """

  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.DisplacementMatching.DisplacementGraphMemory
  alias Monty.Frameworks.Models.GraphMatching.GraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  @default_tolerance 0.001

  @enforce_keys [:graph_lm, :match_attribute]
  defstruct graph_lm: nil,
            match_attribute: nil,
            tolerance: @default_tolerance,
            use_relative_len: false,
            possible_paths: %{},
            next_possible_paths: %{},
            scale_factors: %{}

  @type t :: %__MODULE__{}

  @doc """
  A module with an empty memory.

  `:k` is how many neighbours each node of a graph links to — the edges are what
  a displacement is matched against, so a graph with no edges can match nothing.
  `:tolerance` is how far an observed displacement may sit from a stored one and
  still be called the same; `:use_relative_len` divides lengths by the first
  displacement, which is scale invariance at the cost of a scale you cannot
  measure.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    match_attribute = Keyword.get(options, :match_attribute, "displacement")

    if match_attribute != "displacement" do
      raise ArgumentError,
            "match_attribute #{inspect(match_attribute)} is not ported: only " <>
              ~s("displacement" is, and matching on point-pair features would be a) <>
              " different experiment"
    end

    %__MODULE__{
      graph_lm:
        GraphLM.new(
          options
          |> Keyword.take([:learning_module_id, :tolerances, :has_detailed_logger, :gsg])
          |> Keyword.put(:graph_memory, graph_memory(options))
        ),
      match_attribute: match_attribute,
      tolerance: Keyword.get(options, :tolerance, @default_tolerance),
      use_relative_len: Keyword.get(options, :use_relative_len, false)
    }
  end

  # The edges are the hypothesis: a graph built with no `k` has no neighbours to
  # match a displacement against, so whatever the config says is passed on as it
  # stands rather than defaulted here.
  defp graph_memory(options) do
    GraphMemory.new(
      k: Keyword.get(options, :k),
      graph_delta_thresholds: Keyword.get(options, :graph_delta_thresholds)
    )
  end

  @doc """
  What the module starts an episode from: every object in memory, every node as
  a path, every edge as the path the first movement is matched against.

  Monty's `init_from_ltm`. The memory is what knows the graphs; this holds the
  paths, because a path is where *this* episode's sensor has been.
  """
  @spec init_from_ltm(t()) :: t()
  def init_from_ltm(%__MODULE__{} = lm) do
    hypotheses = DisplacementGraphMemory.get_initial_hypotheses(lm.graph_lm.graph_memory)

    %{
      lm
      | graph_lm: %{lm.graph_lm | possible_matches: hypotheses.possible_matches},
        possible_paths: hypotheses.possible_paths,
        next_possible_paths: hypotheses.next_possible_paths,
        scale_factors: hypotheses.scale_factors
    }
  end

  @doc "The same, with the buffer and the paths emptied first — Monty's `reset_stm`."
  @spec reset_stm(t()) :: t()
  def reset_stm(%__MODULE__{} = lm) do
    %{lm | graph_lm: GraphLM.reset_stm(lm.graph_lm)} |> init_from_ltm()
  end

  # -- the step -------------------------------------------------------------

  @doc """
  Monty's `matching_step`: match this step's displacement against the paths left.

  A step that carried only a location is nothing to match; the rest narrow the
  possible matches, and a module nothing is possible for any more concludes
  `:no_match`.
  """
  @spec matching_step([Monty.Cmp.Message.t()], Monty.Context.t(), t()) :: {:ok, t()}
  def matching_step(percepts, ctx, %__MODULE__{} = lm) do
    if Monty.Runtime.location_only_step?(percepts) do
      {:ok, lm}
    else
      first_movement_detected? = GraphLM.agent_moved_since_reset?(lm.graph_lm)
      feature_percepts = Enum.filter(percepts, & &1.process_features_in_lm)

      # A percept with no sensor location is nothing to measure a move from, which
      # `GraphLM` answers the same way: the module is unchanged this step.
      case add_displacements(lm, percepts) do
        {:error, _reason} ->
          {:ok, lm}

        {:ok, displaced} ->
          lm = %{lm | graph_lm: GraphLM.buffer_percepts(displaced, lm.graph_lm)}

          lm =
            lm
            |> compute_possible_matches(ctx, feature_percepts, first_movement_detected?)
            |> step_the_goal_generator(ctx, feature_percepts)

          {:ok, lm}
      end
    end
  end

  @doc "Monty's `exploratory_step`: keep the observation, match nothing yet."
  @spec exploratory_step([Monty.Cmp.Message.t()], Monty.Context.t(), t()) :: {:ok, t()}
  def exploratory_step(percepts, ctx, %__MODULE__{} = lm) do
    with {:ok, stepped} <- GraphLM.exploratory_step(percepts, ctx, lm.graph_lm) do
      {:ok, %{lm | graph_lm: stepped}}
    end
  end

  defp step_the_goal_generator(lm, ctx, feature_percepts) do
    graph_lm =
      if GraphLM.get_possible_matches(lm.graph_lm) == [] do
        GraphLM.set_individual_ts(lm.graph_lm, :no_match)
      else
        lm.graph_lm
      end

    graph_lm =
      graph_lm
      |> GraphLM.step_goal_generator(ctx, feature_percepts)
      |> GraphLM.record_stats(add_detailed_stats(lm, %{}))

    %{lm | graph_lm: graph_lm}
  end

  @doc """
  Monty's `_compute_possible_matches`: what the displacement says is still possible.

  This is a prediction, not a comparison of features: for every object still
  possible, take the paths this episode could be on, extend each along the edges
  whose displacement matches what was just sensed, and predict whether the
  sensor is still on the object. An object whose prediction is wrong — because
  no edge had that displacement, so the sensor cannot be on it — is ruled out.
  """
  @spec compute_possible_matches(t(), Monty.Context.t(), [Monty.Cmp.Message.t()], boolean()) ::
          t()
  def compute_possible_matches(%__MODULE__{} = lm, _ctx, _observation, false), do: lm

  def compute_possible_matches(%__MODULE__{} = lm, _ctx, observation, true) do
    query = FeatureAtLocationBuffer.current_displacement(lm.graph_lm.buffer)

    # Monty asks the same question of every graph and then removes the objects
    # that answered wrongly; an object with nothing left to test answers wrongly.
    {lm, predictions} =
      Enum.reduce(GraphLM.get_possible_matches(lm.graph_lm), {lm, %{}}, fn graph_id, {lm, acc} ->
        {lm, prediction} = predict_using_displacements(lm, query, graph_id)
        {lm, Map.put(acc, graph_id, prediction)}
      end)

    target = on_object_target(observation)

    keep_the_right_ones(lm, predictions, target)
  end

  defp keep_the_right_ones(lm, predictions, target) do
    still_possible =
      for {graph_id, prediction} <- predictions, target == prediction, do: graph_id

    possible_matches = Map.take(lm.graph_lm.possible_matches, still_possible)

    %{lm | graph_lm: %{lm.graph_lm | possible_matches: possible_matches}}
  end

  # Monty's `_select_features_to_use`: whether the sensor is on the object, which
  # is the whole of what a displacement module predicts. A percept that does not
  # say is taken to be on it.
  defp on_object_target([first | _rest]) do
    case Map.fetch(first.morphological_features, "on_object") do
      {:ok, on_object} -> if on_object, do: 1, else: 0
      :error -> 1
    end
  end

  defp on_object_target([]), do: 1

  # Monty's `_predict_using_displacements`: extend every path this episode could
  # be on by the edges whose stored displacement matches the sensed one.
  #
  # The paths that stay possible are the ones whose edge matched; the paths the
  # next step will test are those extended by one node. An object with no path
  # left is an object the sensor cannot be on — which is the prediction.
  defp predict_using_displacements(lm, displacement, graph_id) do
    {lm, paths} = step_paths(lm, displacement, graph_id)
    {lm, if(Enum.empty?(paths.possible), do: 0, else: 1)}
  end

  defp step_paths(lm, displacement, graph_id) do
    next_paths = Map.get(lm.next_possible_paths, graph_id, [])
    scale_factors = Map.get(lm.scale_factors, graph_id, [])
    graph = graph_of(lm, graph_id)

    {kept, extended, kept_scales} =
      next_paths
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {path, index}, {kept, extended, kept_scales} ->
        extend_if_matched(
          lm,
          graph,
          path,
          scale_factor_at(scale_factors, index),
          displacement,
          {kept, extended, kept_scales}
        )
      end)

    # Built backwards and turned round once: the paths stay in the order Monty
    # walks them, which is the order of the edges they came from.
    kept = Enum.reverse(kept)
    extended = Enum.reverse(extended)
    kept_scales = Enum.reverse(kept_scales)

    lm = %{
      lm
      | possible_paths: Map.put(lm.possible_paths, graph_id, kept),
        next_possible_paths: Map.put(lm.next_possible_paths, graph_id, extended),
        scale_factors: Map.put(lm.scale_factors, graph_id, kept_scales)
    }

    {lm, %{possible: kept, next: extended}}
  end

  defp extend_if_matched(lm, graph, path, scale_factor, displacement, acc) do
    {kept, extended, kept_scales} = acc
    current_node = List.last(path)
    previous_node = Enum.at(path, -2)

    with edge when is_integer(edge) <- edge_index(graph, previous_node, current_node),
         stored when is_list(stored) <- edge_attr(graph, edge),
         true <-
           within_tolerance?(
             comparable(stored, scale_factor, lm.use_relative_len),
             displacement,
             lm.tolerance
           ) do
      next_nodes =
        graph
        |> Map.fetch!(:edge_index)
        |> then(fn {sources, targets} -> sources |> Enum.zip(targets) end)
        |> Enum.filter(fn {source, _target} -> source == current_node end)
        |> Enum.map(fn {_source, target} -> target end)

      {
        [path | kept],
        Enum.map(next_nodes, &(path ++ [&1])) ++ extended,
        [scale_factor | kept_scales]
      }
    else
      _nothing_matched -> {kept, extended, kept_scales}
    end
  end

  defp scale_factor_at(scale_factors, index), do: Enum.at(scale_factors, index, 1.0)

  # A scale-invariant match divides the stored length by the factor the path was
  # learned at, which is Monty's `use_relative_len`; without it a stored
  # displacement is compared as it stands.
  defp comparable(stored, _scale_factor, false), do: stored
  defp comparable(stored, scale_factor, true), do: relative(stored, scale_factor)

  defp relative(displacement, scale_factor) do
    if scale_factor == 0.0 do
      displacement
    else
      [hd(displacement) / scale_factor | tl(displacement)]
    end
  end

  defp within_tolerance?(stored, displacement, tolerance) do
    displacement
    |> Enum.map(&(&1 * 1.0))
    |> Enum.zip(stored)
    |> Enum.all?(fn {sensed, kept} -> abs(sensed - kept) <= tolerance end)
  end

  defp edge_index(graph, previous_node, current_node) do
    {sources, targets} = Map.fetch!(graph, :edge_index)

    sources
    |> Enum.zip(targets)
    |> Enum.find_index(fn {source, target} ->
      source == previous_node and target == current_node
    end)
  end

  defp edge_attr(graph, edge), do: graph |> Map.get(:edge_attr, []) |> Enum.at(edge)

  defp first_channel(lm, graph_id),
    do:
      lm.graph_lm
      |> GraphLM.get_input_channels_in_graph(graph_id)
      |> hd()

  defp graph_of(lm, graph_id) do
    lm.graph_lm
    |> GraphLM.get_graph(graph_id, first_channel(lm, graph_id))
    |> GraphObjectModel.graph()
  end

  # -- the pose -------------------------------------------------------------

  @doc """
  Monty's `get_unique_pose_if_available`: where the object is, once the path is
  the only one left.

  `[x, y, z, euler_x, euler_y, euler_z, scale]` — the sensor's place on the
  object, the turn between the displacements it sensed and the ones the graph
  predicted, and how much bigger or smaller the object is than the one learned.
  Nothing until exactly one path is possible: two paths are two places to be.
  """
  @spec get_unique_pose_if_available(t(), String.t()) ::
          {:ok, map()} | :not_narrowed
  def get_unique_pose_if_available(%__MODULE__{} = lm, object_id) do
    with [path] when is_list(path) <- Map.get(lm.possible_paths, object_id, []),
         {:ok, channel} <-
           FeatureAtLocationBuffer.get_first_sensory_input_channel(lm.graph_lm.buffer),
         locations =
           GraphMemory.get_locations_in_graph(lm.graph_lm.graph_memory, object_id, channel),
         path_locations = Enum.map(path, &Enum.at(locations, &1)),
         [_ | _] = model_displacements <- consecutive(path_locations),
         [_ | _] = sensed <- sensed_displacements(lm.graph_lm.buffer),
         true <- length(sensed) == length(model_displacements) do
      {euler, _matrix, rotation} = get_object_rotation(sensed, model_displacements)
      scale = get_object_scale(Enum.at(sensed, 0), List.first(model_displacements))

      {:ok,
       %{
         path: path,
         pose: List.last(path_locations) ++ euler ++ [scale],
         location_on_model: List.last(path_locations),
         rotation: euler,
         rotation_quaternion: Rotation.to_xyzw(rotation),
         scale: scale
       }}
    else
      _not_one_path_or_no_displacements -> :not_narrowed
    end
  end

  defp consecutive(locations) do
    locations
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> SpatialArithmetics.subtract(to, from) end)
  end

  # The first step of an episode carries no displacement, so the sensed ones
  # start at the second — which is the same count as a path's edges.
  defp sensed_displacements(buffer) do
    case Map.get(buffer.displacements, "displacement", []) do
      [_first | rest] -> rest
      [] -> []
    end
  end

  @doc """
  The turn between two sets of vectors, Monty's `get_object_rotation`.

  `{euler degrees, matrix, rotation}`: the rotation that takes the sensed
  displacements onto the modelled ones, or — with `get_reverse_r` — the one that
  does the opposite, which turns the model to fit the senses.

  Two displacements along one line do not say how far to turn about it, so the
  answer is one of the rotations that fit; Monty's own comment says to keep
  moving, and so does this — nothing here refuses a pose.
  """
  @spec get_object_rotation([[number()]], [[number()]], boolean()) ::
          {[float()], [[float()]], Rotation.t()}
  def get_object_rotation(sensed_displacements, model_displacements, get_reverse_r \\ false) do
    {rotation, _rssd} =
      if get_reverse_r do
        Rotation.align_vectors(sensed_displacements, model_displacements)
      else
        Rotation.align_vectors(model_displacements, sensed_displacements)
      end

    {Rotation.to_euler_degrees(rotation), Rotation.to_matrix(rotation), rotation}
  end

  @doc "How much bigger the object is than the one in memory — Monty's `get_object_scale`."
  @spec get_object_scale([number()], [number()]) :: float()
  def get_object_scale(sensed_displacement, model_displacement) do
    SpatialArithmetics.magnitude(sensed_displacement) /
      SpatialArithmetics.magnitude(model_displacement)
  end

  # -- conclusions ----------------------------------------------------------

  @doc """
  Monty's `update_terminal_condition`: has this module concluded?

  The decision is `GraphLM`'s; what a displacement module adds is the pose,
  which Monty records as a side effect of being asked. So it is worked out
  first, here, and handed to the base as the answer to "is the pose narrowed
  down" — one place that computes it, and the conclusion the same as Monty's.
  """
  @spec update_terminal_condition(t()) :: {t(), atom() | nil}
  def update_terminal_condition(%__MODULE__{} = lm) do
    {lm, pose} =
      case GraphLM.get_possible_matches(lm.graph_lm) do
        [object_id] -> narrow_pose(lm, object_id)
        _several_or_none -> {lm, nil}
      end

    {graph_lm, terminal_state} =
      GraphLM.update_terminal_condition(lm.graph_lm, fn _graph_lm, _object_id -> pose end)

    {%{lm | graph_lm: graph_lm}, terminal_state}
  end

  defp narrow_pose(lm, object_id) do
    case get_unique_pose_if_available(lm, object_id) do
      {:ok, pose} ->
        {:ok, rotation} = Rotation.from_euler_degrees(pose.rotation)

        graph_lm = %{
          lm.graph_lm
          | detected_pose: pose.pose,
            detected_rotation_r: rotation
        }

        {%{lm | graph_lm: record_pose_stats(graph_lm, pose)}, pose.pose}

      :not_narrowed ->
        {lm, nil}
    end
  end

  # Monty's statistics for a pose: the path it came from, where on the model that
  # path ends, where the sensor was, and the turn and scale between them.
  defp record_pose_stats(graph_lm, pose) do
    stats = %{
      "detected_path" => pose.path,
      "detected_location_on_model" => pose.location_on_model,
      "detected_location_rel_body" => FeatureAtLocationBuffer.current_location(graph_lm.buffer),
      "detected_rotation" => pose.rotation,
      "detected_rotation_quat" => pose.rotation_quaternion,
      "detected_scale" => pose.scale
    }

    %{graph_lm | buffer: FeatureAtLocationBuffer.add_overall_stats(graph_lm.buffer, stats)}
  end

  @doc "Monty's `_add_detailed_stats`: the paths a match came from."
  @spec add_detailed_stats(t(), map()) :: map()
  def add_detailed_stats(%__MODULE__{} = lm, stats),
    do: Map.put(stats, "possible_paths", lm.possible_paths)

  # -- what a step carries --------------------------------------------------

  @doc """
  Monty's `_add_displacements` for this class: the step's displacement *and* the
  point-pair features of the move.

  The displacement is what a match is made of; the pair of features is what a
  point-pair-feature module would match on, and Monty computes both whatever the
  match attribute is. Both are set on every percept, because a learning module's
  own output moves with the sensor.
  """
  @spec add_displacements(t(), [Monty.Cmp.Message.t()]) ::
          {:ok, [Monty.Cmp.Message.t()]} | {:error, term()}
  def add_displacements(%__MODULE__{} = lm, percepts) do
    sensor_percepts = Enum.filter(percepts, &Monty.Cmp.Message.from_sensor_module?/1)

    case Monty.Cmp.location_mean(sensor_percepts) do
      nil ->
        {:error, :no_sensor_module_location}

      location ->
        {displacement, ppf} = movement(lm, location, sensor_percepts)

        {:ok, Enum.map(percepts, &Monty.Cmp.Message.set_displacement(&1, displacement, ppf))}
    end
  end

  defp movement(lm, location, [percept | _rest]) do
    case lm.graph_lm.buffer.last_location do
      nil ->
        {[0.0, 0.0, 0.0], zeros_four()}

      last_location ->
        lines = point_pair_features(lm, last_location, location, percept)
        {SpatialArithmetics.subtract(location, last_location), lines}
    end
  end

  defp movement(_lm, _location, []), do: {[0.0, 0.0, 0.0], zeros_four()}

  defp zeros_four, do: [0.0, 0.0, 0.0, 0.0]

  # The normal of the pose the buffer last held, and the one this percept brings:
  # the point-pair features are the line between the two locations against both.
  defp point_pair_features(lm, last_location, location, percept) do
    with {:ok, pose} <-
           FeatureAtLocationBuffer.get_current_pose(lm.graph_lm.buffer, percept.sender_id),
         previous_normal = Enum.at(pose, 1),
         {:ok, normal} <- Monty.Cmp.Message.surface_normal(percept) do
      SensorProcessing.point_pair_features(last_location, location, previous_normal, normal)
    else
      _no_pose_yet -> zeros_four()
    end
  end
end
