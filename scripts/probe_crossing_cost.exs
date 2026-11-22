# What one graph's update costs, crossing by crossing, and what a crossing is.
#
#   DB_PORT=5432 MIX_ENV=test mix run scripts/probe_crossing_cost.exs [experiment] [steps]
#
# `docs/speed.md`'s open decision ("one crossing") says to price the crossings
# before merging them: per-call price times the calls a step makes. This is that
# ledger, on a live run's own shapes rather than guessed ones.
#
# A crossing has two prices, and only one of them is what a merger can win:
#
#   * the arithmetic and the copies that grow with the rows it carries — a
#     merged kernel still pays those;
#   * the part that does not grow — the call itself, the arguments decoded, the
#     answer's own allocation, and the Elixir that turns a column back into
#     terms.
#
# So every kernel is timed at the size a step hands it and again at one row. The
# difference is its marginal price; what is left is the crossing, and that is
# the ceiling of a merge. The same reading catches the crossings nobody planned:
# work done twice a step, or a column decoded only to be thrown away.
#
# Not a gate. Read the shape — which crossing is carrying the step — not the
# microseconds, which are this box's.

alias ExTbpMonty.Core.MatcherNif

alias Monty.Frameworks.Models.EvidenceMatching.{
  EvidenceSlopeTracker,
  Hypotheses
}

alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculator
alias Monty.Frameworks.Models.GraphMatching.GraphMemory
alias Monty.Runtime.{LearningModuleServer, Registry}
alias Monty.Studio
alias Monty.Studio.Run

defmodule CrossingCost do
  @moduledoc """
  One price per call, taken three times and reported as the middle one, plus
  the row count the call carried.
  """

  @doc "How many iterations make each reading last a few milliseconds."
  def iterations(us) do
    cond do
      us < 1.0 -> 2_000
      us < 10.0 -> 500
      us < 100.0 -> 100
      true -> 20
    end
  end

  @doc "Microseconds a call takes, on the size this fun was built for."
  def per_call(fun) do
    {first, _} = :timer.tc(fun)
    times = iterations(first)

    Enum.each(1..min(times, 20), fn _ -> fun.() end)

    1..3
    |> Enum.map(fn _ ->
      {us, _} = :timer.tc(fn -> Enum.each(1..times, fn _ -> fun.() end) end)
      us / times
    end)
    |> Enum.sort()
    |> Enum.at(1)
  end

  @doc """
  A crossing's two prices: `{at_size, at_one}` in microseconds a call.

  The second fun asks the same kernel about one row. A kernel whose answer is
  fixed-size enough that one row is meaningless is quoted with `nil`, and then
  only the whole price is known — say so rather than pretend.
  """
  def pair(at_size, at_one) do
    {per_call(at_size), per_call(at_one)}
  end
end

defmodule CrossingLedger do
  @moduledoc "Rows of `{name, calls a step, size, at_size us, at_one us}`."

  def row(name, calls, size, {at_size, at_one}), do: {name, calls, size, at_size, at_one}

  def report(rows, graphs, step_us) do
    IO.puts("\n#{graphs} graphs, a step of #{round(step_us / 1000)} ms\n")

    IO.puts(
      "  #{String.pad_trailing("crossing", 34)} #{String.pad_leading("calls", 6)} " <>
        "#{String.pad_leading("rows", 6)} #{String.pad_leading("at size", 9)} " <>
        "#{String.pad_leading("at one", 8)} #{String.pad_leading("fixed/step", 11)} " <>
        "#{String.pad_leading("share", 7)}"
    )

    {total_fixed, whole} =
      Enum.reduce(rows, {0.0, 0.0}, fn {name, calls, size, at_size, at_one},
                                       {fixed_acc, whole_acc} ->
        fixed = if is_nil(at_one), do: at_size, else: at_one
        per_step = fixed * calls
        IO.puts(line(name, calls, size, at_size, at_one, per_step, step_us))
        {fixed_acc + per_step, whole_acc + at_size * calls}
      end)

    IO.puts("")
    IO.puts("  crossing only:   #{us(total_fixed)} a step (#{percent(total_fixed, step_us)})")

    IO.puts(
      "  whole calls:     #{us(whole)} a step (#{percent(whole, step_us)}) — " <>
        "the arithmetic the kernels keep either way"
    )
  end

  defp line(name, calls, size, at_size, at_one, per_step, step_us) do
    "  #{String.pad_trailing(name, 34)} #{String.pad_leading("#{calls}", 6)} " <>
      "#{String.pad_leading("#{size}", 6)} #{String.pad_leading(us(at_size), 9)} " <>
      "#{String.pad_leading(if(at_one, do: us(at_one), else: "—"), 8)} " <>
      "#{String.pad_leading(us(per_step), 11)} #{String.pad_leading(percent(per_step, step_us), 7)}"
  end

  defp us(value), do: "#{Float.round(value / 1.0, 1)} us"
  defp percent(part, whole), do: "#{Float.round(part / whole * 100, 1)}%"
