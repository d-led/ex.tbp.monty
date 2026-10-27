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

  All of them start with evidence zero and `possible?: true`: nothing has been
  ruled out yet, and the first observation decides.

  ## A channel that joins late

  A sensor can start reporting after another channel has already accumulated
  evidence. Its hypotheses enter with the *mean* of the evidence already there,
  so a newcomer is not silently out of the running against hypotheses that have
  had several steps to climb.
  """

  @behaviour Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater

  alias Monty.Frameworks.Models.EvidenceMatching.Channels
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Utils.GraphMatchingUtils
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors

  defstruct graph_memory: nil,
            displacer: nil,
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
      initial_possible_poses: Keyword.get(options, :initial_possible_poses, :first_observation),
      umbilical_num_poses: Keyword.get(options, :umbilical_num_poses, 8)
    }
  end

  @doc "Forget which channels this episode has started."
  @impl Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = updater), do: %{updater | initialised_channels: %{}}

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
      |> Enum.map(&initial_hypotheses(updater, Map.fetch!(features, &1), graph_id, &1))
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
      Enum.reduce(new_channels, {updater, updated}, fn channel, {updater, updated} ->
        hypotheses = initial_hypotheses(updater, Map.fetch!(features, channel), graph_id, channel)

        # A newcomer starts where the others already are, so it is not beaten
        # before its second observation.
        lifted = %Hypotheses{
          hypotheses
          | evidence: Enum.map(hypotheses.evidence, &(&1 + mean_evidence(updated)))
        }

        {mark_initialised(updater, graph_id, channel), Hypotheses.concatenate([updated, lifted])}
      end)

    {updater, updated, %{mlh_prediction_error: telemetry.mlh_prediction_error}}
  end

  defp initial_hypotheses(
         %__MODULE__{initial_possible_poses: :first_observation} = updater,
         features,
         graph_id,
         input_channel
       ) do
    locations = GraphMemory.get_locations_in_graph(updater.graph_memory, graph_id, input_channel)

    node_directions =
      GraphMemory.get_rotation_features_at_all_nodes(
        updater.graph_memory,
        graph_id,
        input_channel
      )

    rotations =
      features
      |> sensed_pose_vectors()
      |> GraphMatchingUtils.possible_sensed_directions(per_node(updater, features))
      |> Enum.flat_map(fn sensed ->
        node_directions
        |> SpatialArithmetics.align_multiple_orthonormal_vectors(sensed)
        |> Enum.map(&Rotation.to_matrix/1)
      end)

    all_hypotheses(locations, rotations)
  end

  defp initial_hypotheses(
         %__MODULE__{initial_possible_poses: poses} = updater,
         _features,
         graph_id,
         input_channel
       ) do
    locations = GraphMemory.get_locations_in_graph(updater.graph_memory, graph_id, input_channel)
    rotations = Enum.flat_map(poses, fn pose -> List.duplicate(pose, length(locations)) end)

    all_hypotheses(locations, rotations)
  end

  # One location per rotation, in the order the rotations were built: all nodes
  # for the first direction, then all nodes for the second, and so on.
  defp all_hypotheses(locations, rotations) do
    repeats = div(length(rotations), length(locations))

    %Hypotheses{
      locations: locations |> List.duplicate(repeats) |> Enum.concat(),
      poses: rotations,
      evidence: List.duplicate(0.0, length(rotations)),
      possible: List.duplicate(true, length(rotations))
    }
  end

  defp sensed_pose_vectors(features) do
    features
    |> Map.fetch!("pose_vectors")
    |> Enum.chunk_every(3)
    |> then(fn [normal, curvature_1, curvature_2] ->
      SurfacePoseVectors.new(normal, curvature_1, curvature_2)
    end)
  end

  # A well-defined pose has a mirror twin; an undefined one is sampled around
  # the normal.
  defp per_node(updater, features) do
    if features["pose_fully_defined"], do: 2, else: updater.umbilical_num_poses
  end

  defp mean_evidence(hypotheses) do
    case hypotheses.evidence do
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
