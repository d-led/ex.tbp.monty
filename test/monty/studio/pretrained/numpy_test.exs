defmodule Monty.Studio.Pretrained.NumpyTest do
  @moduledoc """
  Reading a numpy array out of one of Monty's pickles.

  No test in Monty: this is the port's own reader, for the releases whose object
  models keep their nodes in a `NumpyGraph` rather than a torch `Data`. These are
  intent tests — they state what such an array has to arrive as, and they are
  what keeps the cows release exportable at all.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Pretrained.{Numpy, Tensor}

  # The state a numpy `_reconstruct` carries: a version, the shape, the dtype
  # object, whether it is column-major, and the bytes.
  defp array(shape, code, bytes, fortran? \\ false) do
    %Unpickler.Object{
      constructor: "numpy._core.multiarray._reconstruct",
      args: [%Unpickler.Global{scope: "numpy", name: "ndarray"}, {0}, "b"],
      kwargs: %{},
      state: {1, shape, dtype(code), fortran?, bytes}
    }
  end

  defp dtype(code) do
    %Unpickler.Object{constructor: "numpy.dtype", args: [code, false, true]}
  end

  @row_major <<1.0::little-float-64, 2.0::little-float-64, 3.0::little-float-64,
               4.0::little-float-64, 5.0::little-float-64, 6.0::little-float-64>>

  describe "tensor/1" do
    test "reads a row-major float array row by row" do
      assert {:ok, tensor} = Numpy.tensor(array({2, 3}, "f8", @row_major))

      assert Tensor.shape(tensor) == [2, 3]
      assert Tensor.rows(tensor) == [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
    end

    test "reads a column-major array the same way, because the strides say where each number is" do
      assert {:ok, tensor} = Numpy.tensor(array({2, 3}, "f8", @row_major, true))

      assert Tensor.rows(tensor) == [[1.0, 3.0, 5.0], [2.0, 4.0, 6.0]]
    end

    test "reads an unsigned byte, which a surface model's flags are stored as" do
      bytes = <<1, 0, 1, 1>>

      assert {:ok, tensor} = Numpy.tensor(array({2, 2}, "u1", bytes))
      assert Tensor.rows(tensor) == [[1, 0], [1, 1]]
    end

    test "leaves a string array to the reader above it, which ignores what is not a number" do
      assert Numpy.tensor(array({2}, "S1", <<"a", "b">>)) == :error
    end

    test "refuses a numeric array it has no decoder for, and says which" do
      error = assert_raise ArgumentError, fn -> Numpy.tensor(array({2}, "f2", <<0, 0, 0, 0>>)) end

      assert error.message =~ "\"f2\""
    end

    test "leaves anything that is not a numpy array alone" do
      assert Numpy.tensor(%Unpickler.Object{constructor: "torch.Size", args: [[2, 3]]}) == :error
    end
  end
end
