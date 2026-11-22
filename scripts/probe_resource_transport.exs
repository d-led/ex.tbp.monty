# What it costs a round to hand a task its hypothesis space, and what it would
# cost to hand it a reference instead.
#
#   MIX_ENV=test mix run scripts/probe_resource_transport.exs
#
# `probe_round_reductions.exs` counts a round against the loop it replaces. This
# one asks where that count goes: a task is handed a copy of what its closure
# holds, and the standing guess is that the copy is the round's excess. So each
# arm below is the same round — eight tasks, fifty times, `ordered: false` — with
# one thing different, the payload, and each task reads nothing, so what the arm
# reports is the transport and the process and nothing else:
#
#   * `nothing` — what a task costs on its own;
#   * `resource` — a `{:nif, reference()}`, `KdTree`'s native form, which is the
#     four words a shared Rust structure would cost;
#   * `space` — one object's hypotheses at 2 000 hypotheses: three refc binaries
#     and a list of booleans, which is the shape the learning modules hold;
#   * `as lists` — the same hypotheses boxed as floats and lists, which is what a
#     port without the binary columns would be sending.
#
# Reductions are the currency, as everywhere in these probes; the wall clock is
# printed beside them so a starved run can be told from a heavy one. `nothing` is
# measured first and last, so drift in the box is visible rather than inferred.

defmodule ProbeResourceTransport do
  @tasks 8
  @rounds 50

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses

  @doc "One object's hypotheses at the size a ten-object world reaches."
  def space(hypotheses) do
    %Hypotheses{
      evidence: :crypto.strong_rand_bytes(hypotheses * 8),
      locations: :crypto.strong_rand_bytes(hypotheses * 24),
      poses: :crypto.strong_rand_bytes(hypotheses * 72),
      possible: List.duplicate(true, hypotheses)
    }
  end

  @doc "The same hypotheses as the boxed floats a port without the columns sends."
  def space_as_lists(hypotheses) do
    %{
      evidence: Enum.map(1..hypotheses, fn n -> n / 7 end),
      locations: Enum.map(1..hypotheses, fn n -> [n / 3, n / 5, n / 11] end),
      poses: Enum.map(1..hypotheses, fn n -> List.duplicate([n / 2, n / 4, n / 6], 3) end),
      possible: Enum.map(1..hypotheses, fn _ -> true end)
    }
  end

  @doc "Words on the heap, and bytes if the payload were serialised."
  def sizes(payload) do
    heap = :erts_debug.size(payload)
    flight = payload |> :erlang.term_to_binary() |> :erlang.external_size()
    {heap, flight}
  end

  def cost(label, payload, touch) do
    run = fn ->
      1..@tasks
      |> Task.async_stream(fn _ -> touch.(payload) end, ordered: false, timeout: :infinity)
      |> Enum.to_list()
    end

    _ = run.()
    _ = :erlang.statistics(:reductions)
    {micros, _} = :timer.tc(fn -> Enum.each(1..@rounds, fn _ -> run.() end) end)
    {_total, reductions} = :erlang.statistics(:reductions)

    IO.puts(
      "#{label}: #{div(reductions, @rounds * @tasks)} reductions a task, " <>
        "#{Float.round(micros / @rounds / 1000, 3)} ms a round of #{@tasks}"
    )
  end
end

alias Monty.Frameworks.Utils.KdTree

points = for index <- 1..200, do: {[index / 10, index / 20, index / 40], 0}
resource = KdTree.build(points)
space = ProbeResourceTransport.space(2_000)
lists = ProbeResourceTransport.space_as_lists(2_000)

{space_heap, space_flight} = ProbeResourceTransport.sizes(space)
{list_heap, _flight} = ProbeResourceTransport.sizes(lists)

IO.puts(
  "one object's space at 2 000 hypotheses: #{space_heap} words, " <>
    "#{space_flight} bytes in flight; the same as float lists: #{list_heap} words"
)

ProbeResourceTransport.cost("nothing   ", nil, fn _ -> 1 end)
ProbeResourceTransport.cost("resource  ", resource, fn _ -> 1 end)
ProbeResourceTransport.cost("space     ", space, fn _ -> 1 end)
ProbeResourceTransport.cost("as lists  ", lists, fn _ -> 1 end)
ProbeResourceTransport.cost("nothing   ", nil, fn _ -> 1 end)
