defmodule Monty.Geometry.LinearAlgebra do
  @moduledoc """
  The linear algebra Monty's sensors ask numpy for.

  A sensor module fits a plane and then a quadric to a patch of points, which in
  Python is `np.linalg.solve` and `np.linalg.eig`
  (`frameworks/utils/sensor_processing.py`). There is no numpy here, and the fits
  are small — three to six unknowns — so this module carries the three routines
  those fits need and nothing else:

    * `solve/2` — Gaussian elimination with partial pivoting;
    * `symmetric_eigen/1` — Jacobi rotations, for a real symmetric matrix;
    * `eigen_2x2/1` — the closed form for a two-by-two matrix, which is what a
      shape operator is.

  Nothing here is ported from Monty: Monty calls numpy, and this is the part of
  numpy it calls. Matrices are row-major lists, the same shape the rest of this
  port writes them in.
  """

  @typedoc "A row-major matrix."
  @type matrix :: [[float()]]

  # A pivot smaller than this fraction of the matrix's largest entry is a matrix
  # that has no solution to give.
  @pivot_tolerance 1.0e-12
  @eigen_tolerance 1.0e-14
  @max_sweeps 64

  @doc """
  The vector `x` that solves `matrix · x = vector`, or `:singular`.

  Gaussian elimination with partial pivoting: at each column the row with the
  largest entry is moved into place, so a small pivot is only ever used when the
  matrix genuinely has none bigger. `:singular` is answered rather than `NaN`s.
  """
  @spec solve([[number()]], [number()]) :: {:ok, [float()]} | :singular
  def solve(matrix, vector) do
    augmented =
      Enum.zip_with([matrix, vector], fn [row, value] ->
        Enum.map(row, &(&1 * 1.0)) ++ [value * 1.0]
      end)

    case eliminate(augmented, 0, tolerance(augmented)) do
      :singular -> :singular
      upper -> {:ok, substitute(upper)}
    end
  end

  @doc """
  The eigenvalues and eigenvectors of a real symmetric matrix, ascending.

  Jacobi rotations: each pass zeroes the largest off-diagonal entry by turning
  the matrix in its plane, and the turning is accumulated into the identity to
  leave the eigenvectors as its columns. Ascending order is this module's
  choice, not numpy's; callers that want the smallest or largest say so.
  """
  @spec symmetric_eigen([[number()]]) :: [{float(), [float()]}]
  def symmetric_eigen(matrix) do
    count = length(matrix)
    {values, vectors} = sweep(matrix, identity(count), 0, count, eigen_tolerance(matrix))

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> {value, column(vectors, index)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  The eigenvalues and eigenvectors of a two-by-two matrix, largest first.

  The characteristic quadratic `λ² − tr λ + det = 0` solved in closed form, then
  a null vector for each root. A shape operator is two-by-two, symmetric up to
  rounding, and its eigenvalues order the principal curvatures — Monty sorts
  them largest first, so this does too.
  """
  @spec eigen_2x2([[number()]]) :: [{float(), [float()]}]
  def eigen_2x2([[a, b], [c, d]]) do
    trace = a + d
    determinant = a * d - b * c
    root = :math.sqrt(max(trace * trace / 4.0 - determinant, 0.0))
    largest = trace / 2.0 + root

    # A repeated eigenvalue leaves every direction in the plane an eigenvector —
    # which is what a sphere's shape operator is — and the two are answered as
    # the standard basis, orthonormal, as numpy answers them.
    if root <= 1.0e-12 * max(abs(largest), 1.0) do
      [{largest, [1.0, 0.0]}, {largest, [0.0, 1.0]}]
    else
      [largest, trace / 2.0 - root]
      |> Enum.map(fn value -> {value, null_vector([[a - value, b], [c, d - value]])} end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
    end
  end

  @doc "The `count`×`count` identity matrix."
  @spec identity(pos_integer()) :: matrix()
  def identity(count) do
    for row <- 0..(count - 1) do
      for column <- 0..(count - 1), do: if(row == column, do: 1.0, else: 0.0)
    end
  end

  # -- solving ---------------------------------------------------------------

  defp eliminate(rows, index, tolerance) do
    if index == length(rows) do
      rows
    else
      pivot = Enum.max_by(index..(length(rows) - 1), &abs(value(rows, &1, index)))

      if abs(value(rows, pivot, index)) <= tolerance do
        :singular
      else
        rows
        |> swap(index, pivot)
        |> eliminate_below(index)
        |> then(&eliminate(&1, index + 1, tolerance))
      end
    end
  end

  defp eliminate_below(rows, index) do
    pivot_row = Enum.at(rows, index)
    pivot = Enum.at(pivot_row, index)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, every} ->
      if every <= index, do: row, else: subtract(row, pivot_row, Enum.at(row, index) / pivot)
    end)
  end

  defp subtract(row, pivot_row, factor) do
    Enum.zip_with([row, pivot_row], fn [value, pivot_value] -> value - factor * pivot_value end)
  end

  defp substitute(rows) do
    count = length(rows)

    solved =
      for index <- (count - 1)..0//-1, reduce: %{} do
        solved ->
          row = Enum.at(rows, index)

          known =
            Enum.sum(
              for column <- (index + 1)..(count - 1)//1,
                  do: Enum.at(row, column) * Map.fetch!(solved, column)
            )

          Map.put(solved, index, (Enum.at(row, count) - known) / Enum.at(row, index))
      end

    for index <- 0..(count - 1), do: Map.fetch!(solved, index)
  end

  defp swap(rows, index, index), do: rows

  defp swap(rows, index, pivot) do
    rows
    |> List.replace_at(index, Enum.at(rows, pivot))
    |> List.replace_at(pivot, Enum.at(rows, index))
  end

  # -- eigendecomposition ----------------------------------------------------

  defp sweep(matrix, vectors, round, count, tolerance) when round < @max_sweeps do
    if largest_off_diagonal(matrix, count) <= tolerance do
      {diagonal(matrix), vectors}
    else
      {matrix, vectors} =
        for first <- 0..(count - 1),
            second <- (first + 1)..(count - 1)//1,
            reduce: {matrix, vectors} do
          {matrix, vectors} -> rotate(matrix, vectors, first, second, count)
        end

      sweep(matrix, vectors, round + 1, count, tolerance)
    end
  end

  defp sweep(matrix, vectors, _round, _count, _tolerance), do: {diagonal(matrix), vectors}

  defp rotate(matrix, vectors, first, second, count) do
    off_diagonal = value(matrix, first, second)

    if off_diagonal == 0.0 do
      {matrix, vectors}
    else
      diagonal_first = value(matrix, first, first)
      diagonal_second = value(matrix, second, second)
      {sine, cosine} = rotation(off_diagonal, diagonal_first, diagonal_second)

      matrix =
        matrix
        |> rotate_rows(first, second, count, sine, cosine)
        |> put(first, first, diagonal_first - tangent(sine, cosine) * off_diagonal)
        |> put(second, second, diagonal_second + tangent(sine, cosine) * off_diagonal)
        |> put(first, second, 0.0)
        |> put(second, first, 0.0)

      {matrix, rotate_columns(vectors, first, second, count, sine, cosine)}
    end
  end

  # The turn that zeroes `|off|`: `t = tan θ` is the smaller root of
  # `t² + 2τt − 1 = 0` with `τ = (b − a) / (2·off)`, which keeps the rotation
  # within an eighth of a turn.
  defp rotation(off_diagonal, first, second) do
    tau = (second - first) / (2.0 * off_diagonal)

    tangent =
      if tau >= 0.0,
        do: 1.0 / (tau + :math.sqrt(1.0 + tau * tau)),
        else: -1.0 / (-tau + :math.sqrt(1.0 + tau * tau))

    cosine = 1.0 / :math.sqrt(1.0 + tangent * tangent)
    {tangent * cosine, cosine}
  end

  defp tangent(sine, cosine), do: sine / cosine

  defp rotate_rows(matrix, first, second, count, sine, cosine) do
    for index <- 0..(count - 1), reduce: matrix do
      matrix ->
        if index == first or index == second do
          matrix
        else
          to_first = value(matrix, index, first)
          to_second = value(matrix, index, second)
          turned_first = cosine * to_first - sine * to_second
          turned_second = sine * to_first + cosine * to_second

          matrix
          |> put(index, first, turned_first)
          |> put(first, index, turned_first)
          |> put(index, second, turned_second)
          |> put(second, index, turned_second)
        end
    end
  end

  defp rotate_columns(matrix, first, second, count, sine, cosine) do
    for index <- 0..(count - 1), reduce: matrix do
      matrix ->
        to_first = value(matrix, index, first)
        to_second = value(matrix, index, second)

        matrix
        |> put(index, first, cosine * to_first - sine * to_second)
        |> put(index, second, sine * to_first + cosine * to_second)
    end
  end

  # A null vector of a two-by-two matrix whose determinant is zero: the larger of
  # its rows, turned. A matrix that is all zeros has every vector as a null
  # vector, and answers the first axis.
  defp null_vector([[a, b], [c, d]]) do
    largest = Enum.max_by([{a, b}, {c, d}], fn {left, right} -> abs(left) + abs(right) end)

    {left, right} = largest

    if left == 0.0 and right == 0.0,
      do: [1.0, 0.0],
      else: normalise([right, -left])
  end

  defp normalise([x, y]) do
    length = :math.sqrt(x * x + y * y)
    [x / length, y / length]
  end

  # -- reading and writing rows ----------------------------------------------

  defp value(matrix, row, column), do: matrix |> Enum.at(row) |> Enum.at(column)

  defp put(matrix, row, column, value) do
    List.update_at(matrix, row, &List.replace_at(&1, column, value))
  end

  defp column(matrix, index), do: Enum.map(matrix, &Enum.at(&1, index))

  defp diagonal(matrix) do
    matrix
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> Enum.at(row, index) * 1.0 end)
  end

  defp largest_off_diagonal(matrix, count) do
    off_diagonal =
      for row <- 0..(count - 1),
          column <- (row + 1)..(count - 1)//1,
          do: abs(value(matrix, row, column))

    Enum.max(off_diagonal, fn -> 0.0 end)
  end

  defp tolerance(matrix) do
    largest = matrix |> List.flatten() |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)
    @pivot_tolerance * max(largest, 1.0)
  end

  defp eigen_tolerance(matrix) do
    largest = matrix |> List.flatten() |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)
    @eigen_tolerance * max(largest, 1.0)
  end
end
