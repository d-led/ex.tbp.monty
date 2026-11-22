defmodule Monty.Random.Numpy do
  @moduledoc """
  NumPy's `RandomState`, as far as Monty draws from it.

  Monty's randomness is `numpy.random.RandomState`, and a number that is not
  NumPy's is a different experiment rather than a different implementation of the
  same one: the salience module dithers its scores with `rng.normal` and the
  agent turns towards whichever point the dither leaves in front of it, so the
  first action of an episode — and with it every later one — is a function of
  these numbers. Hence a port of the generator itself, not of its statistics.

  Ported: MT19937 seeded as NumPy seeds it (`init_genrand`, which is what
  `RandomState(seed)` does for a seed below 2³²), numpy's `random_sample`
  (`rk_double`, two 32-bit words per double), `normal` (`rk_gauss`: Marsaglia's
  polar method keeping NumPy's cached second value, which is part of its state and
  survives between calls — including between calls of odd length, where the spare
  is what the next call returns), and the bounded integer `randint` with the
  `choice` built on it, which is what an action sampler draws with.

  `choice` is Monty's action draw — `rng.choice(self._method_names)` in
  `action_samplers.py` — so a stream without it cannot answer which action comes
  next, and an episode's walk is the wrong walk: measured on
  `bright_world_image_on_scanned_model` seed 42, `RandomState(42).choice(4)` is
  `turn_left` and so is Monty's first action, while an Erlang stream's is not.

  Not ported: the world-side draws, which its own code still makes — see
  `scripts/monty_simulator_peer.py`.

  State is a value, so a caller threads it:

      {f, state} = Numpy.random_sample(Numpy.new(42))

  which is what lets a stream be part of a struct or a fold without a process.
  """

  import Bitwise

  @n 624
  @m 397
  @matrix_a 0x9908B0DF
  @upper_mask 0x80000000
  @lower_mask 0x7FFFFFFF
  @mask 0xFFFFFFFF
  @two32 0x1_0000_0000
  @double_scale 9_007_199_254_740_992.0
  @word_to_double_high 67_108_864.0

  @enforce_keys [:key, :pos]
  defstruct [:key, :pos, has_gauss: false, gauss: 0.0]

  @type t :: %__MODULE__{
          key: tuple(),
          pos: non_neg_integer(),
          has_gauss: boolean(),
          gauss: float()
        }

  @doc """
  The generator `numpy.random.RandomState(seed)` is, at its first draw.

  NumPy refuses a seed it cannot seed a Mersenne Twister with in one word, and so
  does this: Monty's episode seeds are already below 2³²
  (`Monty.Frameworks.Experiments.Seed`), and a larger one would silently be a
  different stream.
  """
  @spec new(non_neg_integer()) :: t()
  def new(seed) when is_integer(seed) and seed >= 0 and seed < @two32 do
    # NumPy's state after seeding is the untwisted array with the cursor past its
    # end, so the first draw twists.
    %__MODULE__{key: seed_key(seed), pos: @n}
  end

  @doc "A float drawn uniformly from `[0, 1)`: numpy's `random_sample`, and `rand`."
  @spec random_sample(t()) :: {float(), t()}
  def random_sample(%__MODULE__{} = state) do
    {high, state} = next_uint32(state)
    {low, state} = next_uint32(state)

    {((high >>> 5) * @word_to_double_high + (low >>> 6)) / @double_scale, state}
  end

  @doc "A float drawn uniformly from `[low, high)`: numpy's `uniform`."
  @spec uniform(t(), float(), float()) :: {float(), t()}
  def uniform(%__MODULE__{} = state, low, high) do
    {draw, state} = random_sample(state)

    {low + (high - low) * draw, state}
  end

  @doc """
  An integer in `[low, high)`: numpy's `randint(low, high)`.

  The draw is numpy's `random_interval`: a raw 32-bit word masked down to the
  smallest all-ones mask that covers the range, redrawn while it is past it. The
  mask is why the numbers are not `floor(uniform * range)`: for a range that is
  not a power of two the two disagree, and a walk drawn from the wrong one is a
  different walk.
  """
  @spec randint(t(), integer(), integer()) :: {integer(), t()}
  def randint(%__MODULE__{} = state, low, high) when is_integer(high) and high > low do
    {draw, state} = interval(state, high - low - 1)

    {low + draw, state}
  end

  @doc """
  One of `count` items, each equally likely: numpy's `choice(sequence)`.

  An index, because that is all `choice` is: numpy takes `randint(0, len)` and
  indexes with it, so a caller with a list of action names does the same and the
  stream spends exactly one draw.
  """
  @spec choice(t(), pos_integer()) :: {non_neg_integer(), t()}
  def choice(state, count) when is_integer(count) and count > 0,
    do: randint(state, 0, count)

  @doc """
  A normal draw: numpy's `normal(loc, scale, size=1)`.

  The second value of each polar pair is kept in the state, as NumPy keeps it, so
  a caller drawing one at a time gets numpy's numbers and not half of them.
  """
  @spec normal(t(), float(), float()) :: {float(), t()}
  def normal(%__MODULE__{has_gauss: true} = state, loc, scale) do
    {loc + scale * state.gauss, %{state | has_gauss: false, gauss: 0.0}}
  end

  def normal(%__MODULE__{} = state, loc, scale) do
    {x1, x2, r2, state} = polar(state)
    factor = :math.sqrt(-2.0 * :math.log(r2) / r2)

    {loc + scale * (factor * x2), %{state | has_gauss: true, gauss: factor * x1}}
  end

  @doc """
  `count` normal draws: numpy's `normal(loc, scale, size=count)`.

  `scale` is one number or one number a draw, because NumPy broadcasts an array
  scale over the draws (`rng.normal(0, [0.1, 0.2, 0.2], 3)`) — which is how
  Monty writes a per-channel noise amount. A scale array spends the stream
  exactly as `count` scalar draws do, so nothing after it moves.
  """
  @spec normals(t(), non_neg_integer(), float(), float() | [float()]) :: {[float()], t()}
  def normals(%__MODULE__{} = state, 0, _loc, _scale), do: {[], state}

  def normals(%__MODULE__{} = state, count, loc, scale) when is_list(scale) do
    if length(scale) != count do
      raise ArgumentError,
            "a per-draw scale of #{length(scale)} values for #{count} draws: " <>
              "NumPy broadcasts one scale to one draw"
    end

    {draws, state} = normals(state, count, 0.0, 1.0)

    {Enum.zip_with([draws, scale], fn [draw, sigma] -> loc + sigma * draw end), state}
  end

  def normals(%__MODULE__{} = state, count, loc, scale) do
    Enum.map_reduce(1..count, state, fn _draw, state -> normal(state, loc, scale) end)
  end

  # -- the Mersenne Twister -------------------------------------------------

  # numpy's `random_interval`: mask the word down to the range, redraw while it
  # is past it. A range of one item spends no draw at all.
  defp interval(state, 0), do: {0, state}

  defp interval(state, max) do
    {word, state} = next_uint32(state)
    value = word &&& mask_covering(max)

    if value > max, do: interval(state, max), else: {value, state}
  end

  # The smallest mask of ones that covers `max`: the range's own bits spread
  # right, which is what numpy's four shifts do.
  defp mask_covering(0), do: 0

  defp mask_covering(max) do
    Enum.reduce([1, 2, 4, 8, 16], max, fn shift, mask -> mask ||| mask >>> shift end)
  end

  # `init_genrand`, one word per call: the next word is the previous one scrambled
  # and offset by the index it lands on.
  defp seed_key(seed) do
    {key, _previous} =
      Enum.map_reduce(0..(@n - 1), seed, fn
        0, _seed -> {seed, seed}
        index, previous -> scramble(previous, index)
      end)

    List.to_tuple(key)
  end

  defp scramble(previous, index) do
    word = 1_812_433_253 * bxor(previous, previous >>> 30) + index &&& @mask

    {word, word}
  end

  defp next_uint32(%__MODULE__{key: key, pos: @n} = state) do
    next_uint32(%{state | key: twist(key), pos: 0})
  end

  defp next_uint32(%__MODULE__{key: key, pos: pos} = state) do
    {temper(elem(key, pos)), %{state | pos: pos + 1}}
  end

  # The whole block at once, in one pass. NumPy twists in place, so a word is
  # made from `old[i]`, `old[i + 1]` and `old[i + 397]`, and past index 226 that
  # third word is one this pass has already rewritten — 227 back from where it
  # is read — and the last word's successor is the new first one. The cursor
  # over the old words therefore gives the word and the one after it, and a
  # queue of the new ones answers `new[index - 227]` from index 227 on: only the
  # oldest new word is ever read back, so a queue is the whole of what the map
  # of every index used to be.
  defp twist(key) do
    old = Tuple.to_list(key)
    {_first, _queue, new} = twist(old, Enum.drop(old, @m), {[], []}, [], nil)
    List.to_tuple(Enum.reverse(new))
  end

  defp twist([a], _cursor, queue, new, first) do
    {c, queue} = pop(queue)
    value = twist_word(a, first, c)
    {first, push(queue, value), [value | new]}
  end

  defp twist([a, b | rest], cursor, queue, new, first) do
    {c, cursor, queue} =
      case cursor do
        [c | cursor] -> {c, cursor, queue}
        [] -> pop(queue) |> then(fn {c, queue} -> {c, [], queue} end)
      end

    value = twist_word(a, b, c)
    first = first || value
    twist([b | rest], cursor, push(queue, value), [value | new], first)
  end

  defp twist_word(a, b, c) do
    y = (a &&& @upper_mask) ||| (b &&& @lower_mask)
    bxor(c, bxor(y >>> 1, if((y &&& 1) == 1, do: @matrix_a, else: 0)))
  end

  defp push({front, back}, value), do: {front, [value | back]}

  defp pop({[head | front], back}), do: {head, {front, back}}

  defp pop({[], back}) do
    [head | front] = Enum.reverse(back)
    {head, {front, []}}
  end

  defp temper(word) do
    word
    |> bxor(word >>> 11)
    |> then(&bxor(&1, &1 <<< 7 &&& 0x9D2C5680))
    |> then(&bxor(&1, &1 <<< 15 &&& 0xEFC60000))
    |> then(&bxor(&1, &1 >>> 18))
  end

  # Marsaglia's polar method: a point in the unit disc, and the factor that turns
  # it into two normals. A point outside is thrown away and another drawn.
  defp polar(state) do
    {u1, state} = random_sample(state)
    {u2, state} = random_sample(state)

    x1 = 2.0 * u1 - 1.0
    x2 = 2.0 * u2 - 1.0
    r2 = x1 * x1 + x2 * x2

    if r2 >= 1.0 or r2 == 0.0 do
      polar(state)
    else
      {x1, x2, r2, state}
    end
  end
end
