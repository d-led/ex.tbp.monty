defmodule Monty.Studio.Pretrained.Tensor do
  @moduledoc """
  A tensor from one of Monty's pickles: a window onto a storage, not the numbers.

  Monty stores a graph's positions and features as `torch.Tensor`s, and in a
  pickle a tensor is a storage of numbers plus an offset, a shape and a stride.
  Keeping that shape rather than expanding it means a row is read when it is
  written out, so a model with hundreds of thousands of nodes never exists here
  as a list of lists.

  Only the two-dimensional case is implemented, because that is what a graph is:
  nodes down the rows, and either three coordinates or one column per feature
  across.
  """

  defstruct type: :f32, count: 0, size: [], strides: [], offset: 0, storage: <<>>

  @typedoc """
  The element types Monty's models store: the numbers of a position or a
  feature, and the integers of an index. Anything else is a model this port
  does not read, and `Monty.Studio.Pretrained.Torch` says so by name rather than
  decoding the bytes as something they are not.
  """
  @type element_type :: :f32 | :f64 | :i32 | :i64 | :u8

  @type t :: %__MODULE__{
          type: element_type(),
          count: non_neg_integer(),
          size: [non_neg_integer()],
          strides: [non_neg_integer()],
          offset: non_neg_integer(),
          storage: binary()
        }

  @doc "The shape of the tensor, rows first."
  @spec shape(t()) :: [non_neg_integer()]
  def shape(%__MODULE__{size: size}), do: size

  @doc "Every row, in order."
  @spec rows(t()) :: [[number()]]
  def rows(%__MODULE__{size: [_rows, columns]} = tensor), do: select(tensor, 0, columns)

  @doc "Columns `first` up to but not including `last`, for every row."
  @spec columns(t(), non_neg_integer(), non_neg_integer()) :: [[number()]]
  def columns(%__MODULE__{size: [_rows, _columns]} = tensor, first, last),
    do: select(tensor, first, last)

  defp select(%__MODULE__{size: [rows, _columns], strides: [row, column]} = tensor, first, last) do
    for index <- 0..(rows - 1)//1 do
      for place <- first..(last - 1)//1, do: at(tensor, index * row + place * column)
    end
  end

  defp at(%__MODULE__{type: type, offset: offset, storage: storage}, index) do
    size = element_size(type)
    decode(type, :binary.part(storage, (offset + index) * size, size))
  end

  @doc "How many bytes one element of this type takes."
  @spec element_size(element_type()) :: pos_integer()
  def element_size(:f64), do: 8
  def element_size(:i64), do: 8
  def element_size(:f32), do: 4
  def element_size(:i32), do: 4
  def element_size(:u8), do: 1

  defp decode(:f32, <<value::little-float-32>>), do: value
  defp decode(:f64, <<value::little-float-64>>), do: value
  defp decode(:i64, <<value::little-signed-64>>), do: value
  defp decode(:i32, <<value::little-signed-32>>), do: value
  defp decode(:u8, <<value::8>>), do: value
end
