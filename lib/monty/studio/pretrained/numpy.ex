defmodule Monty.Studio.Pretrained.Numpy do
  @moduledoc """
  A numpy array inside one of Monty's pickles, read without numpy.

  Some of Monty's pretrained models are not torch `Data` graphs: a
  `GridObjectModel` keeps its nodes in a `NumpyGraph`, whose `pos` and `x` are
  plain numpy arrays. A pickle writes one as

      %Object{
        constructor: "numpy._core.multiarray._reconstruct",
        args: [Global{numpy.ndarray}, {0}, "b"],
        state: {1, {rows, columns}, %Object{numpy.dtype, ["f8", false, true]}, fortran?, bytes}
      }

  which is everything `Monty.Studio.Pretrained.Tensor` needs: a shape, an
  element type, and the bytes. `tensor/1` answers that `Tensor`, so the rest of
  the reader — `rows/1`, `columns/1` — reads a numpy-backed graph the way it
  reads a torch-backed one.

  ## Column-major arrays

  numpy stores a Fortran-ordered array column by column. `Tensor` already reads
  through strides rather than assuming row-major, so the order is carried as
  `strides: [1, rows]` instead of `[columns, 1]` and nothing is copied.

  ## What is ignored

  An array that is not numbers — a string label, an object column — is nothing a
  feature row can be read from, so `tensor/1` answers `:error` and the walk keeps
  it as one more object. What is *not* ignored is a numeric array this reader
  cannot decode (`Numpy.number/1`'s answer): that is a model from a release that
  needs adding, and "matches nothing for reasons nobody can see" is the one
  failure worth refusing loudly.
  """

  alias Monty.Studio.Pretrained.Tensor

  @constructors [
    "numpy._core.multiarray._reconstruct",
    # numpy < 2 spells the same function without `_core`.
    "numpy.core.multiarray._reconstruct"
  ]

  # numpy's dtype codes, as `Tensor` reads them.
  @types %{
    "f8" => :f64,
    "f4" => :f32,
    "i8" => :i64,
    "i4" => :i32,
    "u1" => :u8
  }

  @doc "The constructors that mean \"a numpy array\", in either numpy spelling."
  @spec constructors() :: [String.t()]
  def constructors, do: @constructors

  @doc """
  The array as a `Tensor`, or `:error` when this object is not a number array.

  `_reconstruct` builds more than arrays — a numpy scalar, a matrix, the strings
  in a label array — so the state's shape decides. A numeric dtype this reader
  does not know is refused with its code, because a feature column read as
  "absent" is a graph that matches nothing.
  """
  @spec tensor(term()) :: {:ok, Tensor.t()} | :error
  def tensor(%Unpickler.Object{constructor: constructor, state: state})
      when constructor in @constructors do
    case state do
      {_version, shape, %Unpickler.Object{constructor: "numpy.dtype", args: [code | _]}, fortran?,
       bytes}
      when is_binary(bytes) ->
        with {:ok, type} <- type(code) do
          {:ok, tensor(shape, type, fortran?, bytes)}
        end

      _not_an_array ->
        :error
    end
  end

  def tensor(_other), do: :error

  @doc """
  The `Tensor` element type a numpy dtype code stands for.

  `:error` for a dtype that is not a number — nothing reads a string as a
  coordinate — and a refusal for a numeric one this reader has no decoder for.
  """
  @spec type(String.t()) :: {:ok, Tensor.element_type()} | :error
  def type(code) do
    case Map.fetch(@types, code) do
      {:ok, type} ->
        {:ok, type}

      :error ->
        if numeric?(code) do
          raise ArgumentError,
                "a numpy array of #{inspect(code)} is not one this reader decodes: " <>
                  "it knows #{inspect(Map.keys(@types) |> Enum.sort())}"
        else
          :error
        end
    end
  end

  # numpy's dtype codes begin with the kind of number: `f` float, `i` signed,
  # `u` unsigned, `c` complex, `b` boolean. Anything else (`S`, `U`, `O`, `M`)
  # is not a number and cannot be a feature row.
  defp numeric?(<<kind::binary-size(1), _rest::binary>>), do: kind in ~w(f i u c b)
  defp numeric?(_code), do: false

  defp tensor(shape, type, fortran?, bytes) do
    dimensions = dimensions(shape)

    %Tensor{
      type: type,
      count: Enum.reduce(dimensions, 1, &(&1 * &2)),
      size: dimensions,
      strides: strides(dimensions, fortran?),
      offset: 0,
      storage: bytes
    }
  end

  # numpy writes a shape as a tuple, and a one-dimensional array as `{n}`.
  defp dimensions(shape) when is_tuple(shape), do: Tuple.to_list(shape)
  defp dimensions(shape) when is_list(shape), do: shape

  # How far apart consecutive elements are, in elements. Row-major counts a
  # position as one step per dimension to its right; column-major is the same
  # numbers read the other way round. `Tensor` reads through strides either way,
  # so nothing is copied and an array of any rank arrives as it was written.
  defp strides(dimensions, false), do: row_major(dimensions)

  defp strides(dimensions, true),
    do: dimensions |> Enum.reverse() |> row_major() |> Enum.reverse()

  # A dimension's stride is the product of everything to its right, so the last
  # one steps by a single element.
  defp row_major(dimensions) do
    dimensions
    |> Enum.with_index()
    |> Enum.map(fn {_dimension, index} ->
      dimensions |> Enum.drop(index + 1) |> Enum.product()
    end)
  end
end
