defmodule Monty.Studio.Pretrained.Pickle do
  @moduledoc """
  A pickle with its non-finite numbers written as `nil`.

  BEAM has no NaN and no infinity: `<<value::float-64>>` does not match those
  bit patterns, so a pickle that carries one stops the reader at that byte. The
  v11 compositional models do carry them — a grid cell no child module
  contributed to is `NaN` — and Python, where that value is ordinary, saves it
  as one.

  `nil` is this port's NaN (`docs/monty-differences.md` §2.33), so the
  translation is the one the rest of the application already makes: a value
  Monty holds as `NaN` is a value this port holds as `nil`.

  The stream is walked opcode by opcode, not searched for bytes. A `BINFLOAT`
  opcode's byte appears inside tensor storages too — those are the numbers this
  read exists for — and rewriting one would corrupt them. An opcode this table
  does not know is an error, never a guess.
  """

  # The opcodes this walk cares about by name; everything else is stepped with
  # its operand length and copied.
  @stop 0x2E
  @none 0x4E
  @binfloat 0x47
  @float 0x46

  # Opcodes followed by a fixed number of operand bytes.
  @one_byte [0x80, 0x71, 0x68, 0x82, 0x4B]
  @two_bytes [0x83, 0x4D]
  @four_bytes [0x4A, 0x72, 0x6A, 0x84]
  @eight_bytes [0x95]

  # Opcodes followed by a length (of the given width) and then that many bytes.
  @sized_one_byte [0x43, 0x55, 0x8C, 0x8A]
  @sized_four_bytes [0x42, 0x54, 0x58, 0x8B]
  @sized_eight_bytes [0x8D, 0x8E, 0x96]

  # Opcodes followed by text up to a newline. `GLOBAL` and `INST` carry two.
  @text [0x70, 0x67, 0x56, 0x53, 0x49, 0x50]
  @two_lines [0x63, 0x69]

  # Opcodes with no operand at all: MARK, POP, POP_MARK, DUP, NONE,
  # EMPTY_TUPLE, EMPTY_LIST, EMPTY_DICT, EMPTY_SET, APPEND, APPENDS, SETITEM,
  # SETITEMS, DICT, LIST, OBJ, TUPLE, the TUPLE1-3 shorthands, FROZENSET,
  # NEWTRUE, NEWFALSE, NEWOBJ, NEWOBJ_EX, STACK_GLOBAL, MEMOIZE, REDUCE,
  # BINPERSID and the buffer opcodes.
  @bare [
    0x28,
    0x29,
    0x30,
    0x31,
    0x32,
    0x4E,
    0x51,
    0x52,
    0x5D,
    0x61,
    0x62,
    0x64,
    0x65,
    0x6C,
    0x6F,
    0x73,
    0x74,
    0x75,
    0x7D,
    0x81,
    0x85,
    0x86,
    0x87,
    0x88,
    0x89,
    0x8F,
    0x90,
    0x91,
    0x92,
    0x93,
    0x94,
    0x97,
    0x98
  ]

  @doc """
  The pickle with every non-finite number replaced by `None`.

  A pickle that is already free of them comes back byte for byte, which is what
  every model this port read before v11 is.
  """
  @spec non_finite_as_nil(binary()) :: binary()
  def non_finite_as_nil(pickle) when is_binary(pickle), do: step(pickle, [])

  defp step(<<@stop, rest::binary>>, acc),
    do: IO.iodata_to_binary([Enum.reverse(acc), <<@stop>>, rest])

  defp step(<<@binfloat, bits::binary-size(8), rest::binary>>, acc) do
    if finite?(bits),
      do: step(rest, [<<@binfloat, bits::binary>> | acc]),
      else: step(rest, [<<@none>> | acc])
  end

  # A text float is not a torch pickle's way of writing a number, but it is a
  # pickle's, and `String.to_float/1` has no answer for "nan" either.
  defp step(<<@float, rest::binary>>, acc) do
    {text, rest} = read_line(rest)

    if text in ~w(nan inf -inf infinity -infinity),
      do: step(rest, [<<@none>> | acc]),
      else: step(rest, [[<<@float>>, text, "\n"] | acc])
  end

  defp step(<<opcode, rest::binary>>, acc) do
    {operand, rest} = operands(opcode, rest)
    step(rest, [<<opcode, operand::binary>> | acc])
  end

  defp step(<<>>, _acc),
    do: raise(ArgumentError, "the pickle ended without its STOP opcode")

  # Exponent bits all ones is NaN or an infinity; BEAM reads neither as a float.
  defp finite?(<<_sign::1, exponent::11, _mantissa::52>>), do: exponent != 0x7FF

  defp operands(opcode, rest) when opcode in @one_byte, do: take(rest, 1)
  defp operands(opcode, rest) when opcode in @two_bytes, do: take(rest, 2)
  defp operands(opcode, rest) when opcode in @four_bytes, do: take(rest, 4)
  defp operands(opcode, rest) when opcode in @eight_bytes, do: take(rest, 8)

  defp operands(opcode, rest) when opcode in @sized_one_byte, do: take_sized(rest, 1)
  defp operands(opcode, rest) when opcode in @sized_four_bytes, do: take_sized(rest, 4)
  defp operands(opcode, rest) when opcode in @sized_eight_bytes, do: take_sized(rest, 8)

  defp operands(opcode, rest) when opcode in @text, do: take_lines(rest, 1)
  defp operands(opcode, rest) when opcode in @two_lines, do: take_lines(rest, 2)

  defp operands(opcode, rest) when opcode in @bare, do: {<<>>, rest}

  defp operands(opcode, _rest) do
    raise ArgumentError,
          "pickle opcode 0x#{Integer.to_string(opcode, 16)} is not one this reader knows"
  end

  defp take(rest, count) do
    case rest do
      <<operand::binary-size(^count), rest::binary>> -> {operand, rest}
      _short -> raise ArgumentError, "the pickle ended inside an opcode's operand"
    end
  end

  defp take_sized(rest, width) do
    {length_bytes, rest} = take(rest, width)
    {payload, rest} = take(rest, length_of(length_bytes))
    {<<length_bytes::binary, payload::binary>>, rest}
  end

  defp length_of(bytes), do: :binary.decode_unsigned(bytes, :little)

  defp take_lines(rest, lines) do
    {operand, rest} =
      Enum.reduce(1..lines, {[], rest}, fn _line, {parts, rest} ->
        {text, rest} = read_line(rest)
        {[[text, "\n"] | parts], rest}
      end)

    {operand |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp read_line(rest) do
    case :binary.split(rest, "\n") do
      [line, rest] -> {line, rest}
      _unterminated -> raise ArgumentError, "the pickle ended inside a line of text"
    end
  end
end
