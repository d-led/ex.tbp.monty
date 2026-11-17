defmodule Monty.Prerequisites.Zip do
  @moduledoc """
  Takes chosen members out of a zip without ever holding the archive.

  A zip is built to be read this way: the **central directory** at the end names
  every member, with its compression method, sizes, CRC32 and the offset of its
  local header. So a reader can

    1. fetch the last few kilobytes and find the directory (Zip64 aware),
    2. fetch the directory itself — one ranged read,
    3. fetch only the byte span each wanted member occupies, and inflate it.

  Every member carries its own CRC32, so the integrity check costs nothing extra
  and does not need the rest of the file. That is what turns a 4.3 GB object
  archive into a few tens of megabytes of traffic when seven objects are wanted.

  The bytes come from a **range function** — `(first, last) -> {:ok, binary}` —
  so this module is the format, and HTTP is one caller:

      range = fn first, last ->
        Req.get!(url, headers: [{"range", "bytes=\#{first}-\#{last}"}], decode_body: false).body
      end

  A caller that knows the size passes it: the last byte of the file is where the
  search for the directory starts, and it is also where a member's span stops.
  """

  @eocd_signature 0x06054B50
  @zip64_eocd_signature 0x06064B50
  @central_signature 0x02014B50
  @local_signature 0x04034B50

  # An end-of-central-directory record is 22 bytes plus up to 65535 of comment,
  # and a Zip64 locator and record sit just before it.
  @tail 65_576
  @eocd 22
  @zip64_locator 20
  @zip64_eocd 56
  @local_fixed 30

  # A local header repeats the member's name and extra field, at lengths the
  # central directory does not state. Asking 1 KiB past the data is cheaper than
  # a second request per member, and the extra bytes are never read — the last
  # byte of a request is clamped at the end of the file.
  @local_slack 1024

  @sentinel 0xFFFFFFFF
  @many_entries 0xFFFF

  @type entry :: %{
          name: String.t(),
          method: 0 | 8 | non_neg_integer(),
          crc32: non_neg_integer(),
          compressed_size: non_neg_integer(),
          size: non_neg_integer(),
          offset: non_neg_integer()
        }

  @type directory :: %{
          offset: non_neg_integer(),
          size: non_neg_integer(),
          entries: non_neg_integer()
        }

  @type range :: (non_neg_integer(), non_neg_integer() ->
                    {:ok, binary()} | {:error, term()})

  @doc """
  Where the central directory is, read from the last bytes of a file of `size`.

  `tail` is the end of the file — `min(size, #{@tail})` bytes is more than any
  comment this reads. The answer's `offset` and `size` are absolute.
  """
  @spec locate(binary(), non_neg_integer()) :: {:ok, directory()} | {:error, term()}
  def locate(tail, size) when is_binary(tail) and is_integer(size) do
    with {:ok, at} <- eocd_at(tail),
         {:ok, record} <- eocd_record(tail, at) do
      zip64_or_eocd(tail, at, record)
    end
  end

  @doc "The members a central directory names, in the order the directory holds them."
  @spec entries(binary()) :: {:ok, [entry()]} | {:error, term()}
  def entries(directory) when is_binary(directory), do: parse(directory, [])

  @doc """
  How many bytes a member occupies from its local header to the end of its data.

  The local header's name and extra field are what `#{@local_slack}` covers; a
  range that asks for this span therefore arrives holding the whole member.

  A byte count is an integer, and the entry a caller hands in is one this module
  parsed: an entry whose size arrived as anything else is not an entry, and the
  guard says so rather than returning a span of half a byte.
  """
  @spec span(entry()) :: pos_integer()
  def span(%{compressed_size: compressed}) when is_integer(compressed),
    do: @local_fixed + @local_slack + compressed

  @doc """
  One member's bytes — as they arrived, local header first — inflated and
  checked against the CRC and size the central directory states.
  """
  @spec extract(entry(), binary()) :: {:ok, binary()} | {:error, term()}
  def extract(
        %{name: name, method: method, crc32: crc, compressed_size: compressed, size: size},
        bytes
      ) do
    with {:ok, data} <- member_data(bytes, name, compressed),
         {:ok, inflated} <- inflate(method, data, size),
         :ok <- verified(inflated, crc, size, name) do
      {:ok, inflated}
    end
  end

  @doc """
  Writes every member under one of `wanted` (a name, or a prefix ending in `/`)
  into `into`, and refuses before writing anything if one of them names nothing.

  Answers the paths written. A member whose name would land outside `into` is
  refused rather than normalised into somewhere the caller did not name.
  """
  @spec take(range(), non_neg_integer(), [String.t()], Path.t()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def take(range, size, wanted, into) do
    range = within(range, size)

    with {:ok, tail} <- range.(max(size - @tail, 0), size - 1),
         {:ok, directory} <- locate(tail, size),
         {:ok, bytes} <- range.(directory.offset, directory.offset + directory.size - 1),
         {:ok, entries} <- entries(bytes),
         {:ok, selected} <- selected(entries, wanted) do
      write(selected, range, into)
    end
  end

  # -- the end of the file ----------------------------------------------------

  defp eocd_at(tail) do
    matches =
      tail
      |> :binary.matches(<<@eocd_signature::little-32>>)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&comment_ends_here?(tail, &1))

    case List.last(matches) do
      nil -> {:error, :no_central_directory}
      at -> {:ok, at}
    end
  end

  defp comment_ends_here?(tail, at) do
    case tail do
      <<_::binary-size(^at), @eocd_signature::little-32, _::binary-size(16), comment::little-16,
        _::binary>> ->
        at + @eocd + comment == byte_size(tail)

      _ ->
        false
    end
  end

  defp eocd_record(tail, at) do
    case tail do
      <<_::binary-size(^at), @eocd_signature::little-32, _disk::little-16, _cd_disk::little-16,
        _on_disk::little-16, total::little-16, size::little-32, offset::little-32, _::binary>> ->
        {:ok, %{total: total, size: size, offset: offset}}

      _ ->
        {:error, :truncated_central_directory}
    end
  end

  defp zip64_or_eocd(tail, at, %{offset: @sentinel} = record), do: zip64(tail, at, record)

  defp zip64_or_eocd(tail, at, %{total: @many_entries} = record), do: zip64(tail, at, record)

  defp zip64_or_eocd(_tail, _at, %{offset: offset, size: size, total: total}) do
    {:ok, %{offset: offset, size: size, entries: total}}
  end

  # The Zip64 record ends exactly where its locator begins, and its own size
  # field is 44 plus any extensible data — the minimum is all a writer produces.
  defp zip64(tail, at, _record) when at >= @zip64_locator + @zip64_eocd do
    start = at - @zip64_locator - @zip64_eocd

    case tail do
      <<_::binary-size(^start), @zip64_eocd_signature::little-32, _size::little-64,
        _made::little-16, _needed::little-16, _disk::little-32, _cd_disk::little-32,
        _on_disk::little-64, total::little-64, size::little-64, offset::little-64, _::binary>> ->
        {:ok, %{offset: offset, size: size, entries: total}}

      _ ->
        {:error, :no_zip64_directory}
    end
  end

  defp zip64(_tail, _at, _record), do: {:error, :no_zip64_directory}

  # -- the central directory --------------------------------------------------

  defp parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse(<<@central_signature::little-32, rest::binary>>, acc) do
    with {:ok, member, tail} <- member(rest) do
      parse(tail, [member | acc])
    end
  end

  defp parse(_other, _acc), do: {:error, :not_a_central_directory}

  defp member(binary) do
    case binary do
      <<_made::little-16, _needed::little-16, flags::little-16, method::little-16,
        _time::little-16, _date::little-16, crc::little-32, compressed::little-32,
        size::little-32, name_len::little-16, extra_len::little-16, comment_len::little-16,
        _disk::little-16, _internal::little-16, _external::little-32, offset::little-32,
        name::binary-size(name_len), extra::binary-size(extra_len),
        _comment::binary-size(comment_len), rest::binary>> ->
        with {:ok, name} <- name(name, flags) do
          {size, compressed, offset} = wide(extra, size, compressed, offset)
          {:ok, member(name, method, crc, compressed, size, offset), rest}
        end

      _ ->
        {:error, :truncated_central_directory}
    end
  end

  defp member(name, method, crc, compressed, size, offset) do
    %{
      name: name,
      method: method,
      crc32: crc,
      compressed_size: compressed,
      size: size,
      offset: offset
    }
  end

  # Bit 11 says the name is UTF-8; a name that is not valid says this reader
  # would write a file under a mangled path, which is worse than refusing.
  defp name(name, flags) do
    if String.valid?(name),
      do: {:ok, name},
      else: {:error, {:unsupported_name_encoding, flags, name}}
  end

  # The Zip64 extra field carries, in order, the u64 for each field that did not
  # fit: size first, then compressed size, then the local header's offset.
  defp wide(extra, size, compressed, offset) do
    if Enum.any?([size, compressed, offset], &(&1 == @sentinel)) do
      values = extra |> zip64_field() |> u64s()
      {size, values} = if size == @sentinel, do: take_u64(values, size), else: {size, values}

      {compressed, values} =
        if compressed == @sentinel, do: take_u64(values, compressed), else: {compressed, values}

      {offset, _values} =
        if offset == @sentinel, do: take_u64(values, offset), else: {offset, values}

      {size, compressed, offset}
    else
      {size, compressed, offset}
    end
  end

  defp take_u64([value | rest], _default), do: {value, rest}
  defp take_u64([], default), do: {default, []}

  defp zip64_field(
         <<0x0001::little-16, length::little-16, data::binary-size(length), _::binary>>
       ),
       do: data

  defp zip64_field(<<_id::little-16, length::little-16, _::binary-size(length), rest::binary>>),
    do: zip64_field(rest)

  defp zip64_field(_extra), do: <<>>

  defp u64s(binary), do: for(<<value::little-64 <- binary>>, do: value)

  # -- one member -------------------------------------------------------------

  defp member_data(bytes, name, compressed) do
    case bytes do
      <<@local_signature::little-32, _needed::little-16, _flags::little-16, _method::little-16,
        _time::little-16, _date::little-16, _crc::little-32, _compressed::little-32,
        _size::little-32, name_len::little-16, extra_len::little-16, rest::binary>> ->
        case rest do
          <<stored::binary-size(^name_len), _extra::binary-size(^extra_len), data::binary>> ->
            if stored == name,
              do: {:ok, binary_part(data, 0, min(compressed, byte_size(data)))},
              else: {:error, {:local_header_names_another_member, name}}

          _ ->
            {:error, {:truncated_member, name}}
        end

      _ ->
        {:error, {:truncated_member, name}}
    end
  end

  defp inflate(0, data, size) do
    if byte_size(data) == size,
      do: {:ok, data},
      else: {:error, {:stored_size_mismatch, size, byte_size(data)}}
  end

  defp inflate(8, data, size), do: raw_deflate(data, size)

  defp inflate(method, _data, _size), do: {:error, {:unsupported_compression, method}}

  # A member states its inflated size in the directory, so the output is bounded
  # by that: a stream that inflates to more than it promised is refused at the
  # chunk that crosses the line, not after the heap fills. The input is one the
  # application fetched from a prerequisite's own URL.
  # sobelow_skip ["DOS.Decompression"]
  defp raw_deflate(data, size) do
    port = :zlib.open()

    try do
      :ok = :zlib.inflateInit(port, -15)

      with {:ok, inflated} <- feed(port, data, size) do
        :ok = :zlib.inflateEnd(port)
        {:ok, inflated}
      end
    catch
      kind, reason -> {:error, {:cannot_inflate, kind, reason}}
    after
      :zlib.close(port)
    end
  end

  defp feed(_port, <<>>, _size), do: {:ok, <<>>}

  # The bound is `size`, the inflated size the member's own directory states, and
  # the stop happens at the chunk that crosses it — not after the heap fills.
  # sobelow_skip ["DOS.Decompression"]
  defp feed(port, data, size) do
    data
    |> chunks()
    |> Enum.reduce_while({:ok, [], 0}, fn chunk, {:ok, acc, grown} ->
      out = port |> :zlib.inflate(chunk) |> IO.iodata_to_binary()
      grown = grown + byte_size(out)

      if grown > size,
        do: {:halt, {:error, {:size_mismatch, size, grown}}},
        else: {:cont, {:ok, [out | acc], grown}}
    end)
    |> case do
      {:ok, acc, _grown} -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp chunks(data) do
    Stream.unfold(data, fn
      <<>> ->
        nil

      rest ->
        size = min(byte_size(rest), 65_536)
        {binary_part(rest, 0, size), binary_part(rest, size, byte_size(rest) - size)}
    end)
  end

  defp verified(inflated, crc, size, name) do
    cond do
      byte_size(inflated) != size -> {:error, {:size_mismatch, name, size, byte_size(inflated)}}
      :erlang.crc32(inflated) != crc -> {:error, {:crc_mismatch, name}}
      true -> :ok
    end
  end

  # -- the members that were asked for ---------------------------------------

  defp selected(entries, wanted) do
    chosen =
      Enum.filter(entries, fn entry -> Enum.any?(wanted, &String.starts_with?(entry.name, &1)) end)

    case Enum.reject(wanted, fn prefix ->
           Enum.any?(chosen, &String.starts_with?(&1.name, prefix))
         end) do
      [] -> {:ok, chosen}
      missing -> {:error, {:missing, missing}}
    end
  end

  # The destination is the directory the caller named, and every path below came
  # from `destination/2`, which refuses a member whose name would leave it.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(entries, range, into) do
    root = Path.expand(into)
    File.mkdir_p!(root)

    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, written} ->
      with {:ok, path} <- destination(root, entry.name),
           {:ok, bytes} <- range.(entry.offset, entry.offset + span(entry) - 1),
           {:ok, blob} <- extract(entry, bytes),
           :ok <- File.write(path, blob) do
        {:cont, {:ok, [path | written]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, written} -> {:ok, Enum.reverse(written)}
      error -> error
    end)
  end

  # A member's name is a path the archive chose. `..` or an absolute name would
  # write outside the directory the caller named, so both are refused rather
  # than normalised into something the caller did not ask for — the two checks
  # below are the whole of what makes this path safe.
  # sobelow_skip ["Traversal.FileModule"]
  defp destination(root, name) do
    path = Path.expand(Path.join(root, name))

    if String.starts_with?(path, root <> "/") and not String.contains?(name, "..") do
      case File.mkdir_p(Path.dirname(path)) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, {:cannot_make_room_for, name, reason}}
      end
    else
      {:error, {:outside_the_destination, name}}
    end
  end

  # -- bytes from somewhere ---------------------------------------------------

  # The last byte of a member's span can be past the end of the file, because the
  # span allows for a local header's name and extra field before they are read.
  defp within(range, size) do
    fn first, last -> range.(first, min(last, size - 1)) end
  end
end