end

defmodule Fixtures do
  @moduledoc """
  One row's worth of each binary, and the bytes a kernel is handed for it.

  The row widths are the ones the memory itself holds, so a crossing is priced
  at the width the step uses.
  """

  @doc "The first `rows` rows of a binary, so a kernel is asked about one row."
  def head(binary, rows, width) do
    binary_part(binary, 0, min(byte_size(binary), rows * width))
  end

  @doc "`count` little-endian f64, all the same value."
  def floats(count, value) do
    :binary.copy(<<value * 1.0::little-float-64>>, count)
  end

  @doc "`count` little-endian u32, counting up from zero."
  def indices(count) do
    for index <- 0..(count - 1)//1, into: <<>>, do: <<index::unsigned-32-little>>
  end

  @doc """
  A column of feature evidence, one f64 a node.

  The value is irrelevant to what a kernel costs; the length is not.
  """
  def evidence(count), do: floats(count, 0.5)
end

defmodule Arguments do
  @moduledoc """
  The arguments a step hands the two kernels it builds rather than holds.

  Where a kernel takes a column the module already has, the ledger uses that
  column; where the step composes one from the observation, it is composed here
  the same way and at the same width, because the crossing is what is being
  priced and the numbers inside it do not change the price.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculator
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias ExTbpMonty.Core.MatcherNif

  @doc "The columns an observation of this channel compares against every node."
  def columns(memory, graph_id, channel) do
    order = GraphMemory.get_feature_order(memory, graph_id, channel)

    observed =
      for feature <- order, into: %{} do
        {feature, Map.fetch!(observed(), feature)}
      end

    weights = for feature <- order, into: %{}, do: {feature, 1.0}
    tolerances = for feature <- order, into: %{}, do: {feature, 1.0}

    DefaultFeatureEvidenceCalculator.columns(order, weights, observed, tolerances)
  end

  # The values an observation carries: what a kernel compares against is not
  # what it costs, so these are the right shape and an arbitrary value.
  defp observed do
    %{
      "hsv" => [0.5, 0.5, 0.5],
      "principal_curvatures_log" => [0.1, 0.0],
      "pose_vectors" => [0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
      "pose_fully_defined" => true,
      "object_id" => 1,
      "on_object" => 1.0,
      "object_coverage" => 0.5
    }
  end

  @doc """
  The evidence kernel's arguments: the hypotheses' rows, the observation's own
  directions, the graph's arrays and the parameters, as the displacer encodes
  them.
  """
  def neighbour_evidence(ids, search_locations, poses, {nodes, node_poses, node_defined}, k) do
    MatcherNif.neighbour_evidence(
      ids,
      k,
      [search_locations, poses, Fixtures.floats(6, 0.0)],
      [nodes, node_poses, node_defined, Fixtures.evidence(div(byte_size(nodes), 24))],
      Fixtures.floats(6, 0.0)
    )
  end

  @doc "The mask kernel's arguments, from a step's own tracker."
  def keep_mask(tracker) do
    channels = tl(tracker.channels)

    MatcherNif.keep_mask(
      tracker.evidence,
      for(here <- channels, into: <<>>, do: <<here * 1.0::little-float-64>>),
      tracker.window_size,
      tracker.cursor,
      for(age <- tracker.ages, into: <<>>, do: <<age::unsigned-32-little>>),
      tracker.min_age,
      0.5
    )
  end

  @doc "One graph's slope column, as the kernel answers it: bytes, not values."
  def slope_bytes(tracker) do
    MatcherNif.window_slopes(
      tracker.evidence,
      for(here <- tl(tracker.channels), into: <<>>, do: <<here * 1.0::little-float-64>>),
      tracker.window_size,
      tracker.cursor
    )
  end

  @doc """
  The step's own `max_global_slope/1` before the kernel answered it, term for
  term.

  This is the shape the port read a burst's trigger from: every graph's slope
  column decoded into a list of floats, all of them concatenated, the nil ones
  rejected, and one maximum taken off the end. Kept here as the arm the kernel
  is measured against.
  """
  def max_global_slope(updater) do
    updater.evidence_slope_trackers
    |> Map.values()
    |> Enum.flat_map(&EvidenceSlopeTracker.calculate_slopes/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      slopes -> Enum.max(slopes)
    end
  end

  @doc "The same question asked of the kernel, one crossing a graph."
  def max_global_slope_native(updater) do
    updater.evidence_slope_trackers
    |> Map.values()
    |> Enum.reject(&(EvidenceSlopeTracker.total_size(&1) == 0))
    |> Enum.map(&EvidenceSlopeTracker.max_slope/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      slopes -> Enum.max(slopes)
    end
  end

  @doc "The same updater, with one graph's tracker and no others."
  def one_graph(updater) do
    [graph_id | _] = Map.keys(updater.evidence_slope_trackers)
    %{updater | evidence_slope_trackers: Map.take(updater.evidence_slope_trackers, [graph_id])}
  end
end

experiment = List.first(System.argv()) || "base_77obj_dist_agent"
steps = System.argv() |> Enum.at(1, "4") |> String.to_integer()

{:ok, opened} = Studio.open(experiment)
{:ok, run} = Run.start(opened.setup, steps: steps)

graphs = length(Monty.Studio.Setup.objects(opened.setup))

{steps_us, run} =
  Enum.map_reduce(1..steps, run, fn _step, run ->
    {us, {:ok, _info, _observations, run}} = :timer.tc(fn -> Run.step(run) end)
    {us, run}
  end)

step_us = Enum.sum(steps_us) / length(steps_us)

# The module, through the registry the step uses: the same state a step left
# behind, not a copy of the constructor's arguments.
[lm_spec] = Run.state(run).learning_modules
server = Registry.via({:learning_module, run.model_id, lm_spec.id})
lm = LearningModuleServer.state(server)

memory = lm.graph_memory
{_module, updater} = lm.hypotheses_updater
displacer = updater.displacer

# One graph with hypotheses, at the median size: the biggest graph is a fixture
# about the biggest graph, and the step is not only its biggest graph.
sizes =
  lm.hypotheses
  |> Enum.map(fn {graph_id, held} -> {graph_id, Hypotheses.count(held)} end)
  |> Enum.sort_by(&elem(&1, 1))

{graph_id, n_hyps} = Enum.at(sizes, div(length(sizes), 2))
held = Map.fetch!(lm.hypotheses, graph_id)
[channel | _] = GraphMemory.get_input_channels_in_graph(memory, graph_id)
n_nodes = GraphMemory.get_num_nodes_in_graph(memory, graph_id, channel)
k = min(displacer.max_nneighbors, n_nodes)
tracker = Map.fetch!(updater.evidence_slope_trackers, graph_id)
window = tracker.window_size
total_hypotheses = sizes |> Enum.map(&elem(&1, 1)) |> Enum.sum()

# The bytes a step already holds for this graph.
poses = held.poses
locations = held.locations
evidence = held.evidence
{search_locations, tested_poses} = Hypotheses.rows_at(held, Enum.to_list(0..(n_hyps - 1)))
{node_rows, width} = GraphMemory.get_feature_rows(memory, graph_id, channel)
{nodes, node_poses, node_defined} = GraphMemory.get_node_arrays(memory, graph_id, channel)

{specs, params} =
  DefaultFeatureEvidenceCalculator.encode_columns(Arguments.columns(memory, graph_id, channel))

graph = GraphMemory.get_graph(memory, graph_id, channel)
{ids, _k} = memory.object_model.find_nearest_neighbor_ids(graph, search_locations, k)

IO.puts("""
#{experiment}, #{steps} steps
  median graph: #{n_hyps} hypotheses, #{n_nodes} nodes, k #{k}, window #{window}
  channels: #{inspect(GraphMemory.get_input_channels_in_graph(memory, graph_id))}
  feature rows: #{width} values a node
  graphs with hypotheses: #{map_size(lm.hypotheses)}
  hypotheses in total: #{total_hypotheses} (the slope column, twice a step)
