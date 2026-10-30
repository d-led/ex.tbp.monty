# Timing for replaying a recorded Monty episode against Monty's pretrained
# memory: the workload the parity tests run, measured so a slowdown is noticed
# before it is felt.
#
#     MIX_ENV=test mix run scripts/bench_replay.exs
#
# It reports the whole episode, and then the matching step that took longest —
# the steps whose hypothesis space has doubled twice are the ones worth looking
# at when the total moves.
#
# Recorded 2026-10-28, Apple M-series, Elixir 1.20.4 / OTP 29:
#
#     episode            ~5.0 s  for 21 matching steps (110 recorded rows)
#     heaviest step      ~5 ms
#     full replay        ~21 s  when the parity test drives every step
#
# The trajectory that got here, all with identical numbers: about 3m30s with a
# nearest-neighbour scan answering in time linear in the node count, 13.7s once
# the trees were kept with their graph instead of rebuilt per step, and ~5s once
# the query pruned properly and two quadratic list walks in hypothesis selection
# were removed.

alias Monty.Context
alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Test.MontyRecording

pretrained = "priv/monty/libraries/pretrained_ycb_v10/surf_agent_1lm_10distinctobj.jsonl.gz"
recording = "test/fixtures/monty_pretrained_episode.jsonl"

tolerances = %{"patch" => %{"hsv" => [0.1, 0.2, 0.2], "principal_curvatures_log" => [1.0, 1.0]}}

feature_weights = %{
  "patch" => %{
    "hsv" => [2.0, 0.5, 0.5],
    "pose_vectors" => [1.0, 1.0, 1.0],
    "principal_curvatures_log" => [1.0, 1.0]
  }
}

{:ok, lm} =
  EvidenceGraphLM.new(MontyRecording.load_pretrained!(pretrained),
    max_match_distance: 0.01,
    max_nneighbors: 5,
    hypotheses_updater: BurstSamplingHypothesesUpdater,
    tolerances: tolerances,
    feature_weights: feature_weights,
    x_percent_threshold: 20,
    evidence_threshold_config: "all"
  )

steps = MontyRecording.load!(recording) |> Enum.reject(&(&1 == []))

{total_us, {lm, timings}} =
  :timer.tc(fn ->
    Enum.reduce(steps, {lm, []}, fn percepts, {lm, timings} ->
      {us, {:ok, lm}} = :timer.tc(fn -> EvidenceGraphLM.matching_step(percepts, Context.new(0), lm) end)
      {lm, [us | timings]}
    end)
  end)

_ = lm
timings = Enum.reverse(timings)
sorted = Enum.sort(timings)
median = Enum.at(sorted, div(length(sorted), 2))
per_step = Float.round(total_us / length(steps) / 1000, 1)

IO.puts("episode #{Float.round(total_us / 1000, 1)}ms for #{length(steps)} matching steps (#{per_step}ms per step)")
IO.puts("heaviest step #{Float.round(Enum.max(timings) / 1000, 1)}ms, median #{Float.round(median / 1000, 1)}ms")
