defmodule ExTbpMonty.Core.Png do
  @moduledoc """
  A PNG of pixels this port already has.

  Monty's worlds answer depth, colour and semantic id as images, and a page that
  shows them needs a bitmap. A 64 × 64 frame drawn as SVG is four thousand
  rectangles; drawn as PNG it is a few hundred bytes and the browser does the
  work.

  Only what a frame needs is implemented: 8-bit greyscale (depth) and 8-bit
  colour (rgba), one filter, one deflate stream. `:zlib` and `:erlang.crc32` are
  the standard library, so this is a file format rather than a dependency.

  The other direction is here too (`decode/1`), because a world that is an
  image is opened the way Monty opens it: `PIL.Image.open(rgb_path)` on a
  captured scene and `np.array(...)` of the answer is what an observation's
  `rgba` is. A capture is written by an encoder that chooses a filter per
  scanline, so the decoder undoes all five rather than the one this module
  writes.
  """

  import Bitwise

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  # A one-bit scanline packs eight pixels into a byte, most significant bit
  # first; this is that byte written out as eight pixels of eight bits, which is
  # what a picture of one channel is everywhere else in this module.
  @byte_as_pixels (for byte <- 0..255, into: %{} do
                     pixels =
                       for shift <- 7..0//-1, into: <<>> do
                         case band(byte, 1 <<< shift) do
                           0 -> <<0>>
                           _one -> <<255>>
                         end
                       end

                     {byte, pixels}
                   end)

  @type rows :: [[number()]]

  @typedoc """
  One picture: its shape, and every pixel as `channels` bytes, row by row.
  """
  @type image :: %{
          width: pos_integer(),
          height: pos_integer(),
          channels: 1 | 2 | 3 | 4,
          pixels: binary()
        }

  @doc """
  A greyscale PNG of `rows`, each a list of values from 0 (black) to 255.

  Depth is drawn this way: one channel, because there is one number per pixel.
  """
  @spec greyscale(rows()) :: binary()
  def greyscale(rows), do: encode(rows, 0, fn value -> <<trunc(value)>> end)

  @doc """
  The same picture from the bytes a decoder hands back: `width` × `height` grey
  values, row by row, with no list in between.
  """
  @spec greyscale_bytes(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def greyscale_bytes(bytes, width, height), do: encode_bytes(bytes, width, height, 0, 1)

  @doc """
  The same picture from RGB bytes, three a pixel.
  """
  @spec rgb_bytes(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def rgb_bytes(bytes, width, height), do: encode_bytes(bytes, width, height, 2, 3)

  @doc """
  A colour PNG of `rows`, each a list of `[r, g, b]` from 0 to 255.
  """
  @spec rgb([[[number()]]]) :: binary()
  def rgb(rows), do: encode(rows, 2, fn [r, g, b] -> <<trunc(r), trunc(g), trunc(b)>> end)

  @doc """
  The pixels of a PNG, from the file's bytes.

  A scene capture is a photograph's PNG, not this module's: written by an
  encoder that picks a filter per scanline. All five filters are undone here,
  because a photograph is where the other four appear.

  What is read is what a world's picture is — greyscale, greyscale-with-alpha,
  colour or colour-with-alpha, one image and not interlaced, and a channel of
  eight bits or of one. One bit is the Omniglot characters: a drawing is ink or
  no ink, and the file spends a bit a pixel on it. It is read out as eight bits
  a pixel, 0 or 255, so that a caller has one shape to handle.

  Anything else is refused with the reason, since a palette, a two-bit or a
  sixteen-bit file decoded into a guess would be a different picture from the one
  Monty saw.
  """
  @spec decode(binary()) :: {:ok, image()} | {:error, String.t()}
  def decode(<<@signature, chunks::binary>>), do: chunks(chunks, nil, [])

  def decode(_bytes),
    do: {:error, "not a PNG: the eight-byte signature is missing"}

  defp chunks(<<size::32, "IHDR", data::binary-size(size), _crc::32, rest::binary>>, nil, idat) do
    with {:ok, header} <- header(data), do: chunks(rest, header, idat)
  end

  defp chunks(<<size::32, "IDAT", data::binary-size(size), _crc::32, rest::binary>>, header, idat) do
    chunks(rest, header, [idat, data])
  end

  defp chunks(<<0::32, "IEND", _crc::32, _rest::binary>>, header, idat)
       when not is_nil(header) do
    image(header, IO.iodata_to_binary(idat))
  end

  # A chunk with no use here — the colour profile a camera writes, the text PIL
  # leaves — and the checksum is over bytes this port does not answer with.
  defp chunks(
         <<size::32, _type::binary-size(4), _data::binary-size(size), _crc::32, rest::binary>>,
         header,
         idat
       ) do
    chunks(rest, header, idat)
  end

  defp chunks(<<>>, nil, _idat), do: {:error, "not a PNG: no header chunk"}

  defp chunks(<<>>, _header, _idat),
    do: {:error, "the file stops before its last chunk, so its pixels are not complete"}

  defp header(
         <<width::32, height::32, depth::8, colour::8, compression::8, filter::8, interlace::8>>
       ) do
    with {:ok, channels} <- channels(colour),
         :ok <- bit_depth(depth, colour),
         :ok <- one_image(interlace),
         :ok <- one_method(compression, filter) do
      {:ok, %{width: width, height: height, channels: channels, depth: depth}}
    end
  end

  defp bit_depth(depth, _colour) when depth in [8], do: :ok

  # A drawing has two colours, and PNG keeps one bit a pixel for it. The other
  # narrow widths (two and four bits, for a greyscale ramp) name no picture here.
  defp bit_depth(1, 0), do: :ok

  defp bit_depth(depth, _colour),
    do: {:error, "a #{depth}-bit PNG is not a picture this port reads"}

  defp channels(0), do: {:ok, 1}
  defp channels(2), do: {:ok, 3}
  defp channels(4), do: {:ok, 2}
  defp channels(6), do: {:ok, 4}

  defp channels(3),
    do: {:error, "a palette PNG is not a picture this port reads: it has no pixels of its own"}

  defp channels(type), do: {:error, "the colour type #{type} is not one PNG defines"}

  defp one_image(0), do: :ok

  defp one_image(_interlaced),
    do: {:error, "an interlaced PNG is not a picture this port reads"}

  defp one_method(0, 0), do: :ok

  defp one_method(compression, filter),
    do: {:error, "the compression #{compression} and filter #{filter} are not PNG's own"}

  defp image(%{width: width, height: height, channels: channels, depth: depth}, compressed) do
    stride = stride(width, channels, depth)
    bpp = max(1, div(channels * depth, 8))
    expected = height * (stride + 1)

    with {:ok, raw} <- inflate(compressed),
         :ok <- whole_rows(raw, expected, width, height),
         {:ok, pixels} <- unfilter(raw, stride, bpp, :binary.copy(<<0>>, stride), []),
         {:ok, pixels} <- as_bytes(pixels, depth, stride, width) do
      {:ok, %{width: width, height: height, channels: channels, pixels: pixels}}
    end
  end

  # A scanline is a whole number of bytes, so a picture narrower than a multiple
  # of eight pixels carries padding bits its width says are not pixels.
  defp stride(width, channels, depth), do: div(width * channels * depth + 7, 8)

  defp as_bytes(pixels, 8, _stride, _width), do: {:ok, pixels}

  defp as_bytes(pixels, 1, stride, width) do
    row_size = stride

    expanded =
      for <<row::binary-size(^row_size) <- pixels>>, into: <<>> do
        binary_part(for(<<byte <- row>>, into: <<>>, do: @byte_as_pixels[byte]), 0, width)
      end

    {:ok, expanded}
  end

  defp as_bytes(_pixels, depth, _stride, _width),
    do: {:error, "a #{depth}-bit PNG is not a picture this port reads"}

  defp inflate(compressed) do
    {:ok, :zlib.uncompress(compressed)}
  rescue
    ErlangError -> {:error, "the pixel data is not a deflate stream"}
  end

  defp whole_rows(raw, expected, _width, _height) when byte_size(raw) == expected, do: :ok

  defp whole_rows(raw, expected, width, height),
    do:
      {:error,
       "a #{width} × #{height} picture is #{expected} bytes and this one is #{byte_size(raw)}"}

  defp unfilter(<<>>, _stride, _bpp, _previous, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp unfilter(<<filter, rest::binary>>, stride, bpp, previous, acc)
       when filter <= 4 and byte_size(rest) >= stride do
    row = binary_part(rest, 0, stride)
    rest = binary_part(rest, stride, byte_size(rest) - stride)
    decoded = undo(filter, row, previous, bpp)
    unfilter(rest, stride, bpp, decoded, [decoded | acc])
  end

  defp unfilter(<<filter, _rest::binary>>, _stride, _bpp, _previous, _acc),
    do: {:error, "the row filter #{filter} is not one of PNG's five"}

  defp undo(0, row, _previous, _bpp), do: row

  defp undo(filter, row, previous, bpp) do
    filter
    |> restore(:binary.bin_to_list(row), :binary.bin_to_list(previous), bpp, 0, [])
    |> :erlang.list_to_binary()
  end

  defp restore(_filter, [], _above, _bpp, _index, out), do: Enum.reverse(out)

  defp restore(filter, [value | rest], above, bpp, index, out) do
    left = if index >= bpp, do: Enum.at(out, bpp - 1), else: 0
    up = Enum.at(above, index)
    upper_left = if index >= bpp, do: Enum.at(above, index - bpp), else: 0

    byte = band(value + predictor(filter, left, up, upper_left), 0xFF)
    restore(filter, rest, above, bpp, index + 1, [byte | out])
  end

  defp predictor(0, _left, _up, _upper_left), do: 0
  defp predictor(1, left, _up, _upper_left), do: left
  defp predictor(2, _left, up, _upper_left), do: up
  defp predictor(3, left, up, _upper_left), do: div(left + up, 2)
  defp predictor(4, left, up, upper_left), do: paeth(left, up, upper_left)

  # PNG's own choice: whichever neighbour the bytes came closest to predicting.
  defp paeth(left, up, upper_left) do
    estimate = left + up - upper_left
    to_left = abs(estimate - left)
    to_up = abs(estimate - up)
    to_corner = abs(estimate - upper_left)

    cond do
      to_left <= to_up and to_left <= to_corner -> left
      to_up <= to_corner -> up
      true -> upper_left
    end
  end

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

  # The same encoding, with the filter bytes placed rather than built row by
  # row: this is the shape a decoded frame arrives in.
  defp encode_bytes(bytes, width, height, colour_type, pixel_size) do
    stride = width * pixel_size

    raw =
      for row <- 0..(height - 1), into: <<>> do
        <<0>> <> binary_part(bytes, row * stride, stride)
      end

    [
      @signature,
      chunk("IHDR", <<width::32, height::32, 8, colour_type, 0, 0, 0>>),
      chunk("IDAT", :zlib.compress(raw)),
      chunk("IEND", <<>>)
    ]
    |> IO.iodata_to_binary()
  end
end
