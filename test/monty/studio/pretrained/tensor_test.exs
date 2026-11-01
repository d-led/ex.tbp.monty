defmodule Monty.Studio.Pretrained.TensorTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Pretrained.Tensor

  # A tensor as a pickle has it: numbers in one storage, plus where the first
  # one is and how the rest are laid out.
  defp tensor(numbers, size, strides, offset \\ 0) do
    storage = for number <- numbers, into: <<>>, do: <<number::little-float-32>>

    %Tensor{
      type: :f32,
      count: length(numbers),
      size: size,
      strides: strides,
      offset: offset,
      storage: storage
    }
  end

  describe "a two-dimensional tensor" do
    test "says its shape, rows first" do
      assert Tensor.shape(tensor([1.0, 2.0, 3.0, 4.0], [2, 2], [2, 1])) == [2, 2]
    end

    test "reads every row in order" do
      assert tensor([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], [2, 3], [3, 1]) |> Tensor.rows() ==
               [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
    end

    test "reads a window of columns, which is what one feature is" do
      tensor = tensor([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], [2, 3], [3, 1])

      assert Tensor.columns(tensor, 1, 3) == [[2.0, 3.0], [5.0, 6.0]]
    end

    test "starts where the offset says, not at the beginning of the storage" do
      # A storage shared by two tensors: the second starts one number in.
      assert tensor([9.0, 1.0, 2.0, 3.0, 4.0], [2, 2], [2, 1], 1) |> Tensor.rows() ==
               [[1.0, 2.0], [3.0, 4.0]]
    end

    test "follows the stride, so a column-major tensor reads correctly too" do
      # The same six numbers laid out down the columns rather than across the
      # rows: element (row, column) is storage[row + 2 * column].
      assert tensor([1.0, 2.0, 3.0, 4.0, 5.0, 6.0], [2, 3], [1, 2]) |> Tensor.rows() ==
               [[1.0, 3.0, 5.0], [2.0, 4.0, 6.0]]
    end

    test "answers nothing for a tensor with no rows" do
      assert tensor([], [0, 3], [3, 1]) |> Tensor.rows() == []
    end
  end

  describe "the numbers inside a storage" do
    test "are read as the type says, not as bytes" do
      assert %Tensor{type: :i64, storage: <<7::little-signed-64>>}
             |> then(&%{&1 | size: [1, 1], strides: [1, 1]})
             |> Tensor.rows() ==
               [[7]]
    end

    test "are read at the width the type has, so a double is not a float" do
      # 0.1 as a double is a different number from 0.1 as a float, and the
      # width is the whole of what says which one a storage holds.
      assert %Tensor{type: :f64, size: [1, 1], strides: [1, 1], storage: <<0.1::little-float-64>>}
             |> Tensor.rows() == [[0.1]]
    end
  end
end
