defmodule ExTbpMonty.MatcherNif do
  @moduledoc """
  The native kernels a matching step repeats once per node and once per
  hypothesis.

  The Elixir arithmetic in each calling module is the reference: it is what the
  tests describe, what runs on a machine without a Rust toolchain, and what these
  kernels are held to by parity tests. They exist because that reference pays
  Elixir's price per value — a boxed float, a list cell, a tuple — where the
  answer is the same arithmetic over a few thousand rows.

  A NIF is a library the BEAM loads into itself, so its absence is a raised
  `ErlangError` rather than a returned error: `loaded?/0` is the question a
  caller asks, and every caller has a path for the answer `false`.

  ## Turning them off

  `loaded?/0` also answers `false` when the application is configured with
  `config :ex_tbp_monty, native_kernels?: false`. That is how a test asks for the
  reference path on a machine that has the kernels, and how a run can be compared
  with itself: two runs of the same episode, one with the switch either way, must
  reach the same numbers.
  """

  use Rustler, otp_app: :ex_tbp_monty, crate: "matcher_nif"

  @doc """
  Whether this VM built and loaded the native kernels, and the configuration has
  not turned them off.
  """
  @spec loaded?() :: boolean()
  def loaded? do
    Application.get_env(:ex_tbp_monty, :native_kernels?, true) and loaded_now?()
  end

  defp loaded_now? do
    available()
  rescue
    ErlangError -> false
  end

  @doc "True, from the native side — the only way to know it is loaded."
  def available, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The bytes of a missing value: the IEEE quiet NaN.

  Erlang has no NaN — the pattern is not a float the syntax can build — so this
  is the one way to write the value both sides agree means "no answer": a node
  with no feature, a comparison that produced nothing, evidence there is none of.
  """
  @spec not_a_number() :: binary()
  def not_a_number, do: <<0x7FF8_0000_0000_0000::little-64>>

  @doc """
  A kernel's answers as Elixir values: a NaN is `nil`.

  Read as the integers the bytes are, because a comprehension over
  `<<value::float-64>>` does not raise on a NaN — it stops, silently returning
  the answers before it.
  """
  @spec decode(binary()) :: [float() | nil]
  def decode(binary) do
    for <<bits::unsigned-64-little <- binary>>, do: decode_one(bits)
  end

  @exponent_mask 0x7FF0_0000_0000_0000
  @significand_mask 0x000F_FFFF_FFFF_FFFF

  defp decode_one(bits)
       when Bitwise.band(bits, @exponent_mask) == @exponent_mask and
              Bitwise.band(bits, @significand_mask) != 0 do
    nil
  end

  defp decode_one(bits) do
    <<value::float-64-little>> = <<bits::unsigned-64-little>>
    value
  end

  @doc """
  The feature evidence of every row, computed natively.

  `rows` is `n * width` little-endian f64 with NaN where a node has no value;
  `specs` gives each column's index and kind (two u32), `params` its observed
  value, tolerance and weight (three f64). The answer is `n` f64, NaN where the
  reference answers `nil`.
  """
  def feature_evidence(_rows, _width, _specs, _params, _increment),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The best evidence around each hypothesis, computed natively.

  `ids` is `hypotheses * k` u32 as the index answered them. `hypotheses` is what
  was asked — the search locations (3 f64 each), the hypothesis rotations (9 f64
  each, row by row) and the observation's own normal and first curvature
  direction (6 f64) — and `graph` is what was asked of: every node's location
  (3 f64), its normal and first curvature direction (6 f64), whether its pose was
  fully defined, and what its features were worth. `params` is `flatness`,
  `max_match_distance`, the normal weight, the curvature weight, whether the
  curvature direction was defined (`1.0` or `0.0`), and the evidence of a
  hypothesis with no neighbour in range.

  The answer is one f64 per hypothesis.
  """
  def neighbour_evidence(_ids, _k, _hypotheses, _graph, _params),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A patch's principal curvatures at its middle pixel, computed natively.

  `points` is the patch as one flat binary of ``count * stride`` f64 — three
  coordinates and, last of all, the on-surface mask — and `params` is the width of
  the Gaussian that weights the fit, whether to weight it, and whether to fit an
  intercept. The answer is nine f64: the two curvatures, their directions (three
  values each) and whether they were defined.
  """
  def principal_curvatures(_points, _stride, _width, _center_id, _normal, _params),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Where every hypothesis' search location moves to, computed natively.

  `poses` is `hypotheses * 9` f64, each rotation row by row; `locations` is the
  search location each hypothesis claims (`hypotheses * 3` f64); `displacement`
  is the three f64 the sensor moved by. The answer is `hypotheses * 3` f64:
  `location + pose · displacement`, the same three dot products in the same order
  as `SpatialArithmetics.add/2` over `Geometry.apply/2`, which is the reference
  the parity test holds this to.
  """
  def displaced_locations(_poses, _locations, _displacement),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The average per-channel slope of every hypothesis' evidence window.

  `evidence` is `hypotheses * window` f64 in ring order — one row a hypothesis,
  NaN for a slot that has not been filled — and `cursor` is the slot the next
  update overwrites, which is also the oldest value every window holds.
  `channels` is the channel count at the later slot of each consecutive pair.

  The answer is one f64 per hypothesis: the mean of the steps that have two
  observations, NaN where the window has none. `EvidenceSlopeTracker` is the
  reference this is held to, and it reads the same bytes when the kernels are
  off.
  """
  def window_slopes(_evidence, _channels, _window, _cursor),
    do: :erlang.nif_error(:nif_not_loaded)
end
