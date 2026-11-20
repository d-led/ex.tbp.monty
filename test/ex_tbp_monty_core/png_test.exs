defmodule ExTbpMonty.Core.PngTest do
  # Reading a PNG back. A world that is an image opens Monty's `rgb_*.png` the
  # way `PIL.Image.open` does, so what matters is not that this module can read
  # what it wrote — a capture is written by a photograph's encoder, which picks
  # a filter per scanline — but that it undoes every filter and refuses the
  # files it cannot read.

  use ExUnit.Case, async: true

  alias ExTbpMonty.Core.Png

  # A capture's encoder, not this module's: PIL 12.3 wrote it from an 8 × 6 RGBA
  # gradient with a flat patch and a hard edge, and chose the filters
  # sub, paeth, paeth, up, paeth, paeth — none of which `encode/3` writes. The
  # expected pixels below are the array PIL was given.
  @capture "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAAS0lEQVR4nGNkYGD4L8/NwIAN8ykZMbCw" <>
             "M+gzsDMwYMUggKJg2ecDDAyfIRL79BwYGBiuMDBBFEAwMoDxUUzI550Htx/E/8mwlLAbAFQnDPBhMH" <>
             "51AAAAAElFTkSuQmCC"

  @capture_pixels [
    [
      [0, 0, 0, 255],
      [31, 11, 0, 255],
      [62, 22, 0, 255],
      [93, 33, 0, 255],
      [124, 44, 0, 255],
      [155, 55, 0, 255],
      [186, 66, 0, 255],
      [200, 100, 50, 255]
    ],
    [
      [7, 0, 47, 255],
      [38, 11, 47, 255],
      [69, 22, 47, 255],
      [100, 33, 47, 255],
      [131, 44, 47, 255],
      [162, 55, 47, 255],
      [193, 66, 47, 255],
      [200, 100, 50, 255]
    ],
    [
      [14, 0, 94, 255],
      [45, 11, 94, 255],
      [76, 22, 94, 255],
      [10, 20, 30, 255],
      [10, 20, 30, 255],
      [10, 20, 30, 255],
      [200, 66, 94, 255],
      [200, 100, 50, 255]
    ],
    [
      [21, 0, 141, 255],
      [52, 11, 141, 255],
      [83, 22, 141, 255],
      [10, 20, 30, 255],
      [10, 20, 30, 255],
      [10, 20, 30, 255],
      [207, 66, 141, 255],
      [200, 100, 50, 255]
    ],
    [
      [28, 0, 188, 255],
      [59, 11, 188, 255],
      [90, 22, 188, 255],
      [121, 33, 188, 255],
      [152, 44, 188, 255],
      [183, 55, 188, 255],
      [214, 66, 188, 255],
      [200, 100, 50, 255]
    ],
    [
      [35, 0, 235, 255],
      [66, 11, 235, 255],
      [97, 22, 235, 255],
      [128, 33, 235, 255],
      [159, 44, 235, 255],
      [190, 55, 235, 255],
      [221, 66, 235, 255],
      [200, 100, 50, 255]
    ]
  ]

  # The filter this module never writes: "average". Built with Python's zlib from
  # a 4 × 3 RGB array whose rows each took `(value - (left + up) / 2) mod 256`,
  # so undoing it is not something the encoder could have agreed with by
  # construction.
  @averaged "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAMklEQVR4nAEnANj/AwoUHiMoLTI3PEFG" <>
              "SwP8+PTw6+fi3tnV0MwDyP8xY/8XYv4WYf0VRMoTQ6Xy5WwAAAAASUVORK5CYII="

  @averaged_pixels [
    [[10, 20, 30], [40, 50, 60], [70, 80, 90], [100, 110, 120]],
    [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]],
    [[200, 0, 50], [201, 1, 51], [202, 2, 52], [203, 3, 53]]
  ]

  describe "a PNG this module wrote" do
    test "comes back as the pixels it was given" do
      grey = <<10, 20, 30, 40, 50, 60>>

      assert {:ok, %{width: 3, height: 2, channels: 1, pixels: ^grey}} =
               Png.decode(Png.greyscale_bytes(grey, 3, 2))

      colour = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12>>

      assert {:ok, %{width: 2, height: 2, channels: 3, pixels: ^colour}} =
               Png.decode(Png.rgb_bytes(colour, 2, 2))
    end
  end

  describe "a captured scene" do
    test "is read as the array the encoder was given, whichever filters it chose" do
      assert {:ok, image} = Png.decode(Base.decode64!(@capture))

      assert %{width: 8, height: 6, channels: 4} = image
      assert image.pixels == pixels(@capture_pixels)
    end

    test "is read when a row took the average filter" do
      assert {:ok, image} = Png.decode(Base.decode64!(@averaged))

      assert %{width: 4, height: 3, channels: 3} = image
      assert image.pixels == pixels(@averaged_pixels)
    end
  end

  describe "a file that is not a captured scene" do
    test "is refused rather than guessed at" do
      assert {:error, "not a PNG: the eight-byte signature is missing"} = Png.decode("GIF89a")

      assert {:error, "not a PNG: no header chunk"} = Png.decode(png([]))

      assert {:error, "a 16-bit PNG is not a captured scene"} =
               Png.decode(with_header(<<1::32, 1::32, 16, 0, 0, 0, 0>>))

      assert {:error, "a palette PNG is not a captured scene: it has no pixels of its own"} =
               Png.decode(with_header(<<1::32, 1::32, 8, 3, 0, 0, 0>>))

      assert {:error, "an interlaced PNG is not a captured scene"} =
               Png.decode(with_header(<<1::32, 1::32, 8, 0, 0, 0, 1>>))
    end

    test "says how much of itself is missing" do
      # One 2 × 2 grey picture is 2 rows of (1 filter byte + 2 pixels), so ten
      # bytes: a body of four pixels and no filter bytes is refused by size.
      truncated = with_data(<<2::32, 2::32, 8, 0, 0, 0, 0>>, <<0, 1, 2, 3>>)

      assert {:error, "a 2 × 2 picture is 6 bytes and this one is 4"} = Png.decode(truncated)
    end
  end

  defp pixels(rows),
    do: for(row <- rows, pixel <- row, into: <<>>, do: :erlang.list_to_binary(pixel))

  defp png(chunks), do: <<137, 80, 78, 71, 13, 10, 26, 10>> <> IO.iodata_to_binary(chunks)

  defp with_header(ihdr), do: png([chunk("IHDR", ihdr), chunk("IEND", <<>>)])

  defp with_data(ihdr, raw) do
    png([chunk("IHDR", ihdr), chunk("IDAT", :zlib.compress(raw)), chunk("IEND", <<>>)])
  end

  defp chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
end
