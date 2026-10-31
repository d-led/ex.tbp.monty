defmodule Monty.Studio.Png do
  @moduledoc """
  A PNG of pixels this port already has.

  Monty's worlds answer depth, colour and semantic id as images, and a page that
  shows them needs a bitmap. A 64 × 64 frame drawn as SVG is four thousand
  rectangles; drawn as PNG it is a few hundred bytes and the browser does the
  work.

  Only what a frame needs is implemented: 8-bit greyscale (depth) and 8-bit
  colour (rgba), one filter, one deflate stream. `:zlib` and `:erlang.crc32` are
  the standard library, so this is a file format rather than a dependency.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @type rows :: [[number()]]

  @doc """
  A greyscale PNG of `rows`, each a list of values from 0 (black) to 255.

  Depth is drawn this way: one channel, because there is one number per pixel.
  """
  @spec greyscale(rows()) :: binary()
  def greyscale(rows), do: encode(rows, 0, fn value -> <<trunc(value)>> end)

  @doc """
  A colour PNG of `rows`, each a list of `[r, g, b]` from 0 to 255.
  """
  @spec rgb([[[number()]]]) :: binary()
  def rgb(rows), do: encode(rows, 2, fn [r, g, b] -> <<trunc(r), trunc(g), trunc(b)>> end)

  defp encode(rows, colour_type, pixel) do
    height = length(rows)
    width = rows |> List.first() |> length()

    # One filter byte per scanline, "none": the pixels are not decorrelated here,
    # because deflate already finds the runs a depth image is made of.
    raw = for row <- rows, into: <<>>, do: <<0>> <> Enum.into(row, <<>>, pixel)

    [
      @signature,
      chunk("IHDR", <<width::32, height::32, 8, colour_type, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(raw)),
      chunk("IEND", <<>>)
    ]
    |> IO.iodata_to_binary()
  end

  defp chunk(type, data) do
    [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
  end
end
