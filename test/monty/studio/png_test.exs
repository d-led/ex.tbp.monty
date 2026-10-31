defmodule Monty.Studio.PngTest do
  @moduledoc """
  A PNG is checked by reading it back: the format earns its place because a
  browser can decode it, so these tests decode it too.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Png

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  test "a greyscale png carries the size and the pixels" do
    assert %{colour: 0, width: 3, height: 2, pixels: [[10, 20, 30], [40, 50, 60]]} =
             decode(Png.greyscale([[10, 20, 30], [40, 50, 60]]))
  end

  test "a colour png carries three channels per pixel" do
    assert %{colour: 2, width: 2, height: 1, pixels: [[[255, 0, 0], [0, 255, 0]]]} =
             decode(Png.rgb([[[255, 0, 0], [0, 255, 0]]]))
  end

  test "the chunks are the ones a png has, in the order a decoder needs" do
    assert ["IHDR", "IDAT", "IEND"] =
             Png.greyscale([[0, 1], [2, 3]]) |> chunks() |> Enum.map(&elem(&1, 0))
  end

  test "every chunk carries the checksum a decoder checks" do
    for {type, data, crc} <- chunks(Png.greyscale([[0, 1], [2, 3]])) do
      assert crc == :erlang.crc32([type, data]),
             "the #{type} chunk's checksum is #{crc}, which a decoder would reject"
    end
  end

  # -- reading a PNG back ---------------------------------------------------

  defp decode(png) do
    chunks = chunks(png)
    {_type, <<width::32, height::32, 8, colour, 0, 0, 0>>, _crc} = chunk(chunks, "IHDR")

    raw =
      chunks
      |> Enum.filter(&(elem(&1, 0) == "IDAT"))
      |> Enum.map(&elem(&1, 1))
      |> IO.iodata_to_binary()
      |> :zlib.uncompress()

    %{
      colour: colour,
      width: width,
      height: height,
      pixels: scanlines(raw, width, if(colour == 0, do: 1, else: 3), height)
    }
  end

  defp chunk(chunks, type), do: Enum.find(chunks, &(elem(&1, 0) == type))

  defp chunks(<<@signature, rest::binary>>), do: chunks(rest, [])
  defp chunks(<<>>, acc), do: Enum.reverse(acc)

  defp chunks(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>,
         acc
       ) do
    chunks(rest, [{type, data, crc} | acc])
  end

  defp scanlines(_raw, _width, _bytes, 0), do: []

  defp scanlines(raw, width, bytes, height) do
    stride = 1 + width * bytes
    line_size = width * bytes

    for index <- 0..(height - 1) do
      # The first byte of a scanline is its filter, and only "none" is written.
      <<0, line::binary-size(^line_size)>> = binary_part(raw, index * stride, stride)
      pixels(line, bytes)
    end
  end

  defp pixels(<<>>, _bytes), do: []
  defp pixels(<<value, rest::binary>>, 1), do: [value | pixels(rest, 1)]
  defp pixels(<<red, green, blue, rest::binary>>, 3), do: [[red, green, blue] | pixels(rest, 3)]
end
