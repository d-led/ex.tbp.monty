# How much of a matching step is nearest-neighbour searching.
#
# The question this answers is whether replacing our kd-tree with something
# faster — a Rust NIF, a tensorised brute-force search, a database index — is
# worth what it costs. That depends entirely on the share of the step the search
# takes, so it is measured against the real thing: Monty's pretrained graphs,
# queried once per hypothesis, which is what displacing evidence does.
#
#     MIX_ENV=test mix run scripts/bench_neighbours.exs
#
# Recorded 2026-10-28, Apple M-series, Elixir 1.20.4 / OTP 29:
#
#     search for a full hypothesis set     95.4ms for 16_083 queries (5.9us each)
#     a matching step, all of it          ~39ms median, ~1.06s heaviest
#     so, the search                      a tenth of a median step, a quarter of
#                                         the heaviest, where bursts double the
#                                         hypothesis set twice over
#
# Which is a ceiling, not a measurement of a replacement: an index that answered
# instantly would save that share and nothing else, while the rest of the step —
# scoring every node, rotating poses, accumulating evidence over thousands of
# hypotheses — is untouched. Hence: keep this tree, and spend the effort on the
# list walking that the profiler ranks above it.

alias Monty.Frameworks.Models.GraphMatching.GraphMemory
alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
alias Monty.Test.MontyRecording

pretrained = "priv/monty/libraries/pretrained_ycb_v10/surf_agent_1lm_10distinctobj.jsonl.gz"
neighbours = 5

memory = MontyRecording.load_pretrained!(pretrained)

timings =
  for object_id <- Enum.sort(GraphMemory.get_memory_ids(memory)) do
    model = GraphMemory.get_graph(memory, object_id, "patch")
    positions = GraphObjectModel.positions(model)

    # Every hypothesis searches from its own node's position, which is where
    # hypotheses start: the realistic worst case for a query.
    {us, _} = :timer.tc(fn -> GraphObjectModel.find_nearest_neighbors(model, positions, neighbours) end)

    {object_id, length(positions), us}
  end

for {object_id, queries, us} <- timings do
  IO.puts("#{object_id}: #{queries} queries in #{Float.round(us / 1000, 1)}ms")
end

total = Enum.reduce(timings, 0, fn {_id, _n, us}, sum -> sum + us end)
queries = Enum.reduce(timings, 0, fn {_id, n, _us}, sum -> sum + n end)

IO.puts(
  "total #{Float.round(total / 1000, 1)}ms for #{queries} queries " <>
    "(#{Float.round(total / queries, 1)}us each)"
)
