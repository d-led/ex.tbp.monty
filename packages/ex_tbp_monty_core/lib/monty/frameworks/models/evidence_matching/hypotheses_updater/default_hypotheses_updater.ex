defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater do
  @moduledoc """
  The straightforward updater: accumulate evidence, start channels, displace.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/hypotheses_updater.py::DefaultHypothesesUpdater`,
  the updater Monty pairs with the plain displacer — no bursting. Every step it
  brings any channel that has just started reporting into the hypothesis space,
  then adds this observation's evidence to the hypotheses already there.

  ## Starting hypotheses

  Two ways, chosen by whether the experiment seeds poses:

    * **informed** — each node's stored pose is aligned with what the sensor
      sees, once per direction the sensed pose allows. This is how Monty
      recognises an object turned any way: the alignment tells it which rotation
      would explain the observation.
    * **fixed** — every node is tried with each configured rotation, which is
      what a `uniform` experiment means.

  All of them start with the evidence the first observation already gives them:
  the feature evidence of the node they sit on. Nothing has been ruled out yet —
  every node is a hypothesis — but a node whose colour and curvature look like
  what the sensor just saw starts ahead of one that does not, which is what
  Monty's first hypothesis space is worth.

  ## A channel that joins late

  A sensor can start reporting after another channel has already accumulated
  evidence. Its hypotheses enter with the *mean* of the evidence already there,
  so a newcomer is not silently out of the running against hypotheses that have
  had several steps to climb.
  """

  @behaviour Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater

  alias ExTbpMonty.Core.MatcherNif
  alias Monty.Frameworks.Models.EvidenceMatching.Channels

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.PoseKind
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.{OrientationMatrix, SurfacePoseVectors}

  defstruct graph_memory: nil,
            displacer: nil,
            scorer: nil,
            initial_possible_poses: nil,
            umbilical_num_poses: 8,
            initialised_channels: %{}

  @type t :: %__MODULE__{}

  @doc """
  An updater over `memory`.

  `:initial_possible_poses` is `:first_observation` for informed sampling, or a
  list of 3×3 pose matrices for fixed poses.
  """
  @spec new(GraphMemory.t(), keyword()) :: t()
  def new(%GraphMemory{} = memory, options) do
    %__MODULE__{
      graph_memory: memory,
      displacer: Keyword.fetch!(options, :displacer),
      scorer: Keyword.fetch!(options, :scorer),
      initial_possible_poses: Keyword.get(options, :initial_possible_poses, :first_observation),
      umbilical_num_poses: Keyword.get(options, :umbilical_num_poses, 8)
    }
  end

  @doc "Forget which channels this episode has started."
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = updater), do: %{updater | initialised_channels: %{}}

  @doc """
  This updater as one object of the memory it was built over.

  What a round of per-object updates hands a task: the library narrowed to the
  object the task updates (`GraphMemory.narrow/2`), the displacer and the scorer
  narrowed with it, and that object's `initialised_channels` alone.
  """
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec narrow(t(), GraphMemory.graph_id()) :: t()
  def narrow(%__MODULE__{} = updater, graph_id) do
    %{
      updater
      | graph_memory: GraphMemory.narrow(updater.graph_memory, graph_id),
        displacer: HypothesesDisplacer.narrow(updater.displacer, graph_id),
        scorer: DefaultFeatureEvidenceScorer.narrow(updater.scorer, graph_id),
        initialised_channels: Map.take(updater.initialised_channels, [graph_id])
    }
  end

  @doc """
  Nothing to prepare: this updater keeps every hypothesis it has and spends no
  step sampling new ones, so each step looks like every other.
  """
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec begin_step(t()) :: t()
  def begin_step(%__MODULE__{} = updater), do: updater

  @doc "Nothing to wind down, for the same reason `begin_step/1` has nothing to set up."
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec end_step(t()) :: t()
  def end_step(%__MODULE__{} = updater), do: updater

  @doc """
  Two halves of one step, each having updated different graphs.

  The only state a graph's update touches is which of its channels this episode
  has started, and a graph belongs to one half, so the union is the whole step.
  """
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec merge_step(t(), t(), t()) :: t()
  def merge_step(%__MODULE__{} = base, %__MODULE__{} = left, %__MODULE__{} = right),
    do: %{
      left
      | initialised_channels:
          HypothesesUpdater.merge_changed(
            base.initialised_channels,
            left.initialised_channels,
            right.initialised_channels
          )
    }

  @doc """
  Move every hypothesis by `displacement`, as its own orientation sees it.
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
  Bring the hypothesis space up to date with this observation.

  Starts the space on the first step, adds a channel that has just begun
  reporting, and otherwise adds the observation's evidence to what is there.
  Returns `nil` and no telemetry when no stored channel was observed.
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
    input_channels =
      Channels.all_usable_input_channels(
        features,
        GraphMemory.get_input_channels_in_graph(updater.graph_memory, graph_id)
      )

    case input_channels do
      [] ->
        {updater, nil, %{}}

      input_channels ->
        updater = initialise_graph(updater, graph_id)

        if Hypotheses.count(hypotheses) == 0 do
          start_hypotheses(updater, features, graph_id, input_channels)
        else
          add_evidence(
            updater,
            hypotheses,
            features,
            graph_id,
            input_channels,
            evidence_update_threshold
          )
        end
    end
  end

  defp start_hypotheses(updater, features, graph_id, input_channels) do
    hypotheses =
      input_channels
      |> Enum.map(&get_initial_hypothesis_space(updater, Map.fetch!(features, &1), graph_id, &1))
      |> Hypotheses.concatenate()

    updater = Enum.reduce(input_channels, updater, &mark_initialised(&2, graph_id, &1))

    {updater, hypotheses, %{}}
  end

  defp add_evidence(updater, hypotheses, features, graph_id, input_channels, threshold) do
    {updated, telemetry} =
      HypothesesDisplacer.compute_evidence(
        updater.displacer,
        features,
        threshold,
        graph_id,
        hypotheses
      )

    new_channels = Enum.reject(input_channels, &initialised?(updater, graph_id, &1))

    {updater, updated} =
      initialize_new_channels(updater, updated, features, new_channels, graph_id)

    {updater, updated, %{mlh_prediction_error: telemetry.mlh_prediction_error}}
  end

  # Monty's `_initialize_new_channels`: a channel that starts reporting after the
  # others have already accumulated evidence. Its hypotheses are lifted to the
  # mean the rest have reached, so a newcomer is not beaten before its second
  # observation.
  defp initialize_new_channels(updater, hypotheses, features, new_channels, graph_id) do
    Enum.reduce(new_channels, {updater, hypotheses}, fn channel, {updater, so_far} ->
      channel_hypotheses =
        get_initial_hypothesis_space(updater, Map.fetch!(features, channel), graph_id, channel)

      lifted =
        Hypotheses.put_evidence(
          channel_hypotheses,
          Enum.map(Hypotheses.evidence(channel_hypotheses), &(&1 + mean_evidence(so_far)))
        )

      {mark_initialised(updater, graph_id, channel), Hypotheses.concatenate([so_far, lifted])}
    end)
  end

  # Monty's `_get_initial_hypothesis_space`: the hypotheses a channel starts
  # with — from its pose features, or from the fixed poses the config names.
  defp get_initial_hypothesis_space(
         %__MODULE__{initial_possible_poses: :first_observation} = updater,
         channel_features,
         graph_id,
         input_channel
       ) do
    {locations, rotations} =
      get_all_informed_possible_poses(updater, graph_id, channel_features, input_channel)

    all_hypotheses(
      locations,
      rotations,
      node_feature_evidence(updater, graph_id, input_channel, channel_features)
    )
  end

  defp get_initial_hypothesis_space(
         %__MODULE__{initial_possible_poses: poses} = updater,
         channel_features,
         graph_id,
         input_channel
       ) do
    locations = GraphMemory.get_locations_in_graph(updater.graph_memory, graph_id, input_channel)
    rotations = Enum.flat_map(poses, fn pose -> List.duplicate(pose, length(locations)) end)

    all_hypotheses(
      locations,
      rotations,
      node_feature_evidence(updater, graph_id, input_channel, channel_features)
    )
  end

  # Monty's `_get_all_informed_possible_poses`: how a stored frame has to be
  # turned to line up with a sensed one, for every node and every sensed
  # direction.
  defp get_all_informed_possible_poses(updater, graph_id, sensed_channel_features, input_channel) do
    node_directions =
      GraphMemory.get_rotation_features_at_all_nodes(
        updater.graph_memory,
        graph_id,
        input_channel
      )

    locations = GraphMemory.get_locations_in_graph(updater.graph_memory, graph_id, input_channel)

    rotations =
      informed_rotations(updater, node_directions, sensed_channel_features)

    {locations, rotations}
  end

  # Monty's `_get_all_informed_possible_poses` dispatch. A surface pose vector
  # allows one rotation per possible sensed direction — two when the pose is
  # fully defined, `umbilical_num_poses` when it is not. An orientation matrix is
  # already a frame, so it is aligned against every stored one as it stands. And
  # anything else is a type the updater cannot use: Monty raises a `TypeError`
  # naming it, and a struct-based port names it in an `ArgumentError`.
  #
  # How many directions a surface pose allows is asked for only in the branch that
  # uses it, as Monty asks: an orientation matrix carries no `pose_fully_defined`
  # flag to read.
  defp informed_rotations(updater, node_directions, sensed_channel_features) do
    case pose_vectors(sensed_channel_features) do
      %OrientationMatrix{value: matrix} ->
        SpatialArithmetics.align_multiple_orthonormal_vectors_as_matrices(
          node_directions,
          matrix
        )

      %SurfacePoseVectors{} = vectors ->
        vectors
        |> GraphMatchingUtils.possible_sensed_directions(
          per_node(updater, sensed_channel_features)
        )
        |> Enum.flat_map(fn sensed ->
          # Matrices, not rotations: a stored frame is only nearly orthonormal and
          # Monty keeps that — see `align_multiple_orthonormal_vectors_as_matrices/2`.
          SpatialArithmetics.align_multiple_orthonormal_vectors_as_matrices(
            node_directions,
            sensed
          )
        end)

      unsupported ->
        raise ArgumentError, "Unsupported pose_vector type: #{inspect(unsupported)}"
    end
  end

  # What the first observation already says about each node: hypotheses start
  # where the features put them, not at zero. This updater builds one hypothesis
  # per node, so it is the one caller that needs a value each — the column
  # arrives as bytes.
  defp node_feature_evidence(updater, graph_id, input_channel, features) do
    updater.scorer
    |> DefaultFeatureEvidenceScorer.evidence(graph_id, input_channel, features)
    |> as_values()
  end

  defp as_values(column) when is_binary(column), do: MatcherNif.decode(column)
  defp as_values(column), do: column

  # One location and one evidence value per rotation, in the order the rotations
  # were built: all nodes for the first direction, then all nodes for the
  # second, and so on.
  defp all_hypotheses(locations, rotations, node_evidence) do
    repeats = div(length(rotations), length(locations))

    Hypotheses.new(
      locations: locations |> List.duplicate(repeats) |> Enum.concat(),
      poses: rotations,
      evidence: node_evidence |> List.duplicate(repeats) |> Enum.concat(),
      possible: List.duplicate(true, length(rotations))
    )
  end

  # The channel's `pose_vectors`: the nine numbers Monty's features carry, or the
  # struct a synthetic learning module builds. Both are what the dispatch reads —
  # the numbers because the type travels beside them.
  defp pose_vectors(features) do
    case Map.fetch!(features, "pose_vectors") do
      %module{} = vectors when module in [SurfacePoseVectors, OrientationMatrix] ->
        vectors

      value when is_list(value) ->
        PoseKind.vectors(PoseKind.of(features), value)

      value ->
        value
    end
  end

  # A well-defined pose has a mirror twin; an undefined one is sampled around
  # the normal.
  defp per_node(updater, features) do
    if features["pose_fully_defined"], do: 2, else: updater.umbilical_num_poses
  end

  defp mean_evidence(hypotheses) do
    case Hypotheses.evidence(hypotheses) do
      [] -> 0.0
      evidence -> Enum.sum(evidence) / length(evidence)
    end
  end

  defp initialise_graph(updater, graph_id) do
    if Map.has_key?(updater.initialised_channels, graph_id) do
      updater
    else
      put_in(updater.initialised_channels[graph_id], MapSet.new())
    end
  end

  defp mark_initialised(updater, graph_id, channel) do
    update_in(updater.initialised_channels[graph_id], &MapSet.put(&1, channel))
  end

  defp initialised?(updater, graph_id, channel) do
    updater.initialised_channels |> Map.get(graph_id, MapSet.new()) |> MapSet.member?(channel)
  end
end
