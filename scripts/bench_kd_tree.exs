# Timing for the nearest-neighbour index, by problem size.
#
# `KdTree` answers the question displacing asks of every hypothesis every step:
# which stored nodes are nearest this search location. Its cost has to be flat in
# the number of stored points, or a pretrained object of a few thousand nodes is
# paid for on every step. This is the check, and it is a script rather than a
# test because a test asserting a duration is a test that fails on a busy
# machine; what a test can hold is the answer, which `kd_tree_test.exs` does
# against brute force.
#
#     MIX_ENV=test mix run scripts/bench_kd_tree.exs
#
# Recorded 2026-11-01, Apple M-series, Elixir 1.20.5 / OTP 29 (µs per query,
# five neighbours, 2 000 queries each), native = `kiddo` behind a NIF:
#
#     n        native        elixir       (build: native / elixir)
#      1000     0.5–2.7       5.4–8.0      2.5ms / 1.5ms
#      4000     0.6–2.2       5.8–10.8     0.8ms / 9.6ms
#     16000     0.7–1.1       7.6–11.6     2.2ms / 54.2ms
#
# The ranges are the same script on a busy machine and an idle one; only the
# ratio is stable, and it is 4–11 times in the native column's favour.
#
# The native column is the whole round trip — encoding the queries, the search,
# decoding the ids — and it is flat in n, which is the property the 77-object
# experiment needs. Both columns answer exactly the same ids.
#
# Before the pruning fix — where the far branch was compared against a
# `{distance, id}` tuple, so it was always taken — the Elixir column was
# 117 / 522 / 2279 µs: linear in n, and the reason a replay took minutes.

alias Monty.Frameworks.Utils.KdTree

:rand.seed(:exsss, {7, 8, 9})

queries = 2_000
count = 5

for n <- [1_000, 4_000, 16_000] do
  points = for id <- 0..(n - 1)//1, do: {for(_ <- 1..3, do: :rand.uniform() * 0.3), id}
  searches = for _ <- 1..queries, do: for(_ <- 1..3, do: :rand.uniform() * 0.3)

  {native_build, native} = :timer.tc(fn -> KdTree.build(points) end)
  {elixir_build, elixir} = :timer.tc(fn -> KdTree.build_elixir(points) end)

  {native_query, _} = :timer.tc(fn -> KdTree.nearest_many(native, searches, count) end)
  {elixir_query, _} = :timer.tc(fn -> KdTree.nearest_many(elixir, searches, count) end)

  IO.puts(
    "n=#{n}  native #{Float.round(native_query / queries, 2)}us " <>
      "(build #{Float.round(native_build / 1000, 1)}ms)  " <>
      "elixir #{Float.round(elixir_query / queries, 2)}us " <>
      "(build #{Float.round(elixir_build / 1000, 1)}ms)  " <>
      "same: #{KdTree.nearest_many(native, searches, count) == KdTree.nearest_many(elixir, searches, count)}"
  )
end
