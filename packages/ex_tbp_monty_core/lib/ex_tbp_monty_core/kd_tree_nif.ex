defmodule ExTbpMonty.Core.KdTreeNif do
  @moduledoc """
  The native index `Monty.Frameworks.Utils.KdTree` uses when it can.

  The Elixir tree in that module is the reference: it is what the tests describe,
  what runs on a machine without a Rust toolchain, and what the native engine is
  held to by a parity test. This is the fast path — `kiddo`, which answers a
  query in about 0.45 µs against the Elixir tree's 6, and stays flat as the graph
  grows instead of getting slower.

  A NIF is a library the BEAM loads into itself, so its absence is a raised
  `ErlangError` rather than a returned error: `loaded?/0` is the question a caller
  asks once, and `KdTree` asks it when it builds an index.
  """

  use Rustler, otp_app: :ex_tbp_monty_core, crate: "kd_tree_nif"

  @doc "Whether this VM built and loaded the native index."
  @spec loaded?() :: boolean()
  def loaded? do
    available()
  rescue
    # A NIF that is not loaded answers every call with this raise, which is how
    # the runtime says "not here" rather than an error value.
    ErlangError -> false
  end

  @doc "True, from the native side — the only way to know it is loaded."
  def available, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  An index over `positions`, a flat binary of `3 * n` little-endian f64 values.

  A point's id is its position in that binary, which is why `KdTree.build/1`
  only takes this path when the ids it was given are `0..n-1`.
  """
  def build(_positions), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The ids of the `k` points nearest each of the queries in `queries`.

  Swept from one flat binary of `3 * m` f64 values to `m * k` little-endian u32
  ids, nearest first, `4_294_967_295` where a query found fewer than `k`.
  """
  def nearest_many(_index, _queries, _k), do: :erlang.nif_error(:nif_not_loaded)

  @doc "The same answers with the distance to each, as `{ids, distances}`."
  def nearest_many_with_distances(_index, _queries, _k),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "How many points an index holds."
  def nodes(_index), do: :erlang.nif_error(:nif_not_loaded)
end
