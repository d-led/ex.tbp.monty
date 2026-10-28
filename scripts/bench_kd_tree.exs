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
# Recorded 2026-10-28, Apple M-series, Elixir 1.20.4 / OTP 29 (µs per query,
# five neighbours, 200 queries each):
#
#     n =  1000    7.9   (build 2.3ms)
#     n =  4000   10.0   (build 9.0ms)
#     n = 16000   13.8   (build 45.8ms)
#
# Before the pruning fix — where the far branch was compared against a
# `{distance, id}` tuple, so it was always taken — the same run was 117 / 522 /
# 2279 µs: linear in n, and the reason a replay of Monty's episode took minutes.

alias Monty.Frameworks.Utils.KdTree

:rand.seed(:exsss, {7, 8, 9})

queries = 200
count = 5

for n <- [1_000, 4_000, 16_000] do
  points = for id <- 0..(n - 1)//1, do: {for(_ <- 1..3, do: :rand.uniform() * 0.3), id}
  searches = for _ <- 1..queries, do: for(_ <- 1..3, do: :rand.uniform() * 0.3)

  {build_us, tree} = :timer.tc(fn -> KdTree.build(points) end)
  {query_us, _} = :timer.tc(fn -> Enum.each(searches, &KdTree.nearest(tree, &1, count)) end)

  IO.puts(
    "n=#{n}  build #{Float.round(build_us / 1000, 1)}ms  " <>
      "query #{Float.round(query_us / queries, 1)}us"
  )
end