""")

# A step asks every graph for the same things, one channel each.
calls = fn per_graph -> graphs * per_graph end

rows = [
  CrossingLedger.row(
    "nearest_many_ids",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn -> memory.object_model.find_nearest_neighbor_ids(graph, search_locations, k) end,
      fn ->
        memory.object_model.find_nearest_neighbor_ids(
          graph,
          Fixtures.head(search_locations, 1, 24),
          k
        )
      end
    )
  ),
  CrossingLedger.row(
    "feature_evidence",
    calls.(1),
    n_nodes,
    CrossingCost.pair(
      fn -> MatcherNif.feature_evidence(node_rows, width, specs, params, 1) end,
      fn ->
        MatcherNif.feature_evidence(
          Fixtures.head(node_rows, 1, width * 8),
          width,
          specs,
          params,
          1
        )
      end
    )
  ),
  CrossingLedger.row(
    "neighbour_evidence",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn ->
        Arguments.neighbour_evidence(
          ids,
          search_locations,
          tested_poses,
          {nodes, node_poses, node_defined},
          k
        )
      end,
      fn ->
        Arguments.neighbour_evidence(
          Fixtures.head(ids, 1, k * 4),
          Fixtures.head(search_locations, 1, 24),
          Fixtures.head(tested_poses, 1, 72),
          {nodes, node_poses, node_defined},
          k
        )
      end
    )
  ),
  CrossingLedger.row(
    "displaced_locations",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn ->
        MatcherNif.displaced_locations(
          poses,
          locations,
          <<0.01::float-64-little, 0.0::float-64-little, 0.0::float-64-little>>
        )
      end,
      fn ->
        MatcherNif.displaced_locations(
          Fixtures.head(poses, 1, 72),
          Fixtures.head(locations, 1, 24),
          <<0.01::float-64-little, 0.0::float-64-little, 0.0::float-64-little>>
        )
      end
    )
  ),
  CrossingLedger.row(
    "indices_at_least",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn -> MatcherNif.indices_at_least(evidence, 0.0) end,
      fn -> MatcherNif.indices_at_least(Fixtures.head(evidence, 1, 8), 0.0) end
    )
  ),
  CrossingLedger.row(
    "blend_evidence",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn -> MatcherNif.blend_evidence(evidence, Fixtures.floats(n_hyps, 0.25), 0.5, 0.5) end,
      fn ->
        MatcherNif.blend_evidence(
          Fixtures.head(evidence, 1, 8),
          Fixtures.floats(1, 0.25),
          0.5,
          0.5
        )
      end
    )
  ),
  CrossingLedger.row(
    "spread_add",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn ->
        MatcherNif.spread_add(
          Fixtures.floats(n_hyps, 0.0),
          Fixtures.indices(n_hyps),
          Fixtures.floats(n_hyps, 0.25)
        )
      end,
      fn ->
        MatcherNif.spread_add(
          Fixtures.floats(1, 0.0),
          Fixtures.indices(1),
          Fixtures.floats(1, 0.25)
        )
      end
    )
  ),
  CrossingLedger.row(
    "gather_rows",
    calls.(2),
    n_hyps,
    CrossingCost.pair(
      fn -> MatcherNif.gather_rows(locations, 3, Fixtures.indices(n_hyps)) end,
      fn -> MatcherNif.gather_rows(locations, 3, Fixtures.indices(1)) end
    )
  ),
  CrossingLedger.row(
    "top_indices",
    calls.(1),
    n_nodes,
    CrossingCost.pair(
      fn -> MatcherNif.top_indices(Fixtures.evidence(n_nodes), div(n_nodes, 4)) end,
      fn -> MatcherNif.top_indices(Fixtures.evidence(4), 1) end
    )
  ),
  CrossingLedger.row(
    "argmax_index",
    calls.(2),
    n_hyps,
    CrossingCost.pair(
      fn -> MatcherNif.argmax_index(evidence) end,
      fn -> MatcherNif.argmax_index(Fixtures.head(evidence, 1, 8)) end
    )
  ),
  CrossingLedger.row(
    "indices_within",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn -> MatcherNif.indices_within(evidence, 1.0, 0.0) end,
      fn -> MatcherNif.indices_within(Fixtures.head(evidence, 1, 8), 1.0, 0.0) end
    )
  ),
  CrossingLedger.row(
    "write_slot",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn -> MatcherNif.write_slot(tracker.evidence, evidence, tracker.cursor * 8, window * 8) end,
      fn ->
        MatcherNif.write_slot(
          Fixtures.head(tracker.evidence, 1, window * 8),
          Fixtures.head(evidence, 1, 8),
          tracker.cursor * 8,
          window * 8
        )
      end
    )
  ),
  CrossingLedger.row(
    "keep_mask",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn -> Arguments.keep_mask(tracker) end,
      fn ->
        Arguments.keep_mask(%{
          tracker
          | evidence: Fixtures.head(tracker.evidence, 1, window * 8),
            ages: [0]
        })
      end
    )
  ),
  CrossingLedger.row(
    "window_slopes + decode",
    calls.(2),
    n_hyps,
    CrossingCost.pair(
      fn -> EvidenceSlopeTracker.calculate_slopes(tracker) end,
      fn ->
        EvidenceSlopeTracker.calculate_slopes(%{
          tracker
          | evidence: Fixtures.head(tracker.evidence, 1, window * 8)
        })
      end
    )
  ),
  CrossingLedger.row(
    "window_slopes (bytes out)",
    calls.(2),
    n_hyps,
    CrossingCost.pair(
      fn -> Arguments.slope_bytes(tracker) end,
      fn ->
        Arguments.slope_bytes(%{
          tracker
          | evidence: Fixtures.head(tracker.evidence, 1, window * 8)
        })
      end
    )
  ),
  CrossingLedger.row(
    "decode a slope column",
    calls.(2),
    n_hyps,
    CrossingCost.pair(
      fn -> MatcherNif.decode(Arguments.slope_bytes(tracker)) end,
      fn -> MatcherNif.decode(Fixtures.floats(1, 0.5)) end
    )
  ),
  CrossingLedger.row(
    "max_global_slope (decode)",
    1,
    total_hypotheses,
    CrossingCost.pair(fn -> Arguments.max_global_slope(updater) end, fn ->
      Arguments.max_global_slope(Arguments.one_graph(updater))
    end)
  ),
  CrossingLedger.row(
    "max_global_slope (kernel)",
    1,
    total_hypotheses,
    CrossingCost.pair(fn -> Arguments.max_global_slope_native(updater) end, fn ->
      Arguments.max_global_slope_native(Arguments.one_graph(updater))
    end)
  ),
  CrossingLedger.row(
    "slope update",
    calls.(1),
    n_hyps,
    CrossingCost.pair(
      fn -> EvidenceSlopeTracker.update(tracker, evidence, num_channels: 1) end,
      fn ->
        EvidenceSlopeTracker.update(
          %{tracker | evidence: Fixtures.head(tracker.evidence, 1, window * 8), ages: [0]},
          Fixtures.head(evidence, 1, 8), num_channels: 1)
      end
    )
  )
]

CrossingLedger.report(rows, graphs, step_us)

# The telemetry arm: the same per-object updates with Monty's `include_telemetry`
# off and on, alternating, over every graph the step has hypotheses for. The
# answers must be the same object for object — the flag decides what is
# reported, not what is computed — and the difference is what a step pays for a
# report nothing reads.
defmodule TelemetryArm do
  @moduledoc """
  One pass of every graph's update, as `update_evidence/5` performs it.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater

  @doc "The updater with the report switched on or off, standing at a quiet step."
  def updater(updater, include?),
    do: %{updater | include_telemetry: include?, sampling_burst_steps: 0}

  @doc """
  One pass over `graph_ids`: `update_evidence/5` a graph, threading the updater.

  The hypotheses a graph holds are the ones the step left it with, so every arm
  starts from the same space.
  """
  def pass(updater, graph_ids, hypotheses, features, threshold) do
    Enum.reduce(graph_ids, {updater, %{}}, fn graph_id, {updater, updated} ->
      {updater, held, _telemetry} =
        BurstSamplingHypothesesUpdater.update_evidence(
          updater,
          Map.fetch!(hypotheses, graph_id),
          features,
          graph_id,
          threshold
        )

      {updater, Map.put(updated, graph_id, held)}
    end)
  end

  @doc "Microseconds a pass takes."
  def micros(fun) do
    {us, _} = :timer.tc(fun)
    us
  end
