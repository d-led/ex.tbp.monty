defmodule Monty.Frameworks.Models.Mixins.NoResetEvidence.TheoreticalLimitLMLoggingMixin do
  @moduledoc """
  What a learning module's hypotheses were worth, in the terms a paper uses.

  Mirrors `frameworks/models/mixins/no_reset_evidence.py::TheoreticalLimitLMLoggingMixin`,
  the mixin Monty's unsupervised-inference learning module is built from. It
  adds four things to a step's log, none of which the module needs in order to
  recognise anything — they exist so an episode can be judged as well as read:

    * `"max_evidence"` — the strongest hypothesis of every object;
    * `"target_object_theoretical_limit"` — the pose error of the *best*
      hypothesis of the target object, i.e. how right Monty could have been if
      it had picked the best one instead of the most likely one;
    * `"target_object_pose_error"` — the pose error of the most likely
      hypothesis, which is the error the episode is actually charged with;
    * `"hypotheses_updater_telemetry"` — per object, the whole hypothesis space
      (`Monty.Frameworks.Models.Mixins.NoResetEvidence.HypothesesUpdaterGraphTelemetry`).

  ## The gap between the two pose errors is the finding

  The theoretical limit is an oracle's score and the MLH's error is Monty's.
  When they diverge, the hypotheses are fine and the choice among them is not —
  which is a different repair from "the model never had a good explanation".
  That is why the mixin computes both rather than one.

  ## Differences from Monty, on purpose

    * **No inheritance, so no `__init_subclass__` guard.** Monty refuses at class
      definition time to mix this into anything but an `EvidenceGraphLM`; here
      the guard is the argument's type, and `add_detailed_stats/2` has no clause
      for anything else.
    * **Monty's mixin replaces the learning module's own detailed statistics**
      rather than adding to them: its `_add_detailed_stats` does not call
      `super()`, so `possible_locations`, `evidences`, `possible_rotations` and
      `symmetry_evidence` are absent from the log of the learning module that
      mixes it in. That is Monty's behaviour, kept.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.Mixins.NoResetEvidence.HypothesesUpdaterGraphTelemetry
  alias Monty.Frameworks.Utils.LoggingUtils
  alias Monty.Geometry.Rotation

  @doc """
  `_add_detailed_stats`: the step's statistics, with this mixin's four added.

  Takes the statistics the learning module would have written and returns them
  with the mixin's fields in place — replacing that module's own detailed
  fields, which is what Monty's mixin does.
  """
  @spec add_detailed_stats(EvidenceGraphLM.t(), map()) :: map()
  def add_detailed_stats(%EvidenceGraphLM{} = lm, stats) do
    stats
    |> Map.put("max_evidence", max_evidence(lm))
    |> Map.put("target_object_theoretical_limit", theoretical_limit(lm))
    |> Map.put("target_object_pose_error", mlh_pose_error(lm))
    |> put_telemetry(lm)
  end

  # The strongest hypothesis of every object, and only the objects that have any:
  # an object the module never considered has nothing to be strong about.
  defp max_evidence(%EvidenceGraphLM{hypotheses: hypotheses}) do
    for {graph_id, held} <- hypotheses,
        evidence = Hypotheses.evidence(held),
        evidence != [],
        into: %{} do
      {graph_id, Enum.max(evidence)}
    end
  end

  # The best rotation any hypothesis of the target object reaches, in radians —
  # Monty's `-1` when the epoch measured, which is the epoch's way of saying
  # "nothing to measure" rather than "no error".
  defp theoretical_limit(%EvidenceGraphLM{primary_target: target} = lm) do
    with %Hypotheses{} = held <- Map.get(lm.hypotheses, target),
         [_ | _] = poses <- Hypotheses.poses(held),
         {:ok, target_rotation} <- target_rotation(lm) do
      poses
      |> Enum.map(&inverted_rotation/1)
      |> LoggingUtils.compute_pose_error(target_rotation)
    else
      _nothing_to_measure -> -1
    end
  end

  # The error of the hypothesis the module actually believes, which is what the
  # episode is scored on.
  defp mlh_pose_error(%EvidenceGraphLM{} = lm) do
    with {:ok, target_rotation} <- target_rotation(lm),
         %{rotation: rotation} <- believed(lm) do
      LoggingUtils.compute_pose_error(Rotation.invert(rotation), target_rotation)
    else
      _nothing_to_measure -> -1
    end
  end

  # A module whose target is not in memory has no hypothesis about it; Monty
  # raises a `KeyError` here, and a log entry is not worth ending an episode over.
  defp believed(%EvidenceGraphLM{primary_target: target} = lm) do
    if Map.has_key?(lm.hypotheses, target), do: EvidenceGraphLM.get_mlh_for_object(lm, target)
  end

  defp put_telemetry(stats, %EvidenceGraphLM{} = lm) do
    case telemetry(lm) do
      telemetry when telemetry == %{} -> stats
      telemetry -> Map.put(stats, "hypotheses_updater_telemetry", telemetry)
    end
  end

  defp telemetry(%EvidenceGraphLM{} = lm) do
    Map.new(lm.hypotheses_updater_telemetry, fn {graph_id, graph_telemetry} ->
      {graph_id, graph_telemetry(lm, graph_id, graph_telemetry)}
    end)
  end

  # One graph's hypotheses, as the updater left them. A graph with no hypotheses
  # still gets a row — an empty one, which is what Monty writes.
  defp graph_telemetry(%EvidenceGraphLM{} = lm, graph_id, graph_telemetry) do
    case Map.get(lm.hypotheses, graph_id) do
      nil ->
        HypothesesUpdaterGraphTelemetry.empty(graph_telemetry)

      %Hypotheses{} = held ->
        telemetry_of(lm, held, graph_telemetry)
    end
  end

  defp telemetry_of(%EvidenceGraphLM{} = lm, held, graph_telemetry) do
    poses = Hypotheses.poses(held)

    if poses == [] do
      HypothesesUpdaterGraphTelemetry.empty(graph_telemetry)
    else
      rotations = Enum.map(poses, &inverted_rotation/1)

      %HypothesesUpdaterGraphTelemetry{
        hypotheses_updater: graph_telemetry,
        evidence: Hypotheses.evidence(held),
        rotations: Enum.map(rotations, &euler_degrees/1),
        locations: Hypotheses.locations(held),
        pose_errors: pose_errors(rotations, lm)
      }
    end
  end

  # Monty's `compute_pose_errors(rotations_inv, target)`. A run whose world named
  # no target pose has no error to measure, and says so with no numbers rather
  # than with zeroes that would read as perfect.
  defp pose_errors(rotations, lm) do
    case target_rotation(lm) do
      {:ok, target_rotation} -> LoggingUtils.compute_pose_errors(rotations, target_rotation)
      {:error, _reason} -> []
    end
  end

  # A hypothesis' pose is the rotation of its matrix, inverted — Monty's
  # `Rotation.from_matrix(poses).inv()`, which is the sense a pose error is
  # measured in.
  defp inverted_rotation(matrix) do
    {:ok, rotation} = Rotation.from_matrix(matrix)
    Rotation.invert(rotation)
  end

  # `as_euler("xyz", degrees: true)`, unrounded: a log is compared, not shown.
  defp euler_degrees(rotation),
    do: rotation |> Rotation.to_euler_radians() |> Enum.map(&to_degrees/1)

  defp to_degrees(radians), do: radians * 180 / :math.pi()

  # The rotation the interface placed the target object with. Monty keeps it as
  # a scalar-first quaternion array (`Rotation.as_quat/0`); here it travels as a
  # list, because that is what JSON carries.
  defp target_rotation(%EvidenceGraphLM{primary_target_rotation_quat: quat}) when is_list(quat) do
    Rotation.from_quaternion(List.to_tuple(quat))
  end

  defp target_rotation(%EvidenceGraphLM{primary_target_rotation_quat: quat})
       when is_tuple(quat) do
    Rotation.from_quaternion(quat)
  end

  defp target_rotation(%EvidenceGraphLM{}), do: {:error, :no_target_rotation}
end
