# Which way to turn a column of f64 bytes back into Elixir values, measured.
#
# The profile says `ExTbpMonty.MatcherNif.decode/1` is the largest single
# allocator in a step (18 % of it). Three ways to do the same thing, on the same
# bytes, with the same answer.
#
#     MIX_ENV=test mix run scripts/probe_decode.exs

defmodule ProbeDecode do
  import Bitwise

  @count 6_432
  @repeats 200

  @exponent_mask 0x7FF0_0000_0000_0000
  @significand_mask 0x000F_FFFF_FFFF_FFFF
  @high_exponent_mask 0x7FF0_0000
  @high_significand_mask 0x000F_FFFF
  @nan 0x7FF8_0000_0000_0000

  @doc "A column shaped like a step's evidence: values, and a NaN every 97th."
  def column do
    for index <- 0..(@count - 1), into: <<>> do
      case rem(index, 97) do
        0 -> <<@nan::unsigned-64-little>>
        _ -> <<(index * 0.37 - 120.0) * 1.0::float-64-little>>
      end
    end
  end

  @doc """
  What the module does now: one 64-bit integer per element, which is a bignum
  for most bit patterns, then a temporary binary to read the float out of.
  """
  def as_is(binary) do
    for <<bits::unsigned-64-little <- binary>> do
      if nan?(bits) do
        nil
      else
        <<value::float-64-little>> = <<bits::unsigned-64-little>>
        value
      end
    end
  end

  @doc "The same two tests, on two 32-bit halves — both small integers."
  def two_halves(binary) do
    for <<bits::unsigned-64-little <- binary>> do
      low = band(bits, 0xFFFF_FFFF)
      high = bsr(bits, 32)

      if nan?(high, low) do
        nil
      else
        <<value::float-64-little>> = <<bits::unsigned-64-little>>
        value
      end
    end
  end

  @doc """
  An eight-byte window per element, read as two halves and, when it is a
  number, as the float itself — no integer of the whole word, no temporary
  binary.
  """
  def window(binary) do
    for <<window::binary-size(8) <- binary>> do
      <<low::unsigned-32-little, high::unsigned-32-little>> = window

      if nan?(high, low) do
        nil
      else
        <<value::float-64-little>> = window
        value
      end
    end
  end

  @doc "The float comprehension alone — the floor, and it stops silently at a NaN."
  def floats_only(binary), do: for(<<value::float-64-little <- binary>>, do: value)

  defp nan?(bits) do
    band(bits, @exponent_mask) == @exponent_mask and band(bits, @significand_mask) != 0
  end

  defp nan?(high, low) do
    band(high, @high_exponent_mask) == @high_exponent_mask and
      (band(high, @high_significand_mask) != 0 or low != 0)
  end

  @doc "The native decoder: one pass over the column, the NaN test the float's own."
  def native(binary), do: ExTbpMonty.Core.MatcherNif.decode_native(binary)

  def measure(name, fun, column) do
    fun.(column)
    :erlang.garbage_collect()

    {_gcs, words_before, _} = :erlang.statistics(:garbage_collection)
    {microseconds, _} = :timer.tc(fn -> for _ <- 1..@repeats, do: fun.(column) end)
    {_gcs, words_after, _} = :erlang.statistics(:garbage_collection)

    :io.format("~-14s ~8.1f us per column   ~6.1f words per value~n", [
      name,
      microseconds / @repeats,
      (words_after - words_before) / @repeats / @count
    ])
  end
end

column = ProbeDecode.column()

IO.puts("one column: #{div(byte_size(column), 8)} values, a NaN in every 97th\n")
ProbeDecode.measure("as_is", &ProbeDecode.as_is/1, column)
ProbeDecode.measure("two_halves", &ProbeDecode.two_halves/1, column)
ProbeDecode.measure("window", &ProbeDecode.window/1, column)
ProbeDecode.measure("native", &ProbeDecode.native/1, column)
ProbeDecode.measure("floats_only", &ProbeDecode.floats_only/1, column)

IO.puts("""

floats_only answers #{length(ProbeDecode.floats_only(column))} of \
#{div(byte_size(column), 8)} values — it stops at the first NaN, which is why it \
cannot be the answer on its own.
""")
