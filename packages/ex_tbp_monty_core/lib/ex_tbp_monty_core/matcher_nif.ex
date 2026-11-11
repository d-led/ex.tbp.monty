defmodule ExTbpMonty.Core.MatcherNif do
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

  use Rustler, otp_app: :ex_tbp_monty_core, crate: "matcher_nif"

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
    for <<window::binary-size(8) <- binary>>, do: decode_one(window)
  end

  # A NaN has every exponent bit set and a significand that is not zero — and
  # that significand can lie entirely in the low half, which is why the low half
  # is read at all. Both halves are 32-bit integers, which fit in a small
  # integer; asking for the whole word as one integer does not, so each value
  # would pay for a bignum and then for a binary built back out of it. Read as
  # halves, the window itself is what the float is read from: 20 % less time and
  # a third of the words, measured by `scripts/probe_decode.exs`.
  @high_exponent 0x7FF0_0000
  @high_significand 0x000F_FFFF

  defp decode_one(<<low::unsigned-32-little, high::unsigned-32-little>>)
       when Bitwise.band(high, @high_exponent) == @high_exponent and
              (Bitwise.band(high, @high_significand) != 0 or low != 0) do
    nil
  end

  defp decode_one(window) do
    <<value::float-64-little>> = window
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

  @doc """
  Which hypotheses a slope threshold keeps, one byte each: `1` kept, `0` not.

  The question a module asks of its slopes is nearly always this one, and asking
  it here is one crossing instead of two: the slopes never become Elixir terms,
  so nothing is boxed and nothing is decoded. `evidence`, `channels`, `window`
  and `cursor` are as `window_slopes/4` takes them, `ages` is one u32 per
  hypothesis, and the rule is the reference's:

      keep = age < min_age || (slope is not NaN && slope >= threshold)

  `EvidenceSlopeTracker.select_hypotheses/2` is the reference this is held to,
  and it walks the same bytes in Elixir when the kernels are off.
  """
  def keep_mask(_evidence, _channels, _window, _cursor, _ages, _min_age, _threshold),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  One column written into every row of `evidence`: `values` at `offset` in each
  `stride`-long row, everything else untouched.

  A tracker's windows are a ring and a step writes the same slot in all of them,
  so this is a copy with a column replaced. `EvidenceSlopeTracker.update/3` is
  the reference — it walks the same bytes in Elixir when the kernels are off.
  """
  def write_slot(_evidence, _values, _offset, _stride),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  One channel's evidence, spread over the whole hypothesis set.

  `totals` is `hypotheses` f64, what each hypothesis has earned from the channels
  so far; `tested` is `k` u32, the indices a kernel answered for; `values` is the
  `k` f64 it answered. The answer is `hypotheses` f64: `total + value` for a
  tested hypothesis, and `total + max(min(values), 0)` for the rest — an
  untested hypothesis must not be rewarded for a step it did not take part in.

  `HypothesesDisplacer.evidence_to_add/7` is the reference this is held to.
  """
  def spread_add(_totals, _tested, _values), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The indices of the `count` highest values in a column, lowest first.

  `evidence` is `nodes` f64 — one feature-evidence answer per node, NaN where a
  node has no features — and the answer is `count` u32 in the order the sampler
  takes them: evidence ascending, ties by index ascending, which is how
  `Enum.sort_by(&{evidence, index}) |> Enum.take(-count)` reads the same column.

  `DefaultFeatureEvidenceScorer.evidence/4` is where the column comes from and
  `BurstSamplingHypothesesUpdater.top_indices/2` is the reference.
  """
  def top_indices(_evidence, _count), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The index of the second highest value — the runner-up hypothesis.

  A vote weighs the best hypothesis against the next one, so a step asks this
  once per object. The Elixir it replaces decoded the column, made a tuple per
  hypothesis and sorted all of them to read one index off the end; the answer is
  in the bytes. `nil` for fewer than two values, and ties go the way
  `Enum.sort_by(fn {value, index} -> {value, index} end) |> Enum.at(-2)` sent
  them.
  """
  def second_argmax_index(_column), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The lowest evidence in the column — the threshold that updates everything.

  `evidence_threshold_config: "all"` is Monty's default and what the experiments
  run, and a step asked for it once per graph. The answer is one number out of a
  column of thousands, so it is read out of the bytes: decoding them into a list
  to take a minimum of it was the largest single Elixir cost in a ten-object
  step. `nil` when every value is a NaN, which is `Enum.min/1`'s answer for a
  column of `nil`s.
  """
  def min_value(_column), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The hypotheses whose evidence has reached `threshold`, in index order.

  `evidence` is `hypotheses` f64; the answer is `k` u32. The reference is the
  comprehension `for {evidence, index} <- Enum.with_index(column), evidence >= threshold`.
  """
  def indices_at_least(_evidence, _threshold), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The first index holding the highest value of a column — numpy's `argmax`.

  `column` is `n` f64; the answer is one u32. The reference is
  `EvidenceGraphLM`'s `argmax/1`, which reports the first of several equal maxima.
  """
  def argmax_index(_column), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The evidence column after a step, and what its most likely hypothesis earned.

  `past · past_weight + present · present_weight` for every hypothesis, and
  `present` at the first index holding the highest `past` — numpy's `argmax`,
  which reports the first of several equal maxima. The reference is
  `HypothesesDisplacer.compute_evidence/6`'s two passes in Elixir.
  """
  def blend_evidence(_past, _present, _past_weight, _present_weight),
    do: :erlang.nif_error(:nif_not_loaded)
end
