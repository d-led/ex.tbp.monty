defmodule Monty.Prerequisites.ZipTest do
  use ExUnit.Case, async: true

  alias Monty.Prerequisites.Zip
  alias Monty.Test.Tmp

  # A zip in memory, made by Erlang's own writer, so the parser is read against
  # a file something else produced rather than against bytes this test invented.
  defp zip(files, options \\ []) do
    {:ok, {_name, bytes}} =
      :zip.create(
        ~c"fixture.zip",
        Enum.map(files, fn {name, text} -> {to_charlist(name), text} end),
        [
          :memory | options
        ]
      )

    bytes
  end

  # Stands in for HTTP: a range over the bytes that remembers what it was asked
  # for, so a test can read both the answer and the traffic that produced it.
  defp source(bytes) do
    fn first, last ->
      Process.put(:ranges, [{first, last} | Process.get(:ranges, [])])
      {:ok, binary_part(bytes, first, last - first + 1)}
    end
  end

  defp ranges, do: Process.get(:ranges, []) |> Enum.reverse()

  describe "taking the members a caller names" do
    setup do
      Process.delete(:ranges)
      :ok
    end

    test "writes only the object asked for, and leaves the rest of the archive unread" do
      bytes =
        zip([
          {"models/047/textured.obj", String.duplicate("a", 4_000)},
          {"models/048/textured.obj", "the cat's mesh"},
          {"models/048/texture_map.png", "the cat's texture"},
          {"models/049/textured.obj", String.duplicate("b", 4_000)}
        ])

      into = Tmp.dir("zip-take")

      assert {:ok, written} = Zip.take(source(bytes), byte_size(bytes), ["models/048/"], into)

      assert written |> Enum.map(&Path.relative_to(&1, into)) |> Enum.sort() == [
               "models/048/texture_map.png",
               "models/048/textured.obj"
             ]

      assert File.read!(Path.join(into, "models/048/textured.obj")) == "the cat's mesh"
      refute File.exists?(Path.join(into, "models/047"))

      # One read for the tail, one for the directory, one per member — and a
      # member's read is its own span, so 047's and 049's bytes never cross.
      assert [{0, _}, {directory_first, _} | members] = ranges()
      assert length(members) == 2
      assert directory_first != 0
      assert Enum.all?(members, &(elem(&1, 0) < directory_first))
    end

    test "a member stored without compression comes out whole" do
      bytes = zip([{"plain.bin", "stored, not deflated"}], [{:uncompress, [~c"plain.bin"]}])
      into = Tmp.dir("zip-stored")

      assert {:ok, [path]} = Zip.take(source(bytes), byte_size(bytes), ["plain.bin"], into)
      assert File.read!(path) == "stored, not deflated"
    end

    test "an id the archive does not hold is refused by name, and nothing is written" do
      bytes = zip([{"models/048/textured.obj", "mesh"}])
      into = Tmp.dir("zip-missing")

      assert {:error, {:missing, ["models/999/"]}} =
               Zip.take(source(bytes), byte_size(bytes), ["models/048/", "models/999/"], into)

      refute File.exists?(Path.join(into, "models"))
    end

    test "a member that would land outside the destination is refused" do
      bytes = zip([{"models/048/../../../escape.txt", "not here"}])
      into = Tmp.dir("zip-escape")

      assert {:error, {:outside_the_destination, _name}} =
               Zip.take(source(bytes), byte_size(bytes), ["models/048/"], into)

      refute File.exists?(Path.join(Path.dirname(into), "escape.txt"))
    end
  end

  describe "a member that arrived wrong" do
    test "a stored member whose bytes changed is refused by its CRC" do
      entry = %{
        name: "a.txt",
        method: 0,
        crc32: :erlang.crc32("abc"),
        compressed_size: 3,
        size: 3,
        offset: 0
      }

      assert {:ok, "abc"} = Zip.extract(entry, local(entry, "abc"))
      assert {:error, {:crc_mismatch, "a.txt"}} = Zip.extract(entry, local(entry, "abd"))
    end

    test "a member that arrived short is named, not inflated" do
      entry = %{name: "a.txt", method: 8, crc32: 0, compressed_size: 9, size: 9, offset: 0}

      assert {:error, {:truncated_member, "a.txt"}} = Zip.extract(entry, <<>>)
    end
  end

  describe "the end of the file" do
    test "a Zip64 directory is found through its own record, not the 32-bit one" do
      zip64 = <<
        0x06064B50::little-32,
        44::little-64,
        45::little-16,
        45::little-16,
        0::little-32,
        0::little-32,
        7::little-64,
        7::little-64,
        4_000::little-64,
        5_000_000::little-64
      >>

      locator = <<0x07064B50::little-32, 0::little-32, 0::little-64, 1::little-32>>

      eocd = <<
        0x06054B50::little-32,
        0::little-16,
        0::little-16,
        0xFFFF::little-16,
        0xFFFF::little-16,
        0xFFFFFFFF::little-32,
        0xFFFFFFFF::little-32,
        0::little-16
      >>

      tail = zip64 <> locator <> eocd

      assert {:ok, %{offset: 5_000_000, size: 4_000, entries: 7}} =
               Zip.locate(tail, byte_size(tail))
    end

    test "a Zip64 member states its sizes past 4 GB" do
      name = "models/048/textured.obj"

      extra =
        <<0x0001::little-16, 24::little-16, 9_000_000_000::little-64, 3_000_000_000::little-64,
          4_100_000_000::little-64>>

      record = <<
        0x02014B50::little-32,
        45::little-16,
        45::little-16,
        0x0800::little-16,
        8::little-16,
        0::little-16,
        0::little-16,
        0xDEADBEEF::little-32,
        0xFFFFFFFF::little-32,
        0xFFFFFFFF::little-32,
        byte_size(name)::little-16,
        byte_size(extra)::little-16,
        0::little-16,
        0::little-16,
        0::little-16,
        0::little-32,
        0xFFFFFFFF::little-32,
        name::binary,
        extra::binary
      >>

      assert {:ok, [entry]} = Zip.entries(record)

      assert %{
               name: ^name,
               size: 9_000_000_000,
               compressed_size: 3_000_000_000,
               offset: 4_100_000_000,
               crc32: 0xDEADBEEF
             } = entry
    end
  end

  # A local header naming `entry`, followed by `data` — what a range returns
  # when it starts at the member's offset.
  defp local(entry, data) do
    name = entry.name

    <<
      0x04034B50::little-32,
      45::little-16,
      0::little-16,
      0::little-16,
      0::little-16,
      0::little-16,
      0::little-32,
      byte_size(data)::little-32,
      byte_size(data)::little-32,
      byte_size(name)::little-16,
      0::little-16,
      name::binary,
      data::binary
    >>
  end
end
