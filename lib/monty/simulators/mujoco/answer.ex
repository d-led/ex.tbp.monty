defmodule Monty.Simulators.Mujoco.Answer do
  @moduledoc """
  The world's answer, read back into the shapes the rest of the application uses.

  `priv/monty_py/world.py` answers three parts: a JSON header, a newline, and the
  bytes of every array the header names — in the order it names them. A 64×64
  depth image crosses as 32 kilobytes of float64 instead of the megabyte of
  decimal text `json.dumps` made of it, and no number here is parsed out of text.

  What comes back is exactly what the JSON used to decode into: nested lists in C
  order, whatever the array's rank. Every reader downstream — the observation
  transforms, the sensor modules, the studio's frames — keeps its shape and its
  arithmetic.
  """

  @typedoc "A decoded answer: its payload, with each array back in nested lists."
  @type answer :: term()

  @array_key "__array__"

  @doc """
  Decodes one answer: the header's payload, with every array back in lists.
  """
  @spec decode(binary()) :: answer()
  def decode(answer) when is_binary(answer) do
    [header, blob] = :binary.split(answer, "\n")
    %{"payload" => payload, "arrays" => arrays} = Jason.decode!(header)

    replace(payload, offsets(arrays), blob)
  end

  # Where each array's bytes begin, and what they hold.
  defp offsets(arrays) do
    {offsets, _total} =
      Enum.map_reduce(arrays, 0, fn %{"dtype" => dtype, "shape" => shape}, at ->
        count = Enum.product(shape)
        size = count * itemsize(dtype)

        {{at, size, count, dtype, shape}, at + size}
      end)

    offsets
  end

  defp replace(%{@array_key => index}, offsets, blob) do
    {at, size, count, dtype, shape} = Enum.at(offsets, index)

    bytes = binary_part(blob, at, size)

    bytes
    |> values(dtype)
    |> same_count(count, dtype)
    |> nest(shape)
  end

  defp replace(map, offsets, blob) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, replace(value, offsets, blob)} end)

  defp replace(list, offsets, blob) when is_list(list),
    do: Enum.map(list, &replace(&1, offsets, blob))

  defp replace(other, _offsets, _blob), do: other

  defp values(binary, "<f8"), do: for(<<value::float-64-little <- binary>>, do: value)
  defp values(binary, "<f4"), do: for(<<value::float-32-little <- binary>>, do: value)
  defp values(binary, "<i8"), do: for(<<value::signed-64-little <- binary>>, do: value)
  defp values(binary, "<i4"), do: for(<<value::signed-32-little <- binary>>, do: value)
  defp values(binary, "<u8"), do: for(<<value::unsigned-64-little <- binary>>, do: value)
  defp values(binary, "<u4"), do: for(<<value::unsigned-32-little <- binary>>, do: value)
  defp values(binary, "|u1"), do: for(<<value::unsigned-8 <- binary>>, do: value)
  defp values(binary, "|i1"), do: for(<<value::signed-8 <- binary>>, do: value)

  # A float that is not finite has no Erlang float to become, and JSON could not
  # have carried one either — `json.dumps` writes `NaN`, which is not JSON and
  # which `Jason` refuses. A comprehension silently *stops* at such a value, so
  # the count the header declares is what keeps a truncated array from being read
  # as a smaller, plausible one.
  defp same_count(values, count, dtype) do
    if length(values) == count do
      values
    else
      raise ArgumentError,
            "the world answered #{length(values)} of #{count} #{dtype} values: a value that is " <>
              "not finite cannot cross this way, and JSON could not have carried it either"
    end
  end

  # `tolist()` nests by the trailing dimensions: a row at a time. The split is
  # by leading dimension, into the list's own tail — `Enum.chunk_every/2` here
  # cost more than the JSON it replaced (a stream and a chunk accumulator per
  # image), which is why this is written out.
  defp nest([value], []), do: value
  defp nest(values, [_only]), do: values

  defp nest(values, [_rows, columns | rest] = shape) do
    rows(values, Enum.product([columns | rest]), shape)
  end

  defp rows([], _per_row, _shape), do: []

  defp rows(values, per_row, shape) do
    {row, rest} = Enum.split(values, per_row)

    [nest(row, tl(shape)) | rows(rest, per_row, shape)]
  end

  # The one place that decides what can cross: an array of any other dtype is
  # refused by name here, before any of its bytes are read.
  defp itemsize("<f8"), do: 8
  defp itemsize("<f4"), do: 4
  defp itemsize("<i8"), do: 8
  defp itemsize("<i4"), do: 4
  defp itemsize("<u8"), do: 8
  defp itemsize("<u4"), do: 4
  defp itemsize("|u1"), do: 1
  defp itemsize("|i1"), do: 1
  defp itemsize(dtype), do: raise(ArgumentError, "an array of #{dtype} has no known width")
end
