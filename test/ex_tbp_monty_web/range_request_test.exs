defmodule ExTbpMontyWeb.RangeRequestTest do
  # One byte range out of a request's header. What a player sends on every seek,
  # and the arithmetic a video route must get right for a run to be scrubbable.

  use ExUnit.Case, async: true

  alias ExTbpMontyWeb.RangeRequest

  @size 1_000

  test "no range asked for is the whole file" do
    assert RangeRequest.parse([], @size) == :whole
  end

  test "a first and last byte" do
    assert RangeRequest.parse(["bytes=100-199"], @size) == {:ok, 100, 199}
  end

  test "a start with no end runs to the last byte" do
    assert RangeRequest.parse(["bytes=900-"], @size) == {:ok, 900, 999}
  end

  test "a suffix asks for the end of the file" do
    assert RangeRequest.parse(["bytes=-100"], @size) == {:ok, 900, 999}

    # More than the file holds is the whole of it, not an error: a player asks for
    # the tail before it knows how long the file is.
    assert RangeRequest.parse(["bytes=-5000"], @size) == {:ok, 0, 999}
  end

  test "an end past the file is cut to it" do
    assert RangeRequest.parse(["bytes=990-5000"], @size) == {:ok, 990, 999}
  end

  test "a range that begins past the end is the caller's one error" do
    assert RangeRequest.parse(["bytes=1000-1200"], @size) == :unsatisfiable
    assert RangeRequest.parse(["bytes=0-10"], 0) == :unsatisfiable
  end

  test "a request this does not parse is answered with the whole file" do
    assert RangeRequest.parse(["bytes=abc"], @size) == :whole
    assert RangeRequest.parse(["bytes=10-5"], @size) == :whole
    assert RangeRequest.parse(["items=0-10"], @size) == :whole
    assert RangeRequest.parse(["bytes=0-10", "bytes=20-30"], @size) == :whole
  end
end
