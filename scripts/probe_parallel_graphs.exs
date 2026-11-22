# Which part of a step's answer differs between the per-graph round and the loop.
#
# Not a gate: a probe for `evidence_graph_lm_parallel_test.exs`, whose walk of
# both paths is the check. Run it with
# `MIX_ENV=test mix run --no-start scripts/probe_parallel_graphs.exs` when that
# case fails and the maps are too large to read in a test report.

alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
alias Monty.Frameworks.Models.EvidenceMatching.GraphMemory.EvidenceGraphMemory
alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Frameworks.Models.GraphMatching.GraphMemory
alias Monty.Geometry.Rotation
alias Monty.Test.Messages

channel = "patch"
pose = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
locations = [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.01, 0.01, 0.0]]
curvature = %{"mug" => [0.0, 0.5], "bowl" => [1.0, 1.5]}

memory =
  curvature
  |> Enum.reduce(EvidenceGraphMemory.new(max_graph_size: 0.3), fn {object, curv}, memory ->
    GraphMemory.update_memory(
      memory,
      locations,
      %{
        channel => %{
          "principal_curvatures_log" => List.duplicate(curv, length(locations)),
          "pose_vectors" => List.duplicate(pose, length(locations)),
          "pose_fully_defined" => List.duplicate(true, length(locations))
        }
      },
      object,
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0],
      Rotation.identity()
    )
  end)

module = fn parallel? ->
  {:ok, lm} =
    EvidenceGraphLM.new(memory,
      max_match_distance: 0.01,
      tolerances: %{channel => %{"principal_curvatures_log" => [1.0, 1.0]}},
      hypotheses_updater: BurstSamplingHypothesesUpdater,
      use_multithreading: parallel?,
      # The fixture's memory is tiny, so it can be held by a task whatever it is;
      # the flag stands for the studio's cached library.
      memory_shared?: true
    )

  lm
end

percepts =
  for {curv, nodes} <- Enum.zip([curvature["mug"], curvature["bowl"]], [locations, locations]),
      location <- nodes do
    Messages.percept(%{
      location: location,
      sender_id: channel,
      non_morphological_features: %{"principal_curvatures_log" => curv}
    })
  end

{round, loop} =
  Enum.reduce(Enum.with_index(percepts), {module.(true), module.(false)}, fn {percept, index},
                                                                           {round, loop} ->
    round = EvidenceGraphLM.compute_possible_matches(round, [percept], false)
    loop = EvidenceGraphLM.compute_possible_matches(loop, [percept], false)

    for key <- [:hypotheses, :possible_matches, :current_mlh, :hypotheses_updater_telemetry, :hypotheses_updater],
        Map.fetch!(round, key) != Map.fetch!(loop, key) do
      IO.puts("step #{index}: #{key} DIFFERS")
    end

    for graph_id <- Enum.sort(Map.keys(round.hypotheses)) do
      left = Map.fetch!(round.hypotheses, graph_id)
      right = Map.fetch!(loop.hypotheses, graph_id)

      if left != right do
        IO.puts("step #{index}: #{graph_id} left  #{inspect(Enum.take(Hypotheses.evidence(left), 6))}")
        IO.puts("step #{index}: #{graph_id} right #{inspect(Enum.take(Hypotheses.evidence(right), 6))}")
      end
    end

    {module_left, left} = round.hypotheses_updater
    {_module_right, right} = loop.hypotheses_updater

    if left != right do
      IO.puts("step #{index}: updater differs (#{inspect(module_left)})")

      for {key, value} <- Map.from_struct(left),
          Map.get(Map.from_struct(right), key) != value do
        IO.puts("  #{key} DIFFERS")
        show = fn term -> if is_map(term) or is_list(term), do: Map.keys(term), else: term end

        IO.puts("    left:  #{inspect(show.(value), limit: 20)}")
        IO.puts("    right: #{inspect(show.(Map.get(Map.from_struct(right), key)), limit: 20)}")
      end
    end

    {round, loop}
  end)

IO.puts("possible: #{inspect(round.possible_matches)} vs #{inspect(loop.possible_matches)}")
IO.puts("done")