end

graph_ids =
  lm.hypotheses
  |> Enum.filter(fn {_graph_id, held} -> Hypotheses.count(held) > 0 end)
  |> Enum.map(&elem(&1, 0))
  |> Enum.sort()

# What an observation carries, at the widths this channel stores: the price of a
# kernel does not depend on the values, and both arms are handed the same ones.
features = %{
  "patch" => %{
    "hsv" => [0.5, 0.5, 0.5],
    "principal_curvatures_log" => [0.0, 0.0],
    "pose_vectors" => [0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
    "pose_fully_defined" => true,
    "on_object" => 1.0,
    "object_coverage" => 0.5
  }
}

threshold = 0.0

arms =
  for include? <- [false, true, false, true] do
    start = TelemetryArm.updater(updater, include?)

    {us, {_updater, updated}} =
      :timer.tc(fn -> TelemetryArm.pass(start, graph_ids, lm.hypotheses, features, threshold) end)

    {include?, us, updated}
  end

off = for {false, us, _} <- arms, do: us
on = for {true, us, _} <- arms, do: us
[{_, _, quiet}, {_, _, talkative} | _] = arms

IO.puts("\nthe telemetry arm, #{length(graph_ids)} graphs, every hypothesis they hold\n")

IO.puts(
  "  off: #{for us <- off, do: "#{Float.round(us / 1000, 1)} ms"}   " <>
    "on: #{for us <- on, do: "#{Float.round(us / 1000, 1)} ms"}"
)

IO.puts(
  "  median #{Float.round(Enum.at(Enum.sort(off), 1) / 1000, 1)} ms against " <>
    "#{Float.round(Enum.at(Enum.sort(on), 1) / 1000, 1)} ms — " <>
    "#{Float.round((Enum.at(Enum.sort(on), 1) - Enum.at(Enum.sort(off), 1)) / 1000, 1)} ms a step\n"
)

same? =
  Enum.all?(quiet, fn {graph_id, held} ->
    other = Map.fetch!(talkative, graph_id)
    held.evidence == other.evidence and held.locations == other.locations
  end)

IO.puts("  the answers are the same either way: #{same?}")

Run.stop(run)
