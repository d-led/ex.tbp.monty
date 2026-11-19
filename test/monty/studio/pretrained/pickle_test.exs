defmodule Monty.Studio.Pretrained.PickleTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Pretrained.Pickle

  # A number a pickle writes in eight bytes, big-endian, after `G`.
  @nan <<0x7F, 0xF8, 0, 0, 0, 0, 0, 0>>
  @infinity <<0x7F, 0xF0, 0, 0, 0, 0, 0, 0>>
  @minus_infinity <<0xFF, 0xF0, 0, 0, 0, 0, 0, 0>>
  @one_and_a_half <<0x3F, 0xF8, 0, 0, 0, 0, 0, 0>>

  # protocol 2, the number, STOP
  defp pickle_of(bits), do: <<0x80, 0x02, 0x47>> <> bits <> <<0x2E>>

  defp read(pickle), do: pickle |> Pickle.non_finite_as_nil() |> Unpickler.load!()

  describe "a number that is a value in Python and no value here" do
    test "reads as nil, which is this port's NaN" do
      assert read(pickle_of(@nan)) == {nil, ""}
    end

    test "reads as nil when it is an infinity, either sign" do
      assert read(pickle_of(@infinity)) == {nil, ""}
      assert read(pickle_of(@minus_infinity)) == {nil, ""}
    end

    test "reads as the number it is when it is one" do
      assert read(pickle_of(@one_and_a_half)) == {1.5, ""}
    end
  end

  describe "a pickle with nothing to translate" do
    test "comes back byte for byte" do
      pickle = pickle_of(@one_and_a_half)

      assert Pickle.non_finite_as_nil(pickle) == pickle
    end
  end

  describe "a value that spells a number but is not one" do
    test "keeps the bytes of a bytes object that begin like a NaN" do
      # `C` short binbytes, nine of them: a NaN's eight bytes after a `G`.
      pickle = <<0x80, 0x02, 0x43, 0x09, 0x47>> <> @nan <> <<0x2E>>

      assert read(pickle) == {<<0x47>> <> @nan, ""}
    end

    test "keeps a text float that is finite" do
      pickle = <<0x80, 0x02, 0x46>> <> "1.5\n" <> <<0x2E>>

      assert Pickle.non_finite_as_nil(pickle) == pickle
    end

    test "reads a text float of nan as nil too" do
      pickle = <<0x80, 0x02, 0x46>> <> "nan\n" <> <<0x2E>>

      assert read(pickle) == {nil, ""}
    end
  end

  describe "a pickle this walk cannot follow" do
    test "is refused rather than guessed at, naming the opcode" do
      assert_raise ArgumentError, ~r/opcode 0xFC/, fn ->
        Pickle.non_finite_as_nil(<<0x80, 0x02, 0xFC, 0x2E>>)
      end
    end

    test "is refused when it ends without a STOP" do
      assert_raise ArgumentError, ~r/without its STOP/, fn ->
        Pickle.non_finite_as_nil(<<0x80, 0x02>>)
      end
    end
  end
end
