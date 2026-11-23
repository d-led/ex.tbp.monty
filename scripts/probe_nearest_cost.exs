# What one graph's k-nearest search costs, at the size a step hands it.
#
#   DB_PORT=5432 MIX_ENV=test mix run scripts/probe_nearest_cost.exs [experiment]
#
# `/usr/bin/sample` on a stepping beam puts kiddo's `nearest_n_recurse` first by
# a wide margin — more samples than everything else in the step together — and a
# step asks it one question per hypothesis, every hypothesis distinct. So this is
# the step's dominant cost, and this probe is the lever for changing it: it takes
# a live run's own graph (its positions, its query rows, its `k`) and prices the
# batch call three times, so a change to the index can be measured without
# stepping a whole run.
#
# Not a gate: the numbers are this box's. Compare two builds' readings of the
# same line.

alias ExTbpMonty.Core.KdTreeNif
alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
alias Monty.Frameworks.Models.GraphMatching.GraphMemory
alias Monty.Frameworks.Utils.KdTree
alias Monty.Runtime.{LearningModuleServer, Registry}
alias Monty.Studio

experiment = List.first(System.argv()) || "base_77obj_dist_agent"

{:ok, opened} = Studio.open(experiment)
{:ok, run} = Monty.Studio.Run.start(opened.setup, steps: 20)

# Six steps, so the spaces are the size a matchable step carries.
run =
  Enum.reduce(1..6, run, fn _step, run ->
    {:ok, _info, _observations, run} = Monty.Studio.Run.step(run)
    run
  end)

[lm_spec] = Monty.Studio.Run.state(run).learning_modules
lm = LearningModuleServer.state(Registry.via({:learning_module, run.model_id, lm_spec.id}))

# The biggest graph, which is the one a change shows up in first.
{graph_id, held} =
  lm.hypotheses
  |> Enum.map(fn {graph_id, held} -> {graph_id, Hypotheses.count(held)} end)
  |> Enum.max_by(&elem(&1, 1))

space = Map.fetch!(lm.hypotheses, graph_id)
channel = hd(GraphMemory.get_input_channels_in_graph(lm.graph_memory, graph_id))
graph = GraphMemory.get_graph(lm.graph_memory, graph_id, channel)
{queries, _poses} = Hypotheses.rows_at(space, Enum.to_list(0..(Hypotheses.count(space) - 1)))

{:nif, index} = graph.location_tree
nodes = KdTreeNif.nodes(index)

IO.puts("""
#{experiment}, graph #{graph_id}
  #{nodes} nodes, #{div(byte_size(queries), 24)} queries, k 5
""")

defmodule NearestCost do
  @moduledoc "Microseconds the batch query takes, three times over."

  def per_call(index, queries, k) do
    _ = KdTreeNif.nearest_many(index, queries, k)

    1..3
    |> Enum.map(fn _round ->
      {us, _} = :timer.tc(fn -> KdTreeNif.nearest_many(index, queries, k) end)
      us
    end)
  end

  def report(nodes, queries, readings) do
    count = div(byte_size(queries), 24)
    us = readings |> Enum.sort() |> Enum.at(1)

    IO.puts(
      "  #{us} us for #{count} queries over #{nodes} nodes " <>
        "(#{Float.round(us / count * 1000, 0)} ns a query) " <>
        "#{inspect(readings)} us the three readings"
    )
  end
end

NearestCost.report(nodes, queries, NearestCost.per_call(index, queries, 5))
NearestCost.report(nodes, queries, NearestCost.per_call(index, queries, 3))

Monty.Studio.Run.stop(run)
