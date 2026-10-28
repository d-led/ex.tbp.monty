defmodule Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater do
  @moduledoc """
  Which hypotheses survive a step, and which new ones are worth trying.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/burst_sampling.py::BurstSamplingHypothesesUpdater`,
  the sampling strategy Monty's evidence matching actually runs.

  The idea: when evidence stops moving, one more observation of the same
  hypotheses will not settle anything. So when the largest evidence slope falls
  to `burst_trigger_slope` or below — and no burst is already running — the
  updater spends `burst_sampling_duration` steps sampling fresh hypotheses
  around the best-matching nodes, and drops the ones whose evidence is falling
  faster than `deletion_trigger_slope`. A burst therefore explores without
  simply growing the hypothesis space.

  ## Two passes, both deterministic

    * **existing** hypotheses are filtered by slope, never sampled randomly, so
      two runs of an episode keep the same ones;
    * **new** hypotheses come from the top `count ÷ rotations_per_node` nodes by
      *this* observation's feature evidence, each tried with every rotation the
      sensed pose allows.

  A new hypothesis starts with its feature evidence and `possible?: false`: it
  has earned nothing yet, but it is the alternative the burst exists to try.
  """

  @behaviour Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater

  alias Monty.Frameworks.Models.EvidenceMatching.Channels
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors

  defstruct graph_memory: nil,
            displacer: nil,
            scorer: nil,
            initial_possible_poses: nil,
            umbilical_num_poses: 8,
            sampling_multiplier: 0.4,
            burst_trigger_slope: 1.0,
            burst_sampling_duration: 5,
            deletion_trigger_slope: 0.5,
            sampling_burst_steps: 0,
            evidence_slope_trackers: %{},
            max_slope: 0.0

  @type t :: %__MODULE__{}

  @doc """
  An updater over `memory`.

  `:sampling_multiplier` is how many hypotheses per node a burst draws.
  `:initial_possible_poses` is `nil` for informed sampling — align each node's
  stored pose with what was sensed — or a list of 3×3 pose matrices for fixed
  poses.
  """
  @spec new(GraphMemory.t(), keyword()) :: t()
  def new(%GraphMemory{} = memory, options) do
    %__MODULE__{
      graph_memory: memory,
      displacer: Keyword.fetch!(options, :displacer),
      scorer: Keyword.fetch!(options, :scorer),
      initial_possible_poses: Keyword.get(options, :initial_possible_poses),
      umbilical_num_poses: Keyword.get(options, :umbilical_num_poses, 8),
      sampling_multiplier: Keyword.get(options, :sampling_multiplier, 0.4),
      burst_trigger_slope: Keyword.get(options, :burst_trigger_slope, 1.0),
      burst_sampling_duration: Keyword.get(options, :burst_sampling_duration, 5),
      deletion_trigger_slope: Keyword.get(options, :deletion_trigger_slope, 0.5)
    }
  end

  @doc "Forget what an episode learned, keeping the configuration."
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = updater),
    do: %{updater | sampling_burst_steps: 0, evidence_slope_trackers: %{}}

  @doc """
  Prepare the step: measure the evidence slope and start a burst if it stalled.

  A burst starts when evidence has stopped moving, not while it is climbing —
  while it climbs, another observation is the cheaper way to settle things.
  """
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec begin_step(t()) :: t()
  def begin_step(%__MODULE__{} = updater) do
    max_slope = max_global_slope(updater)
    stalled? = max_slope <= updater.burst_trigger_slope and updater.sampling_burst_steps == 0

    %{
      updater
      | max_slope: max_slope,
        sampling_burst_steps:
          if(stalled?, do: updater.burst_sampling_duration, else: updater.sampling_burst_steps)
    }
  end

  @doc "Count a burst step down once the step's update is done."
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec end_step(t()) :: t()
  def end_step(%__MODULE__{sampling_burst_steps: steps} = updater) when steps > 0,
    do: %{updater | sampling_burst_steps: steps - 1}

  def end_step(%__MODULE__{} = updater), do: updater

  @doc """
  Move every hypothesis by `displacement`, as its own orientation sees it.

  A no-op with no hypotheses or no movement — before the first step there is
  nothing to move by.
  """
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec displace_hypotheses(t(), Hypotheses.t(), [number()] | nil) :: Hypotheses.t()
  def displace_hypotheses(%__MODULE__{}, %Hypotheses{} = hypotheses, nil), do: hypotheses

  def displace_hypotheses(
        %__MODULE__{displacer: displacer},
        %Hypotheses{} = hypotheses,
        displacement
      ) do
    if Hypotheses.count(hypotheses) == 0 do
      hypotheses
    else
      HypothesesDisplacer.displace_hypotheses(displacer, hypotheses, displacement)
    end
  end

  @doc """
  Rebuild the hypothesis space for this observation and update its evidence.

  Returns `{updater, hypotheses, telemetry}`, with `hypotheses` and telemetry
  empty when the observation carries no channel this graph stores — the caller
  then has nothing to update rather than an empty space pretending to be one.
  """
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec update_evidence(
          t(),
          Hypotheses.t(),
          %{optional(String.t()) => map()},
          String.t(),
          float()
        ) ::
          {t(), Hypotheses.t() | nil, map()}
  def update_evidence(
        %__MODULE__{} = updater,
        hypotheses,
        features,
        graph_id,
        evidence_update_threshold
      ) do
    tracker = tracker_for(updater, graph_id)

    input_channels =
      Channels.all_usable_input_channels(
        features,
        GraphMemory.get_input_channels_in_graph(updater.graph_memory, graph_id)
      )

    if input_channels == [] do
      {updater, nil, %{}}
    else
      {selection, new_per_channel} =
        sample_count(updater, features, graph_id, input_channels, tracker)

      {existing, tracker} = sample_existing(selection, hypotheses, tracker)

      {new_hypotheses, tracker} =
        sample_new(updater, features, graph_id, new_per_channel, tracker)

      {existing, prediction_error} =
        evidence_for(existing, selection, updater, features, evidence_update_threshold, graph_id)

      combined = Hypotheses.concatenate([existing, new_hypotheses])

      {:ok, tracker} =
        EvidenceSlopeTracker.update(tracker, combined.evidence,
          num_channels: length(input_channels)
        )

      updater = put_in(updater.evidence_slope_trackers[graph_id], tracker)

      {updater, combined,
       telemetry(updater, combined, new_hypotheses, selection, tracker, prediction_error)}
    end
  end

  defp evidence_for(hypotheses, selection, updater, features, threshold, graph_id) do
    if HypothesesSelection.ids_to_retain(selection) == [] do
      {hypotheses, nil}
    else
      {updated, telemetry} =
        HypothesesDisplacer.compute_evidence(
          updater.displacer,
          features,
          threshold,
          graph_id,
          hypotheses
        )

      {updated, telemetry.mlh_prediction_error}
    end
  end

  defp telemetry(updater, combined, new_hypotheses, selection, tracker, prediction_error) do
    count = Hypotheses.count(combined)
    first_new = count - Hypotheses.count(new_hypotheses)

    %{
      mlh_prediction_error: prediction_error,
      added_ids: Enum.to_list(first_new..(count - 1)//1),
      ages: EvidenceSlopeTracker.hyp_ages(tracker),
      evidence_slopes: EvidenceSlopeTracker.calculate_slopes(tracker),
      removed_ids: HypothesesSelection.ids_to_remove(selection),
      max_slope: updater.max_slope
    }
  end

  # A well-defined pose has a mirror twin; an undefined one is sampled around
  # the normal; fixed poses are however many the experiment named.
  defp hyps_per_node(%__MODULE__{initial_possible_poses: nil} = updater, features) do
    if features["pose_fully_defined"], do: 2, else: updater.umbilical_num_poses
  end

  defp hyps_per_node(%__MODULE__{initial_possible_poses: poses}, _features), do: length(poses)

  defp sample_count(updater, features, graph_id, input_channels, tracker) do
    new_per_channel =
      if updater.sampling_burst_steps > 0 do
        Map.new(input_channels, fn channel ->
          num_nodes =
            length(GraphMemory.get_locations_in_graph(updater.graph_memory, graph_id, channel))

          per_node = hyps_per_node(updater, Map.fetch!(features, channel))
          wanted = round(num_nodes * min(updater.sampling_multiplier, per_node))

          # Whole rotations only: half a set of poses is not a hypothesis set.
          {channel, wanted - rem(wanted, per_node)}
        end)
      else
        %{}
      end

    selection =
      if EvidenceSlopeTracker.total_size(tracker) > 0 do
        EvidenceSlopeTracker.select_hypotheses(tracker, updater.deletion_trigger_slope)
      else
        HypothesesSelection.new([])
      end

    {selection, new_per_channel}
  end

  defp sample_existing(selection, hypotheses, tracker) do
    case HypothesesSelection.ids_to_retain(selection) do
      [] ->
        {Hypotheses.empty(), EvidenceSlopeTracker.clear_hyp(tracker)}

      ids ->
        {Hypotheses.take(hypotheses, ids),
         EvidenceSlopeTracker.remove_hyp(tracker, HypothesesSelection.ids_to_remove(selection))}
    end
  end

  defp sample_new(updater, features, graph_id, new_per_channel, tracker) do
    sampled =
      new_per_channel
      |> Enum.reject(fn {_channel, count} -> count == 0 end)
      |> Enum.map(fn {channel, count} ->
        sample_from_channel(updater, Map.fetch!(features, channel), count, graph_id, channel)
      end)

    case sampled do
      [] ->
        {Hypotheses.empty(), tracker}

      sampled ->
        hypotheses = Hypotheses.concatenate(sampled)
        {hypotheses, EvidenceSlopeTracker.add_hyp(tracker, Hypotheses.count(hypotheses))}
    end
  end

  defp sample_from_channel(updater, features, count, graph_id, input_channel) do
    per_node = hyps_per_node(updater, features)

    node_evidence =
      DefaultFeatureEvidenceScorer.evidence(updater.scorer, graph_id, input_channel, features)

    top_indices = top_indices(node_evidence, div(count, per_node))

    locations = GraphMemory.get_locations_in_graph(updater.graph_memory, graph_id, input_channel)
    selected_locations = Enum.map(top_indices, &Enum.at(locations, &1))
    selected_evidence = Enum.map(top_indices, &Enum.at(node_evidence, &1))

    rotations = rotations(updater, graph_id, input_channel, features, top_indices, per_node)

    # One hypothesis per (rotation, node), rotation-major: the order the
    # rotations were built in, so each location keeps the pose it was given.
    %Hypotheses{
      locations: selected_locations |> List.duplicate(per_node) |> Enum.concat(),
      poses: rotations,
      evidence:
        selected_evidence |> List.duplicate(per_node) |> Enum.concat() |> Enum.map(&(&1 * 1.0)),
      possible: List.duplicate(false, length(rotations))
    }
  end

  # The ids of the nodes whose evidence is highest, lowest first among the
  # chosen ones — `argsort` from the far end, as Monty takes them.
  defp top_indices(_node_evidence, 0), do: []

  defp top_indices(node_evidence, count) do
    node_evidence
    |> Enum.with_index()
    |> Enum.sort_by(fn {evidence, index} -> {evidence, index} end)
    |> Enum.take(-count)
    |> Enum.map(fn {_evidence, index} -> index end)
  end

  defp rotations(
         %__MODULE__{initial_possible_poses: nil} = updater,
         graph_id,
         input_channel,
         features,
         top_indices,
         per_node
       ) do
    node_directions =
      GraphMemory.get_rotation_features_at_all_nodes(
        updater.graph_memory,
        graph_id,
        input_channel
      )

    directions = Enum.map(top_indices, &Enum.at(node_directions, &1))

    features
    |> sensed_pose_vectors()
    |> GraphMatchingUtils.possible_sensed_directions(per_node)
    |> Enum.flat_map(fn sensed ->
      directions
      |> then(&SpatialArithmetics.align_multiple_orthonormal_vectors(&1, sensed))
      |> Enum.map(&Rotation.to_matrix/1)
    end)
  end

  defp rotations(
         %__MODULE__{initial_possible_poses: poses},
         _graph_id,
         _input_channel,
         _features,
         top_indices,
         _per_node
       ) do
    Enum.flat_map(poses, fn pose -> List.duplicate(pose, length(top_indices)) end)
  end

  defp sensed_pose_vectors(features) do
    features
    |> Map.fetch!("pose_vectors")
    |> Enum.chunk_every(3)
    |> then(fn [normal, curvature_1, curvature_2] ->
      SurfacePoseVectors.new(normal, curvature_1, curvature_2)
    end)
  end

  defp tracker_for(updater, graph_id) do
    Map.get_lazy(updater.evidence_slope_trackers, graph_id, fn -> EvidenceSlopeTracker.new() end)
  end

  defp max_global_slope(updater) do
    updater.evidence_slope_trackers
    |> Map.values()
    |> Enum.flat_map(&EvidenceSlopeTracker.calculate_slopes/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0.0
      slopes -> Enum.max(slopes)
    end
  end
end
