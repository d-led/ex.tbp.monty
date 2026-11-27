defmodule Monty.Frameworks.Models.EvidenceMatching.PoseKind do
  @moduledoc """
  What a channel's pose is, read from beside the numbers a step carries.

  Monty's feature dict holds a value that is both an array and a type, and three
  places ask for the type: the displacer chooses the distance rule and the pose
  evidence by it, and the updater decides how many hypotheses a node starts with
  (§2.50). Here the numbers are a list, so `select_features_to_use/2` records the
  type on the same map under `key/0`, and this module is the one place that reads
  it back — a caller that hands over numbers alone is a surface channel, which is
  what every config in `conf/` asks for.
  """

  alias Monty.Geometry.{OrientationMatrix, SurfacePoseVectors}

  @key "pose_vectors_kind"

  @typedoc "The pose types a step can carry, and the one it cannot."
  @type t :: :surface_pose_vectors | :orientation_matrix | :unsupported

  @doc "The key the type travels under, beside the pose's nine numbers."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  The kind a channel's features carry.

  In the struct, when a synthetic module built one; beside the numbers when the
  selector flattened an observation; and `:unsupported` when the value is neither
  — which its caller refuses by name, as Monty's `TypeError` does.
  """
  @spec of(map()) :: t()
  def of(features) do
    case Map.fetch(features, "pose_vectors") do
      {:ok, %SurfacePoseVectors{}} -> :surface_pose_vectors
      {:ok, %OrientationMatrix{}} -> :orientation_matrix
      {:ok, numbers} when is_list(numbers) -> Map.get(features, @key, :surface_pose_vectors)
      _neither -> :unsupported
    end
  end

  @doc """
  The pose as the type it arrived as, built from the nine numbers.

  A surface pose is three directions — its normal and two curvature directions;
  an object orientation is the frame itself, row by row.
  """
  @spec vectors(t(), [number()]) :: SurfacePoseVectors.t() | OrientationMatrix.t()
  def vectors(:orientation_matrix, numbers) do
    [first, second, third] = Enum.chunk_every(numbers, 3)
    %OrientationMatrix{value: [first, second, third]}
  end

  def vectors(:surface_pose_vectors, numbers) do
    [normal, curvature_1, curvature_2] = Enum.chunk_every(numbers, 3)
    SurfacePoseVectors.new(normal, curvature_1, curvature_2)
  end
end
