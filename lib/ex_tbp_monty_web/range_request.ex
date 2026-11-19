defmodule ExTbpMontyWeb.RangeRequest do
  @moduledoc """
  One byte range out of a request's `range` header.

  A video a page plays is fetched in ranges: a player asks for the first bytes to
  read the file's header, then for the bytes around wherever the reader drags
  the scrubber. `Plug.Static` answers ranges for a directory the endpoint was
  built with; a run's videos are written wherever the deployment says, so this
  route answers them itself — and this is the arithmetic, apart from the
  response that uses it.

  Only what a player sends is understood — `bytes=first-last`, `bytes=first-`,
  `bytes=-suffix` — and the answer says what to do with the request:

    * `{:ok, first, last}` — those bytes, inclusive, as a `206`;
    * `:whole` — no range asked for, or a request this does not parse, so the
      file is sent as it is (`200`), which every player can also cope with;
    * `:unsatisfiable` — a range that starts past the end of the file, which is a
      `416` with the file's size so the player can ask again properly.
  """

  @typedoc """
  What to answer: the bytes `first..last`, the whole file, or nothing.
  """
  @type answer :: {:ok, non_neg_integer(), non_neg_integer()} | :whole | :unsatisfiable

  @doc """
  The range a request asked for, against a file of `size` bytes.

  `headers` is what `Plug.Conn.get_req_header/2` answered — a list, because a
  request may carry more than one header — and more than one range is not a
  request this serves: a multipart range is answered with the whole file, which
  is correct rather than clever.
  """
  @spec parse([String.t()], non_neg_integer()) :: answer()
  def parse(headers, size) do
    case headers do
      ["bytes=" <> requested] -> bounds(requested, size)
      _none_or_several -> :whole
    end
  end

  defp bounds(requested, size) do
    case String.split(requested, "-", parts: 2) do
      ["", suffix] -> from_the_end(suffix, size)
      [first, last] -> from(first, last, size)
      _malformed -> :whole
    end
  end

  # `bytes=-500`: the last five hundred bytes.
  defp from_the_end(suffix, size) do
    case number(suffix) do
      {:ok, length} when length > 0 -> {:ok, max(size - length, 0), size - 1}
      _not_a_length -> :whole
    end
  end

  defp from(first, last, size) do
    with {:ok, first} <- number(first),
         {:ok, finish} <- finish(last, size) do
      # A range that begins at or past the end is the one case a player must be
      # told about: it answers by asking for the file again.
      cond do
        first >= size -> :unsatisfiable
        first > finish -> :whole
        true -> {:ok, first, min(finish, size - 1)}
      end
    else
      _not_a_range -> :whole
    end
  end

  # `bytes=40-` is everything from forty on.
  defp finish("", size), do: {:ok, size - 1}
  defp finish(last, _size), do: number(last)

  defp number(text) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> {:ok, value}
      _not_a_number -> :error
    end
  end
end
