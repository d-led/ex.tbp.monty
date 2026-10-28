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

  alias Monty.Frameworks.Models.EvidenceMatching.Channels

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer.HypothesisDisplacerTelemetry
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
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
  """
  @spec compute_evidence(
          t(),
          %{optional(String.t()) => map()},
          float(),
          String.t(),
          Hypotheses.t()
        ) ::
          {Hypotheses.t(), HypothesisDisplacerTelemetry.t()}
  def compute_evidence(
        %__MODULE__{} = displacer,
        features,
        evidence_update_threshold,
        graph_id,
        hypotheses
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
          evidence_to_add(displacer, features, graph_id, input_channels, to_test, hypotheses)

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

  defp evidence_to_add(displacer, features, graph_id, input_channels, to_test, hypotheses) do
    search_locations = Enum.map(to_test, &Enum.at(hypotheses.locations, &1))
    poses = Enum.map(to_test, &Enum.at(hypotheses.poses, &1))

    # Where each tested hypothesis sits in the full set, so the update can be
    # spread over every hypothesis without searching for them one at a time.
    positions = to_test |> Enum.with_index() |> Map.new()

    Enum.reduce(input_channels, List.duplicate(0.0, Hypotheses.count(hypotheses)), fn channel,
                                                                                      totals ->
      channel_features = Map.fetch!(features, channel)

      evidence =
        evidence_for_new_locations(
          displacer,
          graph_id,
          channel,
          search_locations,
          poses,
          channel_features
        )

      # Untested hypotheses get the worst tested update, floored at zero: being
      # skipped must not earn evidence, and must not be punished either.
      skipped_update = evidence |> Enum.min() |> max(0.0)

      Enum.map(Enum.with_index(totals), fn {total, index} ->
        case Map.fetch(positions, index) do
          :error -> total + skipped_update
          {:ok, position} -> total + Enum.at(evidence, position)
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
         channel_features
       ) do
    graph = GraphMemory.get_graph(displacer.graph_memory, graph_id, input_channel)

    channel_locations =
      displacer.graph_memory
      |> GraphMemory.get_locations_in_graph(graph_id, input_channel)
      |> List.to_tuple()

    nearest =
      displacer.graph_memory.object_model.find_nearest_neighbors(
        graph,
        search_locations,
        min(displacer.max_nneighbors, tuple_size(channel_locations))
      )

    rotated = Enum.map(poses, fn pose -> rotate(channel_features["pose_vectors"], pose) end)
    curvature = GraphMatchingUtils.relevant_curvature(channel_features)

    node_feature_evidence =
      DefaultFeatureEvidenceScorer.evidence(
        displacer.feature_evidence_scorer,
        graph_id,
        input_channel,
        channel_features
      )
      |> List.to_tuple()

    # Every hypothesis reads the pose features of its neighbours, so they are
    # read once for the whole graph rather than once per hypothesis.
    {all_node_poses, all_node_pose_flags} =
      node_poses(displacer, graph_id, input_channel, tuple_size(channel_locations))

    Enum.zip_with([search_locations, rotated, nearest], fn [
                                                             search_location,
                                                             pose_vectors,
                                                             node_ids
                                                           ] ->
      node_locations = Enum.map(node_ids, &elem(channel_locations, &1))

      [distances] =
        GraphMatchingUtils.custom_distances(
          [node_locations],
          [search_location],
          [hd(pose_vectors)],
          curvature
        )

      too_far = Enum.map(distances, fn distance -> weight(displacer, distance) <= 0 end)

      radius_evidence =
        pose_evidence(
          displacer,
          pose_vectors,
          channel_features["pose_fully_defined"],
          Enum.map(node_ids, &elem(all_node_poses, &1)),
          Enum.map(node_ids, &elem(all_node_pose_flags, &1)),
          input_channel
        )

      radius_evidence
      |> Enum.zip(node_ids)
      |> Enum.with_index()
      |> Enum.map(fn {{evidence, node_id}, position} ->
        if Enum.at(too_far, position),
          do: @min_evidence,
          else: evidence + elem(node_feature_evidence, node_id)
      end)
      |> Enum.max()
    end)
  end

  # One pose per node, flattened as stored, and whether that pose was fully
  # defined — the two things the pose comparison reads.
  defp node_poses(displacer, graph_id, input_channel, num_nodes) do
    features =
      displacer.graph_memory
      |> GraphMemory.get_features_at_node(
        graph_id,
        input_channel,
        Enum.to_list(0..(num_nodes - 1)//1),
        ["pose_vectors", "pose_fully_defined"]
      )

    {List.to_tuple(Map.fetch!(features, "pose_vectors")),
     features |> Map.fetch!("pose_fully_defined") |> Enum.map(&hd/1) |> List.to_tuple()}
  end

  # Pose evidence in [-1, 1]: surface normal and first curvature direction, each
  # worth 0.5 when they match and -0.5 when perpendicular. The second curvature
  # direction is always 90° from the first, so it adds nothing.
  defp pose_evidence(
         displacer,
         [normal, curvature_1 | _rest],
         fully_defined?,
         node_poses,
         node_defined,
         input_channel
       ) do
    weights = Map.fetch!(displacer.feature_weights, input_channel)["pose_vectors"]
    normal_weight = Enum.at(weights, 0)
    curvature_weight = if fully_defined?, do: Enum.at(weights, 1), else: 0.0

    Enum.zip_with(node_poses, node_defined, fn node_pose, stored_defined ->
      stored_normal = Enum.take(node_pose, 3)
      stored_curvature = Enum.slice(node_pose, 3, 3)
      stored_defined? = stored_defined != 0.0

      normal_evidence = -(:math.sin(angle(stored_normal, normal) / 2) - 0.5)

      curvature_evidence =
        if fully_defined? do
          # A curvature direction has no sign, so 0° and 180° are equally good and
          # 90° is the worst case: that is what folding the angle at π/2 does.
          error = @half_turn - abs(angle(stored_curvature, curvature_1) - @half_turn)
          -(:math.sin(error) - 0.5) * if(stored_defined?, do: 1.0, else: 0.0)
        else
          0.0
        end

      normal_evidence * normal_weight + curvature_evidence * curvature_weight
    end)
  end

  defp angle(a, b),
    do:
      SpatialArithmetics.get_angle(
        SpatialArithmetics.normalize(a),
        SpatialArithmetics.normalize(b)
      )

  defp rotate(pose_vectors, pose) do
    pose_vectors
    |> Enum.chunk_every(3)
    |> Enum.map(&Geometry.apply(pose, &1))
  end

  defp weight(%__MODULE__{max_match_distance: max}, distance), do: (max - distance) / max

  defp argmax(values) do
    values |> Enum.with_index() |> Enum.max_by(fn {value, _index} -> value end) |> elem(1)
  end
end
