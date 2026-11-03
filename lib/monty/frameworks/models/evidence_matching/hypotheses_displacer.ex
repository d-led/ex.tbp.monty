defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer do
  @moduledoc """
  Where hypotheses move to, and how much evidence they earn there.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/hypotheses_displacer.py`.
  Two jobs:

    * **displacement** — a hypothesis says "the sensor is here and the object is
      turned this way", so when the sensor moves by `d` the hypothesis moves to
      `pose · d`. Every hypothesis is moved, not just the likely ones: dropping
      one would lose the path information it carries.
    * **evidence** — for each hypothesis worth testing, find the graph nodes
      around its search location and score the sensed pose and features there.

  ## The range evidence has

  Pose evidence is in `[-1, 1]`: `-0.5` for the surface normal plus `-0.5` for
  the first curvature direction, each mapped so a perfect match scores `+0.5`
  and a perpendicular one `-0.5`. Feature evidence is `[0, 1]`, so one channel
  contributes `[-1, 2]` — `MIN_EVIDENCE`, `MAX_EVIDENCE` below. Summed over `C`
  channels that is `[-C, 2C]`, which is why the prediction error divides by
  `EVIDENCE_RANGE * C`. A hypothesis with no node within `max_match_distance`
  scores `-1`: being wrong is worse than being uninformative.
  """

  alias ExTbpMonty.MatcherNif

  alias Monty.Frameworks.Models.EvidenceMatching.Channels

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer.HypothesisDisplacerTelemetry
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Frameworks.Utils.KdTree
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry

  @min_evidence -1.0
  @max_evidence 2.0
  @evidence_range @max_evidence - @min_evidence
  @half_turn :math.pi() / 2

  @enforce_keys [:graph_memory, :feature_weights, :max_match_distance]
  defstruct graph_memory: nil,
            feature_weights: %{},
            max_match_distance: nil,
            max_nneighbors: 3,
            past_weight: 1,
            present_weight: 1,
            feature_evidence_scorer: nil

  @type t :: %__MODULE__{}

  @doc """
  A displacer over `memory`.

  `:max_match_distance` is how far a search location may sit from a stored node
  and still match it. `:past_weight` and `:present_weight` decide how much of a
  hypothesis' history survives each observation; adding to one bounds the
  evidence, which is Monty's reason for having both.
  """
  @spec new(GraphMemory.t(), keyword()) :: t()
  def new(%GraphMemory{} = memory, options) do
    feature_weights = Keyword.fetch!(options, :feature_weights)

    %__MODULE__{
      graph_memory: memory,
      feature_weights: feature_weights,
      max_match_distance: Keyword.fetch!(options, :max_match_distance),
      max_nneighbors: Keyword.get(options, :max_nneighbors, 3),
      past_weight: Keyword.get(options, :past_weight, 1),
      present_weight: Keyword.get(options, :present_weight, 1),
      feature_evidence_scorer:
        Keyword.get_lazy(options, :feature_evidence_scorer, fn ->
          DefaultFeatureEvidenceScorer.new(memory,
            feature_weights: feature_weights,
            tolerances: Keyword.get(options, :tolerances, %{})
          )
        end)
    }
  end

  @doc """
  Move every hypothesis by `displacement`, as its own object orientation sees it.
  """
  @spec displace_hypotheses(t(), Hypotheses.t(), [number()]) :: Hypotheses.t()
  def displace_hypotheses(%__MODULE__{}, %Hypotheses{} = hypotheses, displacement) do
    search_locations =
      Enum.zip_with(hypotheses.poses, hypotheses.locations, fn pose, location ->
        SpatialArithmetics.add(location, Geometry.apply(pose, displacement))
      end)

    %Hypotheses{hypotheses | locations: search_locations}
  end

  @doc """
  Add this observation's evidence to the hypotheses worth testing.

  Hypotheses below `evidence_update_threshold` keep their evidence and gain
  nothing from this step: a cheap way to keep the space bounded without throwing
  the alternatives away.

  Options:

    * `:node_feature_evidence` — what each stored node is worth for one channel,
      from `node_feature_evidence/4`. The same comparison decides which nodes
      burst sampling draws from and what a hypothesis earns at a node, so the
      sampler hands its answer over rather than having it computed twice per
      step. Absent, it is computed here.
  """
  @spec compute_evidence(
          t(),
          %{optional(String.t()) => map()},
          float(),
          String.t(),
          Hypotheses.t(),
          keyword()
        ) ::
          {Hypotheses.t(), HypothesisDisplacerTelemetry.t()}
  def compute_evidence(
        %__MODULE__{} = displacer,
        features,
        evidence_update_threshold,
        graph_id,
        hypotheses,
        options \\ []
      ) do
    to_test =
      for {evidence, index} <- Enum.with_index(hypotheses.evidence),
          evidence >= evidence_update_threshold,
          do: index

    case to_test do
      [] ->
        # Nothing has been predicted yet, so there is no prediction error to report.
        {hypotheses, %HypothesisDisplacerTelemetry{mlh_prediction_error: nil}}

      to_test ->
        input_channels =
          Channels.all_usable_input_channels(
            features,
            GraphMemory.get_input_channels_in_graph(displacer.graph_memory, graph_id)
          )

        to_add =
          evidence_to_add(
            displacer,
            features,
            graph_id,
            input_channels,
            to_test,
            hypotheses,
            Keyword.get(options, :node_feature_evidence, %{})
          )

        mlh_evidence = Enum.at(to_add, argmax(hypotheses.evidence))
        channels = length(input_channels)

        evidence =
          Enum.zip_with(hypotheses.evidence, to_add, fn past, present ->
            past * displacer.past_weight + present * displacer.present_weight
          end)

        {%Hypotheses{hypotheses | evidence: evidence},
         %HypothesisDisplacerTelemetry{
           mlh_prediction_error:
             (@max_evidence * channels - mlh_evidence) / (@evidence_range * channels)
         }}
    end
  end

  @doc """
  What each stored node is worth against the sensed features, for one channel.

  One comparison per node, in the nodes' own order: burst sampling draws from it
  when it decides where to put new hypotheses, and the evidence kernel reads it
  when it decides what a hypothesis earns at a node. Both ask the same question
  of the same graph and channel in the same step, so it is answered once.
  """
  @spec node_feature_evidence(t(), String.t(), String.t(), map()) :: [number()]
  def node_feature_evidence(%__MODULE__{} = displacer, graph_id, input_channel, channel_features) do
    DefaultFeatureEvidenceScorer.evidence(
      displacer.feature_evidence_scorer,
      graph_id,
      input_channel,
      channel_features
    )
  end

  defp evidence_to_add(
         displacer,
         features,
         graph_id,
         input_channels,
         to_test,
         hypotheses,
         given_node_evidence
       ) do
    # Hypotheses are reached by position, so they are turned into tuples once:
    # `Enum.at/2` on a list walks to the index, and asking that of every index
    # is a quadratic pass over the whole hypothesis space, every step.
    locations = List.to_tuple(hypotheses.locations)
    poses = List.to_tuple(hypotheses.poses)

    search_locations = Enum.map(to_test, &elem(locations, &1))
    tested_poses = Enum.map(to_test, &elem(poses, &1))

    # Where each tested hypothesis sits in the full set, so the update can be
    # spread over every hypothesis without searching for them one at a time.
    positions = to_test |> Enum.with_index() |> Map.new()

    Enum.reduce(input_channels, List.duplicate(0.0, Hypotheses.count(hypotheses)), fn channel,
                                                                                      totals ->
      channel_features = Map.fetch!(features, channel)

      node_feature_evidence =
        Map.get_lazy(given_node_evidence, channel, fn ->
          node_feature_evidence(displacer, graph_id, channel, channel_features)
        end)

      evidence =
        evidence_for_new_locations(
          displacer,
          graph_id,
          channel,
          search_locations,
          tested_poses,
          channel_features,
          node_feature_evidence
        )
        |> List.to_tuple()

      # Untested hypotheses get the worst tested update, floored at zero: being
      # skipped must not earn evidence, and must not be punished either.
      skipped_update = evidence |> Tuple.to_list() |> Enum.min() |> max(0.0)

      Enum.with_index(totals)
      |> Enum.map(fn {total, index} ->
        case Map.fetch(positions, index) do
          :error -> total + skipped_update
          {:ok, position} -> total + elem(evidence, position)
        end
      end)
    end)
  end

  defp evidence_for_new_locations(
         displacer,
         graph_id,
         input_channel,
         search_locations,
         poses,
         channel_features,
         node_feature_evidence
       ) do
    graph = GraphMemory.get_graph(displacer.graph_memory, graph_id, input_channel)

    capacity =
      min(
        displacer.max_nneighbors,
        GraphMemory.get_num_nodes_in_graph(displacer.graph_memory, graph_id, input_channel)
      )

    # The graph's own arrays are read from memory rather than rebuilt: where every
    # node is, how its frame sits and whether that frame was defined are what the
    # graph holds when an episode starts, and they are flattened once with its
    # feature rows rather than once a step.
    with true <- MatcherNif.loaded?(),
         {nodes, node_poses, node_defined} when is_binary(nodes) <-
           GraphMemory.get_node_arrays(displacer.graph_memory, graph_id, input_channel),
         {ids, k} when is_binary(ids) and k > 0 <-
           displacer.graph_memory.object_model.find_nearest_neighbor_ids(
             graph,
             search_locations,
             capacity
           ) do
      native_evidence(
        displacer,
        input_channel,
        search_locations,
        poses,
        channel_features,
        node_feature_evidence,
        {ids, k},
        {nodes, node_poses, node_defined}
      )
    else
      _read_the_reference ->
        reference_evidence(
          displacer,
          graph_id,
          input_channel,
          search_locations,
          poses,
          channel_features,
          node_feature_evidence
        )
    end
  end

  # The same comparison, one native call for the whole graph and channel.
  #
  # The graph arrives as the bytes a kernel reads — where every node is, how its
  # pose sits, whether that pose was defined, what it is worth — and the answer
  # comes back as one float per hypothesis. What used to be a hypothesis-sized
  # list of lists per graph is now the bytes it was built from.
  defp native_evidence(
         displacer,
         input_channel,
         search_locations,
         poses,
         channel_features,
         node_feature_evidence,
         {ids, k},
         {nodes, node_poses, node_defined}
       ) do
    {normal_weight, curvature_weight} =
      pose_weights(displacer, input_channel, channel_features["pose_fully_defined"])

    flatness =
      GraphMatchingUtils.flatness(GraphMatchingUtils.relevant_curvature(channel_features))

    MatcherNif.neighbour_evidence(
      ids,
      k,
      [
        KdTree.points_bytes(search_locations),
        hypothesis_poses_bytes(poses),
        sensed_pose_bytes(channel_features["pose_vectors"])
      ],
      [nodes, node_poses, node_defined, evidence_bytes(node_feature_evidence)],
      params_bytes([
        flatness,
        displacer.max_match_distance,
        normal_weight,
        curvature_weight,
        if(channel_features["pose_fully_defined"], do: 1.0, else: 0.0),
        @min_evidence
      ])
    )
    |> MatcherNif.decode()
  end

  defp reference_evidence(
         displacer,
         graph_id,
         input_channel,
         search_locations,
         poses,
         channel_features,
         node_feature_evidence
       ) do
    channel_locations =
      displacer.graph_memory
      |> GraphMemory.get_locations_in_graph(graph_id, input_channel)
      |> List.to_tuple()

    nearest =
      displacer.graph_memory.object_model.find_nearest_neighbors(
        GraphMemory.get_graph(displacer.graph_memory, graph_id, input_channel),
        search_locations,
        min(displacer.max_nneighbors, tuple_size(channel_locations))
      )

    # Only the normal and the first curvature direction are ever read off the
    # rotated pose, so turning one and judging that hypothesis' neighbours is one
    # pass: the turned directions are not three more hypothesis-sized lists.
    channel_feature_vectors = channel_features["pose_vectors"]
    curvature = GraphMatchingUtils.relevant_curvature(channel_features)

    node_feature_evidence = List.to_tuple(node_feature_evidence)

    # Every hypothesis reads the pose features of its neighbours, so they are
    # read once for the whole graph rather than once per hypothesis.
    {all_node_poses, all_node_pose_flags} =
      node_poses(displacer, graph_id, input_channel, tuple_size(channel_locations))

    comparison = %{
      weights: pose_weights(displacer, input_channel, channel_features["pose_fully_defined"]),
      fully_defined?: channel_features["pose_fully_defined"],
      locations: channel_locations,
      flatness: GraphMatchingUtils.flatness(curvature),
      node_poses: all_node_poses,
      node_defined: all_node_pose_flags,
      node_feature_evidence: node_feature_evidence,
      max_match_distance: displacer.max_match_distance
    }

    Enum.zip_with([poses, nearest, search_locations], fn one ->
      [pose, node_ids, search_location] = one
      {normal, curvature_1} = rotate_normal_and_curvature(channel_feature_vectors, pose)
      best_of_neighbours(node_ids, search_location, normal, curvature_1, comparison)
    end)
  end

  # The bytes a kernel reads that this step has to build: the hypotheses' own
  # rotations, one after another, and what each stored node is worth on its
  # features. The graph's own arrays are not here — they are read from memory,
  # flattened once when the graph was built.
  defp hypothesis_poses_bytes(poses) do
    poses
    |> Enum.map(fn [[p, q, r], [s, t, u], [v, w, x]] ->
      <<p * 1.0::float-64-little, q * 1.0::float-64-little, r * 1.0::float-64-little,
        s * 1.0::float-64-little, t * 1.0::float-64-little, u * 1.0::float-64-little,
        v * 1.0::float-64-little, w * 1.0::float-64-little, x * 1.0::float-64-little>>
    end)
    |> IO.iodata_to_binary()
  end

  defp sensed_pose_bytes([n1, n2, n3, d1, d2, d3 | _unread]) do
    params_bytes([n1, n2, n3, d1, d2, d3])
  end

  # A node whose features could not be read has no evidence, which a kernel reads
  # as a NaN — the same value a missing feature is written with.
  defp evidence_bytes(evidence) do
    for value <- evidence, into: <<>> do
      case value do
        nil -> MatcherNif.not_a_number()
        number -> <<number * 1.0::float-64-little>>
      end
    end
  end

  defp params_bytes(values) do
    for value <- values, into: <<>>, do: <<value * 1.0::float-64-little>>
  end

  # The best neighbour decides a hypothesis' evidence, so the neighbour ids are
  # walked once and the best kept. Everything a neighbour is judged by — where it
  # sits, what it looks like, what it is worth — is read by id, so no list of
  # node locations, of distances or of evidence is built per hypothesis.
  defp best_of_neighbours(
         [node_id | ids],
         search_location,
         normal,
         curvature_1,
         comparison
       ) do
    best_of_neighbours(
      ids,
      search_location,
      normal,
      curvature_1,
      comparison,
      neighbour_evidence(node_id, search_location, normal, curvature_1, comparison)
    )
  end

  defp best_of_neighbours([], _search_location, _normal, _curvature_1, _comparison, best),
    do: best

  defp best_of_neighbours(
         [node_id | ids],
         search_location,
         normal,
         curvature_1,
         comparison,
         best
       ) do
    best_of_neighbours(
      ids,
      search_location,
      normal,
      curvature_1,
      comparison,
      max(best, neighbour_evidence(node_id, search_location, normal, curvature_1, comparison))
    )
  end

  # A neighbour beyond `max_match_distance` is no neighbour at all: it says the
  # sensor's location has nothing to do with this hypothesis, which is the worst
  # evidence there is.
  defp neighbour_evidence(node_id, search_location, normal, curvature_1, comparison) do
    distance =
      GraphMatchingUtils.custom_distance(
        elem(comparison.locations, node_id),
        search_location,
        normal,
        comparison.flatness
      )

    if (comparison.max_match_distance - distance) / comparison.max_match_distance <= 0 do
      @min_evidence
    else
      {stored_normal, stored_curvature} = elem(comparison.node_poses, node_id)

      pose_evidence(
        comparison,
        normal,
        curvature_1,
        stored_normal,
        stored_curvature,
        elem(comparison.node_defined, node_id) != 0.0
      ) + elem(comparison.node_feature_evidence, node_id)
    end
  end

  # One stored pose, cut into the two directions the comparison reads: the
  # normal and the first curvature direction. Where a pose is stored end to end
  # the cut is the same for every node, so it belongs to the graph rather than to
  # the hypothesis that happens to ask.
  defp node_poses(displacer, graph_id, input_channel, num_nodes) do
    features =
      displacer.graph_memory
      |> GraphMemory.get_features_at_node(
        graph_id,
        input_channel,
        Enum.to_list(0..(num_nodes - 1)//1),
        ["pose_vectors", "pose_fully_defined"]
      )

    {features
     |> Map.fetch!("pose_vectors")
     |> Enum.map(fn pose -> {Enum.take(pose, 3), Enum.slice(pose, 3, 3)} end)
     |> List.to_tuple(),
     features |> Map.fetch!("pose_fully_defined") |> Enum.map(&hd/1) |> List.to_tuple()}
  end

  # What the pose comparison weighs its two directions: the normal always, the
  # first curvature direction only when the observation defined one.
  defp pose_weights(displacer, input_channel, fully_defined?) do
    weights = Map.fetch!(displacer.feature_weights, input_channel)["pose_vectors"]
    {Enum.at(weights, 0), if(fully_defined?, do: Enum.at(weights, 1), else: 0.0)}
  end

  # Pose evidence in [-1, 1]: surface normal and first curvature direction, each
  # worth 0.5 when they match and -0.5 when perpendicular. The second curvature
  # direction is always 90° from the first, so it adds nothing.
  defp pose_evidence(
         comparison,
         normal,
         curvature_1,
         stored_normal,
         stored_curvature,
         stored_defined?
       ) do
    {normal_weight, curvature_weight} = comparison.weights
    normal_evidence = -(:math.sin(angle(stored_normal, normal) / 2) - 0.5)

    curvature_evidence =
      if comparison.fully_defined? do
        # A curvature direction has no sign, so 0° and 180° are equally good and
        # 90° is the worst case: that is what folding the angle at π/2 does.
        error = @half_turn - abs(angle(stored_curvature, curvature_1) - @half_turn)
        -(:math.sin(error) - 0.5) * if(stored_defined?, do: 1.0, else: 0.0)
      else
        0.0
      end

    normal_evidence * normal_weight + curvature_evidence * curvature_weight
  end

  # The angle Monty reads off two pose directions, straight from the dot product
  # and clipped at ±1, with no normalisation. That is not an oversight on its
  # side: the stored direction is a measurement whose length is not exactly one,
  # and the rotation that turns the sensed frame onto it is only nearly a
  # rotation, so both lengths are already part of the comparison. Normalising
  # them first "fixes" a cosine that is not wrong and moves the evidence.
  defp angle(a, b), do: SpatialArithmetics.get_angle(a, b)

  # The sensed pose arrives as three directions end to end, and Monty turns each
  # by the hypothesis pose. The third is never read, so it is not turned; and
  # the two that are turned are one matrix times one vector, which the generic
  # three-vectors-in-a-list helpers spend a chunk and a closure per hypothesis to
  # say. Same products in the same order, so the same floats.
  defp rotate_normal_and_curvature(
         [n1, n2, n3, d1, d2, d3 | _unread],
         [[p, q, r], [s, t, u], [v, w, x]]
       ) do
    normal = [p * n1 + q * n2 + r * n3, s * n1 + t * n2 + u * n3, v * n1 + w * n2 + x * n3]
    curvature = [p * d1 + q * d2 + r * d3, s * d1 + t * d2 + u * d3, v * d1 + w * d2 + x * d3]

    {normal, curvature}
  end

  defp argmax(values) do
    values |> Enum.with_index() |> Enum.max_by(fn {value, _index} -> value end) |> elem(1)
  end
end
