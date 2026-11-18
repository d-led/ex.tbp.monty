# How much of one matching step is per object, and how much is fixed?
#
#   MIX_ENV=test mix run --no-start scripts/probe_lm_graph_split.exs
#
# `EvidenceGraphLM.update_possible_matches/2` folds over every object in the
# memory, so "run the objects in parallel" is only worth anything if that fold
# dominates the call. This measures the two halves the same way: one
# `compute_possible_matches/3` over the whole memory, then the same call over a
# memory cut to a single object. The difference is the per-object cost of the
# objects that were removed; what is left of the single call is the fixed cost
# (the percept's features, the band threshold, the most-likely calculation).
#
# Reductions, not wall clock: this box's clock is not evidence while anything
# else runs. `moved?` is false, so no displacement is asked of a buffer that has
# not seen a step yet — the fold is the same shape either way.

alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_pretrained_episode.jsonl"

memory_path =
  Path.join([
    Monty.Studio.Memory.libraries_dir(),
    "pretrained_ycb_v10/surf_agent_1lm_10distinctobj.jsonl.gz"
  ])

unless File.regular?(memory_path) do
  IO.puts("no memory at #{memory_path} — fetch it with `mix monty.prerequisites.fetch`")

  System.halt(1)
end

percept =
  recording
  |> MontyRecording.load!()
  |> Enum.find_value(fn
    [] -> nil
    [percept | _rest] -> percept
  end)

unless percept do
  IO.puts("no percept in #{recording}")

  System.halt(1)
end

defmodule Probe do
  @doc "The work `fun` did, in reductions, and its answer."
  def reductions(fun) do
    {before, _} = :erlang.statistics(:reductions)
    answer = fun.()
    {afterwards, _} = :erlang.statistics(:reductions)
    {afterwards - before, answer}
  end

  @doc "One matching step over `memory`, with `percept` as the whole observation."
  def step(memory, percept) do
    {:ok, lm} =
      EvidenceGraphLM.new(memory,
        max_match_distance: 0.01,
        max_nneighbors: 5,
        hypotheses_updater: BurstSamplingHypothesesUpdater,
        tolerances: %{
          "patch" => %{"hsv" => [0.1, 0.2, 0.2], "principal_curvatures_log" => [1.0, 1.0]}
        },
        feature_weights: %{
          "patch" => %{
            "hsv" => [2.0, 0.5, 0.5],
            "pose_vectors" => [1.0, 1.0, 1.0],
            "principal_curvatures_log" => [1.0, 1.0]
          }
        },
        x_percent_threshold: 20,
        evidence_threshold_config: "all"
      )

    reductions(fn -> EvidenceGraphLM.compute_possible_matches(lm, [percept], false) end)
  end
end

memory = MontyRecording.load_pretrained!(memory_path)
graphs = Map.keys(memory.models_in_memory) |> Enum.sort()
first = hd(graphs)

{whole, _} = Probe.step(memory, percept)

# Every object on its own, so the average is not one object's price: a memory's
# graphs differ in size by an order of magnitude, and the fold pays each one's.
per =
  Map.new(graphs, fn id ->
    {one, _} =
      Probe.step(%{memory | models_in_memory: Map.take(memory.models_in_memory, [id])}, percept)

    {id, one}
  end)

{one, _} =
  Probe.step(%{memory | models_in_memory: Map.take(memory.models_in_memory, [first])}, percept)

IO.puts("memory:             #{length(graphs)} objects, #{inspect(Path.basename(memory_path))}")
IO.puts("whole memory:       #{whole} reductions")

IO.puts(
  "per object alone:   #{inspect(Enum.sort_by(per, &elem(&1, 1)) |> Enum.map(fn {id, cost} -> {id, cost} end))}"
)

IO.puts(
  "fixed (one object): #{one} reductions, #{Float.round(100 * one / whole, 1)} % of the whole"
)

IO.puts("per-object share:   #{Float.round(100 * (whole - one) / whole, 1)} % of the whole")

IO.puts(
  "sum of the objects: #{Enum.sum(Map.values(per))} reductions (what a parallel pass would divide)"
)

# An upper bound on what a per-object pass could buy, measured rather than
# argued: the same ten calls one after another, then the same ten handed to
# `async_stream`. Each task builds its own module — the copies a real change
# would have to arrange more cheaply — so this is the arithmetic divided by the
# scheduler count with coordination on top, and none of the serial 30 %.
each = fn id ->
  memory = %{memory | models_in_memory: Map.take(memory.models_in_memory, [id])}
  Probe.step(memory, percept)
end

concurrency = System.schedulers_online()

{serial_us, _} = :timer.tc(fn -> Enum.each(graphs, each) end)

{parallel_us, _} =
  :timer.tc(fn ->
    graphs
    |> Task.async_stream(each, max_concurrency: concurrency, timeout: :infinity, ordered: false)
    |> Stream.run()
  end)

IO.puts("serial, ten calls:  #{div(serial_us, 1000)} ms")

IO.puts(
  "async_stream (#{concurrency}): #{div(parallel_us, 1000)} ms — #{Float.round(serial_us / max(parallel_us, 1), 2)}x"
)
