defmodule Monty.Attention.VoxelGrid do
  @moduledoc """
  A sparse grid of per-voxel weights over 3-D space: Monty's
  `attention/voxel_grid.py::VoxelGrid`.

  An attention system remembers where it has looked, and it remembers it in
  voxels: space is cut into cubes `voxel_size` on a side, and each cube that has
  been looked at holds one weight. Space is mostly empty, so the grid is sparse —
  Monty backs it with a pandas `DataFrame` whose index is the occupied voxels'
  coordinates; here it is a map from a voxel to its weight, which is the same
  thing with less machinery.

  ## Which voxel a point is in

  Voxels are **half-open**: a point on the face shared by two voxels belongs to
  the one with the larger coordinate, so voxel `v` spans `[v, v + 1)` in units of
  `voxel_size`. That is `floor(point / voxel_size)` and it is why a point at
  exactly `0.0` is in voxel `0` while one at `-0.0001` is in voxel `-1`.

  ## What is not here

  Monty's representation is public, so its tests can build a malformed
  `DataFrame` and check that `validate_dataframe` refuses it: no `(x, y, z)`
  index, a duplicated index, no `weight` column, a weight column that is not one
  dimension. A map cannot be malformed in those ways — a duplicate voxel is
  simply one entry — so what survives of those four cases here is the one rule a
  map *can* break: `new/3` refuses two weights for one voxel rather than letting
  the last one win. `from_pandas/2` and `to_pandas/1` have no counterpart.
  """

  @enforce_keys [:voxel_size]
  defstruct voxel_size: nil, weights: %{}

  @typedoc "A voxel's lower corner, in voxels."
  @type voxel :: {integer(), integer(), integer()}

  @type t :: %__MODULE__{
          voxel_size: float(),
          weights: %{optional(voxel()) => number()}
        }

  @doc "A grid with no occupied voxels."
  @spec empty(float()) :: t()
  def empty(voxel_size), do: %__MODULE__{voxel_size: voxel_size}

  @doc """
  A grid over the given voxels.

  Refuses two weights for one voxel: a voxel holds one weight, and silently
  keeping the last would turn a caller's bookkeeping bug into a grid that looks
  fine.
  """
  @spec new(float(), [voxel()], [number()]) :: t()
  def new(voxel_size, voxels, weights) do
    if length(voxels) != length(weights) do
      raise ArgumentError,
            "a voxel grid needs one weight per voxel, got #{length(voxels)} voxels " <>
              "and #{length(weights)} weights"
    end

    weights =
      voxels
      |> Enum.zip(weights)
      |> Map.new()

    if map_size(weights) != length(voxels) do
      raise ArgumentError, "a voxel grid holds one weight per voxel: the voxels given repeat"
    end

    %__MODULE__{voxel_size: voxel_size, weights: weights}
  end

  @doc "Edge length of a voxel."
  @spec voxel_size(t()) :: float()
  def voxel_size(%__MODULE__{voxel_size: voxel_size}), do: voxel_size

  @doc "The number of occupied voxels."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{weights: weights}), do: map_size(weights)

  @doc "The occupied voxels, in a stable order (the tuples sort)."
  @spec voxels(t()) :: [voxel()]
  def voxels(%__MODULE__{weights: weights}), do: weights |> Map.keys() |> Enum.sort()

  @doc "The weights of the occupied voxels, in the same order as `voxels/1`."
  @spec weights(t()) :: [number()]
  def weights(%__MODULE__{} = grid), do: Enum.map(voxels(grid), &Map.fetch!(grid.weights, &1))

  @doc """
  The grid's weight at each point.

  `:fill` is what an unoccupied voxel answers — `nil` by default, the NaN of
  this port, which says "no weight here" rather than "a weight of zero".
  """
  @spec weights_at_points(t(), [[number()]], keyword()) :: [number() | nil]
  def weights_at_points(%__MODULE__{} = grid, points, options \\ []) do
    fill = Keyword.get(options, :fill, nil)

    grid.voxel_size
    |> voxelize_points(points)
    |> Enum.map(&Map.get(grid.weights, &1, fill))
  end

  @doc """
  Which voxel each point is in — Monty's `voxelize_points`.

  `floor` rather than `trunc`: the voxels are half-open, so the point at `-0.5`
  is in voxel `-1`, not in voxel `0`.
  """
  @spec voxelize_points(float(), [[number()]]) :: [voxel()]
  def voxelize_points(voxel_size, points) do
    unless Enum.all?(points, &match?([_, _, _], &1)) do
      raise ArgumentError,
            "points must be a list of [x, y, z]; a point cloud with any other shape " <>
              "is not one this grid can bin"
    end

    Enum.map(points, fn [x, y, z] ->
      {floor_to_voxel(x, voxel_size), floor_to_voxel(y, voxel_size),
       floor_to_voxel(z, voxel_size)}
    end)
  end

  defp floor_to_voxel(coordinate, voxel_size),
    do: coordinate |> Kernel./(voxel_size) |> :math.floor() |> trunc()

  @doc """
  Each point's voxel alongside its weight — Monty's `voxelize_and_bin_points`.

  The rows come back in point order, which is what a caller that wants to group
  them by voxel needs to keep the point indices.
  """
  @spec voxelize_and_bin_points(float(), [[number()]], [number()]) :: [{voxel(), number()}]
  def voxelize_and_bin_points(voxel_size, points, weights) do
    if length(weights) != length(points) do
      raise ArgumentError,
            "weights must be one per point: #{length(points)} points and #{length(weights)} weights"
    end

    voxel_size
    |> voxelize_points(points)
    |> Enum.zip(weights)
  end

  @doc """
  The grid as JSON-encodable data — Monty's `encode_voxel_grid`.

  `voxels` and `weight` are parallel lists, which is how Monty writes the
  MultiIndex it cannot serialise.
  """
  @spec encode(t()) :: %{optional(String.t()) => term()}
  def encode(%__MODULE__{} = grid) do
    %{
      "voxel_size" => grid.voxel_size,
      "voxels" => grid |> voxels() |> Enum.map(&Tuple.to_list/1),
      "weight" => weights(grid)
    }
  end
end
